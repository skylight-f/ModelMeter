import Foundation

enum TaskRuntimeState: String, Equatable {
    case recorded
    case idle
    case running
    case waitingApproval
    case waitingInput
    case failed
    case completed
    case interrupted
    case disconnected

    var attentionRank: Int? {
        switch self {
        case .waitingApproval:
            return 0
        case .waitingInput:
            return 1
        case .failed:
            return 2
        case .recorded, .idle, .running, .completed, .interrupted, .disconnected:
            return nil
        }
    }

    var columnKind: TaskColumnKind {
        switch self {
        case .running, .waitingApproval, .waitingInput:
            return .active
        case .completed:
            return .done
        case .recorded, .idle, .failed, .interrupted, .disconnected:
            return .pending
        }
    }
}

enum TaskConnectionMode: String, Equatable {
    case disconnected
    case sharedDaemon
    case isolated
}

enum CodexRequestID: Equatable {
    case string(String)
    case integer(Int64)

    init?(_ value: Any?) {
        if let value = value as? String {
            self = .string(value)
        } else if let value = value as? Int {
            self = .integer(Int64(value))
        } else if let value = value as? Int64 {
            self = .integer(value)
        } else if let value = value as? NSNumber {
            self = .integer(value.int64Value)
        } else {
            return nil
        }
    }

    var jsonObject: Any {
        switch self {
        case .string(let value):
            return value
        case .integer(let value):
            return value
        }
    }

    var stableKey: String {
        switch self {
        case .string(let value):
            return "s:\(value)"
        case .integer(let value):
            return "i:\(value)"
        }
    }
}

enum TaskApprovalKind: String, Equatable {
    case command
    case fileChange
}

enum TaskApprovalDecision: String, CaseIterable, Equatable {
    case accept
    case acceptForSession
    case decline
    case cancel
}

enum TaskApprovalSubmissionState: String, Equatable {
    case pending
    case submitting
}

struct TaskApprovalRequest: Equatable {
    let requestID: CodexRequestID
    let kind: TaskApprovalKind
    let threadID: String
    let turnID: String
    let itemID: String
    let reason: String?
    let summary: String
    let detail: String?
    let requestedAt: Date
    let availableDecisions: [TaskApprovalDecision]
    let submissionState: TaskApprovalSubmissionState

    func submitting() -> TaskApprovalRequest {
        TaskApprovalRequest(
            requestID: requestID,
            kind: kind,
            threadID: threadID,
            turnID: turnID,
            itemID: itemID,
            reason: reason,
            summary: summary,
            detail: detail,
            requestedAt: requestedAt,
            availableDecisions: availableDecisions,
            submissionState: .submitting
        )
    }
}

struct TaskLiveRecord: Equatable {
    let threadID: String
    let name: String?
    let state: TaskRuntimeState
    let updatedAt: Date?
    let turnID: String?
    let approval: TaskApprovalRequest?
    let connectionMode: TaskConnectionMode

    var isRealtime: Bool {
        connectionMode != .disconnected && state != .recorded && state != .disconnected
    }
}

struct CodexTaskLiveSnapshot: Equatable {
    let connectionMode: TaskConnectionMode
    let records: [String: TaskLiveRecord]
    let refreshedAt: Date

    static let disconnected = CodexTaskLiveSnapshot(
        connectionMode: .disconnected,
        records: [:],
        refreshedAt: .distantPast
    )
}

private struct TaskItemSummary {
    let summary: String
    let detail: String?
}

struct TaskRuntimeReducer {
    private(set) var connectionMode: TaskConnectionMode = .disconnected
    private var records: [String: TaskLiveRecord] = [:]
    private var requestThreads: [String: String] = [:]
    private var itemSummaries: [String: TaskItemSummary] = [:]

    mutating func replaceThreads(_ threads: [[String: Any]], connectionMode: TaskConnectionMode) {
        self.connectionMode = connectionMode
        var nextRecords: [String: TaskLiveRecord] = [:]

        for thread in threads {
            guard let threadID = thread["id"] as? String else { continue }
            let previous = records[threadID]
            let state = Self.runtimeState(from: thread["status"] as? [String: Any])
            let updatedAt = Self.dateFromSeconds(thread["updatedAt"])
            let rawName = (thread["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let name = rawName.flatMap { $0.isEmpty ? nil : $0 }

            nextRecords[threadID] = TaskLiveRecord(
                threadID: threadID,
                name: name ?? previous?.name,
                state: previous?.approval == nil ? state : .waitingApproval,
                updatedAt: updatedAt ?? previous?.updatedAt,
                turnID: previous?.turnID,
                approval: previous?.approval,
                connectionMode: connectionMode
            )
        }

        for (threadID, record) in records where record.approval != nil && nextRecords[threadID] == nil {
            nextRecords[threadID] = TaskLiveRecord(
                threadID: threadID,
                name: record.name,
                state: .waitingApproval,
                updatedAt: record.updatedAt,
                turnID: record.turnID,
                approval: record.approval,
                connectionMode: connectionMode
            )
        }

        records = nextRecords
    }

    @discardableResult
    mutating func applyNotification(method: String, params: [String: Any]) -> Bool {
        switch method {
        case "thread/status/changed":
            guard let threadID = params["threadId"] as? String else { return false }
            updateRecord(
                threadID: threadID,
                state: Self.runtimeState(from: params["status"] as? [String: Any]),
                updatedAt: Date()
            )
            return true

        case "turn/started":
            guard let threadID = params["threadId"] as? String else { return false }
            let turn = params["turn"] as? [String: Any]
            updateRecord(
                threadID: threadID,
                state: .running,
                updatedAt: Date(),
                turnID: turn?["id"] as? String
            )
            return true

        case "turn/completed":
            guard let threadID = params["threadId"] as? String,
                  let turn = params["turn"] as? [String: Any]
            else { return false }
            let state = Self.turnState(turn["status"] as? String)
            updateRecord(
                threadID: threadID,
                state: state,
                updatedAt: Date(),
                turnID: turn["id"] as? String,
                clearApproval: true
            )
            return true

        case "item/started":
            guard let item = params["item"] as? [String: Any],
                  let itemID = item["id"] as? String
            else { return false }
            if let summary = Self.itemSummary(item) {
                itemSummaries[itemID] = summary
            }
            return false

        case "item/completed":
            guard let threadID = params["threadId"] as? String,
                  let item = params["item"] as? [String: Any]
            else { return false }
            if let itemID = item["id"] as? String {
                itemSummaries.removeValue(forKey: itemID)
            }
            let status = item["status"] as? String
            if status == "failed" {
                updateRecord(threadID: threadID, state: .failed, updatedAt: Date(), clearApproval: true)
                return true
            }
            return false

        case "serverRequest/resolved":
            guard let requestID = CodexRequestID(params["requestId"]) else { return false }
            return resolve(requestID: requestID)

        default:
            return false
        }
    }

    @discardableResult
    mutating func applyServerRequest(
        requestID: CodexRequestID,
        method: String,
        params: [String: Any]
    ) -> Bool {
        guard let threadID = params["threadId"] as? String else { return false }

        if method == "item/tool/requestUserInput" {
            updateRecord(threadID: threadID, state: .waitingInput, updatedAt: Date())
            return true
        }

        guard method == "item/commandExecution/requestApproval"
            || method == "item/fileChange/requestApproval"
        else {
            if method == "item/permissions/requestApproval" || method == "mcpServer/elicitation/request" {
                updateRecord(threadID: threadID, state: .waitingApproval, updatedAt: Date())
                return true
            }
            return false
        }

        guard let turnID = params["turnId"] as? String,
              let itemID = params["itemId"] as? String
        else { return false }

        let kind: TaskApprovalKind = method == "item/commandExecution/requestApproval" ? .command : .fileChange
        let cachedSummary = itemSummaries[itemID]
        let summary: String
        let detail: String?

        if kind == .command {
            let command = params["command"] as? String
            summary = cachedSummary?.summary ?? Self.commandSummary(params: params, command: command)
            detail = command ?? cachedSummary?.detail
        } else {
            summary = cachedSummary?.summary ?? "File changes"
            detail = cachedSummary?.detail
        }

        let availableDecisions = Self.approvalDecisions(params["availableDecisions"])
        let requestedAt = Self.dateFromMilliseconds(params["startedAtMs"]) ?? Date()
        let approval = TaskApprovalRequest(
            requestID: requestID,
            kind: kind,
            threadID: threadID,
            turnID: turnID,
            itemID: itemID,
            reason: params["reason"] as? String,
            summary: summary,
            detail: detail,
            requestedAt: requestedAt,
            availableDecisions: availableDecisions,
            submissionState: .pending
        )

        requestThreads[requestID.stableKey] = threadID
        let previous = records[threadID]
        records[threadID] = TaskLiveRecord(
            threadID: threadID,
            name: previous?.name,
            state: .waitingApproval,
            updatedAt: requestedAt,
            turnID: turnID,
            approval: approval,
            connectionMode: connectionMode
        )
        return true
    }

    @discardableResult
    mutating func markSubmitting(requestID: CodexRequestID, decision: TaskApprovalDecision) -> Bool {
        guard let threadID = requestThreads[requestID.stableKey],
              let record = records[threadID],
              let approval = record.approval,
              approval.submissionState == .pending,
              approval.availableDecisions.contains(decision)
        else { return false }

        records[threadID] = TaskLiveRecord(
            threadID: record.threadID,
            name: record.name,
            state: record.state,
            updatedAt: record.updatedAt,
            turnID: record.turnID,
            approval: approval.submitting(),
            connectionMode: record.connectionMode
        )
        return true
    }

    @discardableResult
    mutating func resolve(requestID: CodexRequestID) -> Bool {
        guard let threadID = requestThreads.removeValue(forKey: requestID.stableKey),
              let record = records[threadID]
        else { return false }

        records[threadID] = TaskLiveRecord(
            threadID: record.threadID,
            name: record.name,
            state: .running,
            updatedAt: Date(),
            turnID: record.turnID,
            approval: nil,
            connectionMode: record.connectionMode
        )
        return true
    }

    mutating func disconnect() {
        connectionMode = .disconnected
        requestThreads.removeAll()
        itemSummaries.removeAll()
        records = records.mapValues { record in
            let disconnectedState: TaskRuntimeState
            switch record.state {
            case .running, .waitingApproval, .waitingInput:
                disconnectedState = .disconnected
            default:
                disconnectedState = record.state
            }
            return TaskLiveRecord(
                threadID: record.threadID,
                name: record.name,
                state: disconnectedState,
                updatedAt: record.updatedAt,
                turnID: record.turnID,
                approval: nil,
                connectionMode: .disconnected
            )
        }
    }

    func snapshot(at date: Date = Date()) -> CodexTaskLiveSnapshot {
        CodexTaskLiveSnapshot(
            connectionMode: connectionMode,
            records: records,
            refreshedAt: date
        )
    }

    private mutating func updateRecord(
        threadID: String,
        state: TaskRuntimeState,
        updatedAt: Date?,
        turnID: String? = nil,
        clearApproval: Bool = false
    ) {
        let previous = records[threadID]
        if clearApproval, let requestID = previous?.approval?.requestID {
            requestThreads.removeValue(forKey: requestID.stableKey)
        }
        records[threadID] = TaskLiveRecord(
            threadID: threadID,
            name: previous?.name,
            state: state,
            updatedAt: updatedAt ?? previous?.updatedAt,
            turnID: turnID ?? previous?.turnID,
            approval: clearApproval ? nil : previous?.approval,
            connectionMode: connectionMode
        )
    }

    private static func runtimeState(from status: [String: Any]?) -> TaskRuntimeState {
        guard let type = status?["type"] as? String else { return .recorded }
        switch type {
        case "active":
            let flags = status?["activeFlags"] as? [String] ?? []
            if flags.contains("waitingOnApproval") { return .waitingApproval }
            if flags.contains("waitingOnUserInput") { return .waitingInput }
            return .running
        case "idle":
            return .idle
        case "systemError":
            return .failed
        default:
            return .recorded
        }
    }

    private static func turnState(_ status: String?) -> TaskRuntimeState {
        switch status {
        case "completed":
            return .completed
        case "interrupted":
            return .interrupted
        case "failed":
            return .failed
        case "inProgress":
            return .running
        default:
            return .recorded
        }
    }

    private static func approvalDecisions(_ value: Any?) -> [TaskApprovalDecision] {
        let parsed = (value as? [Any] ?? []).compactMap { element -> TaskApprovalDecision? in
            guard let raw = element as? String else { return nil }
            return TaskApprovalDecision(rawValue: raw)
        }
        if !parsed.isEmpty { return parsed }
        return [.accept, .decline, .cancel]
    }

    private static func itemSummary(_ item: [String: Any]) -> TaskItemSummary? {
        switch item["type"] as? String {
        case "commandExecution":
            let command = item["command"] as? String
            return TaskItemSummary(
                summary: commandSummary(params: item, command: command),
                detail: command
            )
        case "fileChange":
            let changes = item["changes"] as? [[String: Any]] ?? []
            let filenames = changes.compactMap { change in
                (change["path"] as? String).map { URL(fileURLWithPath: $0).lastPathComponent }
            }
            let count = changes.count
            let summary = count == 1 ? "Change 1 file" : "Change \(count) files"
            let detail = filenames.isEmpty ? nil : filenames.prefix(4).joined(separator: ", ")
            return TaskItemSummary(summary: summary, detail: detail)
        default:
            return nil
        }
    }

    private static func commandSummary(params: [String: Any], command: String?) -> String {
        let actions = params["commandActions"] as? [[String: Any]] ?? []
        if let action = actions.first,
           let type = action["type"] as? String {
            switch type {
            case "read":
                return "Read \((action["name"] as? String) ?? "a file")"
            case "listFiles":
                return "List files"
            case "search":
                return "Search files"
            default:
                break
            }
        }
        guard let command, !command.isEmpty else { return "Run a command" }
        let executable = command.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? "command"
        return "Run \(URL(fileURLWithPath: executable).lastPathComponent)"
    }

    private static func dateFromSeconds(_ value: Any?) -> Date? {
        if let value = value as? Int { return Date(timeIntervalSince1970: TimeInterval(value)) }
        if let value = value as? Int64 { return Date(timeIntervalSince1970: TimeInterval(value)) }
        if let value = value as? NSNumber { return Date(timeIntervalSince1970: value.doubleValue) }
        return nil
    }

    private static func dateFromMilliseconds(_ value: Any?) -> Date? {
        if let value = value as? Int { return Date(timeIntervalSince1970: TimeInterval(value) / 1_000) }
        if let value = value as? Int64 { return Date(timeIntervalSince1970: TimeInterval(value) / 1_000) }
        if let value = value as? NSNumber { return Date(timeIntervalSince1970: value.doubleValue / 1_000) }
        return nil
    }
}

enum TaskAttentionKind: Int, Equatable {
    case approval = 0
    case userInput = 1
    case failure = 2
    case dataIssue = 3
    case update = 4
}

struct TaskAttentionItem: Identifiable, Equatable {
    let id: String
    let kind: TaskAttentionKind
    let runtimeScope: RuntimeScope?
    let threadID: String?
    let title: String
    let since: Date?
}

enum TaskAttentionSelector {
    static func highestPriority(_ items: [TaskAttentionItem]) -> TaskAttentionItem? {
        items.sorted { lhs, rhs in
            if lhs.kind.rawValue != rhs.kind.rawValue {
                return lhs.kind.rawValue < rhs.kind.rawValue
            }
            switch (lhs.since, rhs.since) {
            case let (left?, right?) where left != right:
                return left < right
            case (nil, _?):
                return false
            case (_?, nil):
                return true
            default:
                return lhs.id < rhs.id
            }
        }.first
    }
}

extension TaskItem {
    func applying(_ record: TaskLiveRecord) -> TaskItem {
        TaskItem(
            id: id,
            code: code,
            title: title,
            detail: detail,
            chip: chip,
            updatedAt: record.updatedAt ?? updatedAt,
            tokens: tokens,
            kind: record.state.columnKind,
            threadID: record.threadID,
            runtimeState: record.state,
            isRealtime: record.isRealtime,
            approval: record.approval
        )
    }
}

extension TaskBoard {
    func merging(_ live: CodexTaskLiveSnapshot, now: Date = Date()) -> TaskBoard {
        var itemsByThread: [String: TaskItem] = [:]
        var scheduledItems: [TaskItem] = []

        for column in columns {
            for item in column.items {
                if item.kind == .scheduled || item.threadID == nil {
                    scheduledItems.append(item)
                } else if let threadID = item.threadID {
                    itemsByThread[threadID] = item
                }
            }
        }

        for record in live.records.values {
            if let existing = itemsByThread[record.threadID] {
                itemsByThread[record.threadID] = existing.applying(record)
            } else if record.isRealtime, Calendar.current.isDate(record.updatedAt ?? now, inSameDayAs: now) {
                let compactID = record.threadID.replacingOccurrences(of: "-", with: "")
                let item = TaskItem(
                    id: "live-\(record.threadID)",
                    code: "COD-\(compactID.suffix(4).uppercased())",
                    title: record.name ?? "Codex task",
                    detail: "",
                    chip: "Live",
                    updatedAt: record.updatedAt,
                    tokens: nil,
                    kind: record.state.columnKind,
                    threadID: record.threadID,
                    runtimeState: record.state,
                    isRealtime: record.isRealtime,
                    approval: record.approval
                )
                itemsByThread[record.threadID] = item
            }
        }

        let threadItems = Array(itemsByThread.values)
        func sorted(_ kind: TaskColumnKind) -> [TaskItem] {
            threadItems.filter { $0.kind == kind }.sorted { lhs, rhs in
                let leftRank = lhs.runtimeState.attentionRank ?? Int.max
                let rightRank = rhs.runtimeState.attentionRank ?? Int.max
                if leftRank != rightRank { return leftRank < rightRank }
                return (lhs.updatedAt ?? .distantPast) > (rhs.updatedAt ?? .distantPast)
            }
        }

        let titles = Dictionary(uniqueKeysWithValues: columns.map { ($0.id, $0.title) })
        let active = sorted(.active)
        let pending = sorted(.pending)
        let done = sorted(.done)
        let scheduled = scheduledItems.sorted { $0.title < $1.title }

        return TaskBoard(refreshedAt: now, columns: [
            TaskColumn(id: .active, title: titles[.active] ?? "Active", count: active.count, items: active),
            TaskColumn(id: .pending, title: titles[.pending] ?? "Pending", count: pending.count, items: pending),
            TaskColumn(id: .scheduled, title: titles[.scheduled] ?? "Scheduled", count: scheduled.count, items: scheduled),
            TaskColumn(id: .done, title: titles[.done] ?? "Done", count: done.count, items: done)
        ])
    }

    func attentionItems(scope: RuntimeScope) -> [TaskAttentionItem] {
        columns.flatMap(\.items).compactMap { item in
            let kind: TaskAttentionKind
            switch item.runtimeState {
            case .waitingApproval:
                kind = .approval
            case .waitingInput:
                kind = .userInput
            case .failed:
                kind = .failure
            default:
                return nil
            }
            return TaskAttentionItem(
                id: "\(scope.runtimeId)-\(item.id)-\(kind.rawValue)",
                kind: kind,
                runtimeScope: scope,
                threadID: item.threadID,
                title: item.title,
                since: item.approval?.requestedAt ?? item.updatedAt
            )
        }
    }
}
