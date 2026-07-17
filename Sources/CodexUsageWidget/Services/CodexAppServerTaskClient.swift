import AppKit
import Darwin
import Foundation

enum TaskConnectionReason: Hashable {
    case startup
    case taskUI
    case popover
}

protocol CodexTaskEventClient: AnyObject {
    var onSnapshot: ((CodexTaskLiveSnapshot) -> Void)? { get set }
    func start(reason: TaskConnectionReason)
    func stopIfIdle()
    func stop()
    func refreshThreads()
}

final class CodexAppServerTaskClient: CodexTaskEventClient {
    var onSnapshot: ((CodexTaskLiveSnapshot) -> Void)?

    private let queue = DispatchQueue(label: "com.codexu.task-app-server", qos: .utility)
    private let fileManager: FileManager
    private let homeDirectory: URL
    private var process: Process?
    private var inputHandle: FileHandle?
    private var outputHandle: FileHandle?
    private var outputBuffer = Data()
    private var reducer = TaskRuntimeReducer()
    private var connectionMode: TaskConnectionMode = .disconnected
    private var activeReasons: Set<TaskConnectionReason> = []
    private var nextRequestID: Int64 = 100
    private var pendingThreadListIDs: Set<Int64> = []
    private var pendingThreadListSpans: [Int64: PerformanceSpan] = [:]
    private var initializeTimeout: DispatchWorkItem?
    private var isStopping = false

    private let initializeRequestID: Int64 = 1

    init(
        fileManager: FileManager = .default,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.fileManager = fileManager
        self.homeDirectory = homeDirectory
    }

    func start(reason: TaskConnectionReason) {
        queue.async { [weak self] in
            guard let self else { return }
            self.activeReasons.insert(reason)
            if self.process?.isRunning == true {
                if reason != .startup { self.requestThreadList() }
                return
            }

            let sharedDaemonAvailable = self.fileManager.fileExists(atPath: self.defaultDaemonSocket.path)
            guard sharedDaemonAvailable else { return }
            self.launch(mode: .sharedDaemon)
        }
    }

    func stopIfIdle() {
        queue.async { [weak self] in
            guard let self else { return }
            self.activeReasons.remove(.taskUI)
            self.activeReasons.remove(.popover)
            if self.connectionMode == .isolated {
                self.stopProcess()
            }
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.activeReasons.removeAll()
            self?.stopProcess()
        }
    }

    func refreshThreads() {
        queue.async { [weak self] in
            self?.requestThreadList()
        }
    }

    private var defaultDaemonSocket: URL {
        homeDirectory
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("app-server-control", isDirectory: true)
            .appendingPathComponent("app-server-control.sock")
    }

    private func launch(mode: TaskConnectionMode) {
        guard let codexURL = resolveCodexExecutableURL() else {
            reducer.disconnect()
            publishSnapshot()
            return
        }

        isStopping = false
        outputBuffer.removeAll(keepingCapacity: true)
        pendingThreadListIDs.removeAll()
        pendingThreadListSpans.removeAll()
        connectionMode = mode

        let process = Process()
        process.executableURL = codexURL
        process.arguments = mode == .sharedDaemon
            ? ["app-server", "proxy"]
            : ["app-server"]

        let input = Pipe()
        let output = Pipe()
        let error = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = error
        process.terminationHandler = { [weak self] _ in
            self?.queue.async {
                self?.handleDisconnect()
            }
        }

        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            self?.queue.async {
                self?.consume(data)
            }
        }

        do {
            try process.run()
        } catch {
            output.fileHandleForReading.readabilityHandler = nil
            connectionMode = .disconnected
            reducer.disconnect()
            publishSnapshot()
            return
        }

        self.process = process
        inputHandle = input.fileHandleForWriting
        outputHandle = output.fileHandleForReading

        guard writeJSONObject([
            "id": initializeRequestID,
            "method": "initialize",
            "params": [
                "clientInfo": [
                    "name": "codexu",
                    "title": "codexU",
                    "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
                ],
                "capabilities": [
                    "experimentalApi": false,
                    "optOutNotificationMethods": []
                ]
            ]
        ]) else {
            stopProcess()
            return
        }

        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.process?.isRunning == true else { return }
            self.stopProcess()
        }
        initializeTimeout = timeout
        queue.asyncAfter(deadline: .now() + 8, execute: timeout)
    }

    private func consume(_ data: Data) {
        guard !data.isEmpty else {
            handleDisconnect()
            return
        }

        outputBuffer.append(data)
        while let newline = outputBuffer.firstIndex(of: 10) {
            let line = outputBuffer.subdata(in: outputBuffer.startIndex..<newline)
            outputBuffer.removeSubrange(outputBuffer.startIndex...newline)
            guard !line.isEmpty,
                  let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any]
            else { continue }
            handle(object)
        }
    }

    private func handle(_ object: [String: Any]) {
        if let method = object["method"] as? String {
            guard object["id"] == nil else { return }
            let params = object["params"] as? [String: Any] ?? [:]
            if reducer.applyNotification(method: method, params: params) {
                publishSnapshot()
            }
            return
        }

        guard let responseID = Self.integerID(object["id"]) else { return }
        if responseID == initializeRequestID {
            initializeTimeout?.cancel()
            initializeTimeout = nil
            guard object["error"] == nil else {
                stopProcess()
                return
            }
            _ = writeJSONObject(["method": "initialized"])
            requestThreadList()
            return
        }

        guard pendingThreadListIDs.remove(responseID) != nil,
              let result = object["result"] as? [String: Any],
              let threads = result["data"] as? [[String: Any]]
        else {
            if let span = pendingThreadListSpans.removeValue(forKey: responseID) {
                PerformanceMonitor.shared.end(span, success: false)
            }
            return
        }

        if let span = pendingThreadListSpans.removeValue(forKey: responseID) {
            PerformanceMonitor.shared.end(span)
        }
        reducer.replaceThreads(threads, connectionMode: connectionMode)
        publishSnapshot()
    }

    private func requestThreadList() {
        guard process?.isRunning == true, initializeTimeout == nil else { return }
        let requestID = nextRequestID
        nextRequestID &+= 1
        pendingThreadListIDs.insert(requestID)
        pendingThreadListSpans[requestID] = PerformanceMonitor.shared.begin(.appServerTasks)
        let wrote = writeJSONObject([
            "id": requestID,
            "method": "thread/list",
            "params": [
                "limit": 100,
                "sortKey": "recency_at",
                "sortDirection": "desc",
                "useStateDbOnly": true,
                "sourceKinds": ["cli", "vscode", "appServer"]
            ]
        ])
        if !wrote {
            pendingThreadListIDs.remove(requestID)
            if let span = pendingThreadListSpans.removeValue(forKey: requestID) {
                PerformanceMonitor.shared.end(span, success: false)
            }
            handleDisconnect()
        }
    }

    private func writeJSONObject(_ object: [String: Any]) -> Bool {
        guard let handle = inputHandle,
              let data = try? JSONSerialization.data(withJSONObject: object)
        else { return false }
        do {
            try handle.write(contentsOf: data)
            try handle.write(contentsOf: Data("\n".utf8))
            return true
        } catch {
            return false
        }
    }

    private func publishSnapshot() {
        let snapshot = reducer.snapshot()
        DispatchQueue.main.async { [weak self] in
            self?.onSnapshot?(snapshot)
        }
    }

    private func handleDisconnect() {
        guard connectionMode != .disconnected || process != nil else { return }
        initializeTimeout?.cancel()
        initializeTimeout = nil
        outputHandle?.readabilityHandler = nil
        try? inputHandle?.close()
        inputHandle = nil
        outputHandle = nil
        process = nil
        outputBuffer.removeAll(keepingCapacity: false)
        pendingThreadListIDs.removeAll()
        for span in pendingThreadListSpans.values {
            PerformanceMonitor.shared.end(span, success: false)
        }
        pendingThreadListSpans.removeAll()
        connectionMode = .disconnected
        reducer.disconnect()
        publishSnapshot()
    }

    private func stopProcess() {
        guard !isStopping else { return }
        isStopping = true
        initializeTimeout?.cancel()
        initializeTimeout = nil
        outputHandle?.readabilityHandler = nil
        try? inputHandle?.close()

        if let process, process.isRunning {
            let pid = process.processIdentifier
            process.terminate()
            queue.asyncAfter(deadline: .now() + 1) {
                if process.isRunning { Darwin.kill(pid, SIGKILL) }
            }
        }
        handleDisconnect()
        isStopping = false
    }

    private func resolveCodexExecutableURL() -> URL? {
        var candidates: [URL] = []
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex") {
            candidates.append(appURL.appendingPathComponent("Contents/Resources/codex"))
        }
        candidates.append(contentsOf: [
            URL(fileURLWithPath: "/Applications/ChatGPT.app/Contents/Resources/codex"),
            URL(fileURLWithPath: "/Applications/Codex.app/Contents/Resources/codex"),
            URL(fileURLWithPath: "/opt/homebrew/bin/codex"),
            URL(fileURLWithPath: "/usr/local/bin/codex"),
            URL(fileURLWithPath: "/usr/bin/codex")
        ])
        return candidates.first { fileManager.isExecutableFile(atPath: $0.path) }
    }

    private static func integerID(_ value: Any?) -> Int64? {
        if let value = value as? Int { return Int64(value) }
        if let value = value as? Int64 { return value }
        if let value = value as? NSNumber { return value.int64Value }
        return nil
    }
}
