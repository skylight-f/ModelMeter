import Cocoa
import Carbon.HIToolbox
import SwiftUI

struct RateWindow: Equatable {
    let usedPercent: Double
    let windowDurationMins: Int?
    let resetsAt: Date?

    var remainingPercent: Double {
        max(0, min(100, 100 - usedPercent))
    }
}

struct CreditsInfo: Equatable {
    let hasCredits: Bool
    let unlimited: Bool
    let balance: String?
    let resetCredits: Int?
}

struct AccountInfo: Equatable {
    let type: String
    let planType: String?
    let emailPresent: Bool
}

struct LocalThread: Identifiable, Equatable {
    let id: String
    let title: String
    let tokens: Int64
    let updatedAt: Date?
    let model: String?
    let cwd: String
    let archived: Bool
}

struct DailyTokenBucket: Identifiable, Equatable {
    let id: String
    let label: String
    let tokens: Int64
}

struct LocalUsage: Equatable {
    let lifetimeTokens: Int64
    let todayTokens: Int64
    let sevenDayTokens: Int64
    let threadCount: Int
    let lastUpdatedAt: Date?
    let dailyBuckets: [DailyTokenBucket]
    let recentThreads: [LocalThread]
}

enum TaskColumnKind: String, Equatable {
    case active
    case pending
    case scheduled
    case done
}

struct TaskItem: Identifiable, Equatable {
    let id: String
    let code: String
    let title: String
    let detail: String
    let chip: String
    let updatedAt: Date?
    let tokens: Int64?
    let kind: TaskColumnKind
}

struct TaskColumn: Identifiable, Equatable {
    let id: TaskColumnKind
    let title: String
    let count: Int
    let items: [TaskItem]
}

struct TaskBoard: Equatable {
    let refreshedAt: Date
    let columns: [TaskColumn]

    var totalCount: Int {
        columns.reduce(0) { $0 + $1.count }
    }
}

struct UsageSnapshot: Equatable {
    let refreshedAt: Date
    let account: AccountInfo?
    let limitId: String?
    let limitName: String?
    let primary: RateWindow?
    let secondary: RateWindow?
    let credits: CreditsInfo?
    let cloudLifetimeTokens: Int64?
    let local: LocalUsage?
    let taskBoard: TaskBoard?
    let messages: [String]

    static let empty = UsageSnapshot(
        refreshedAt: Date(),
        account: nil,
        limitId: nil,
        limitName: nil,
        primary: nil,
        secondary: nil,
        credits: nil,
        cloudLifetimeTokens: nil,
        local: nil,
        taskBoard: nil,
        messages: ["正在读取 codexU 数据"]
    )

    func replacingTaskBoard(_ taskBoard: TaskBoard?) -> UsageSnapshot {
        UsageSnapshot(
            refreshedAt: refreshedAt,
            account: account,
            limitId: limitId,
            limitName: limitName,
            primary: primary,
            secondary: secondary,
            credits: credits,
            cloudLifetimeTokens: cloudLifetimeTokens,
            local: local,
            taskBoard: taskBoard,
            messages: messages
        )
    }
}

struct DiagnosticItem: Identifiable {
    let id: String
    let title: String
    let detail: String
    let systemName: String
    let tint: Color
}

final class UsageStore: ObservableObject {
    @Published var snapshot: UsageSnapshot = .empty
    @Published var isRefreshing = false

    private var fullTimer: Timer?
    private var taskBoardTimer: Timer?
    private var isRefreshingTaskBoard = false

    func start() {
        refresh()
        fullTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        taskBoardTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            self?.refreshTaskBoard()
        }
    }

    func stop() {
        fullTimer?.invalidate()
        taskBoardTimer?.invalidate()
    }

    func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true

        DispatchQueue.global(qos: .utility).async {
            let snapshot = CodexUsageReader().load()
            DispatchQueue.main.async {
                self.snapshot = snapshot
                self.isRefreshing = false
            }
        }
    }

    private func refreshTaskBoard() {
        guard !isRefreshing, !isRefreshingTaskBoard else { return }
        isRefreshingTaskBoard = true

        DispatchQueue.global(qos: .utility).async {
            let taskBoard = CodexUsageReader().loadTaskBoard()
            DispatchQueue.main.async {
                self.snapshot = self.snapshot.replacingTaskBoard(taskBoard)
                self.isRefreshingTaskBoard = false
            }
        }
    }
}

final class CodexUsageReader {
    private let fileManager = FileManager.default

    func load() -> UsageSnapshot {
        var messages: [String] = []
        let appServer = readAppServer(messages: &messages)
        let local = readLocalUsage(messages: &messages)
        let taskBoard = readTaskBoard(messages: &messages)

        return UsageSnapshot(
            refreshedAt: Date(),
            account: appServer.account,
            limitId: appServer.limitId,
            limitName: appServer.limitName,
            primary: appServer.primary,
            secondary: appServer.secondary,
            credits: appServer.credits,
            cloudLifetimeTokens: appServer.cloudLifetimeTokens,
            local: local,
            taskBoard: taskBoard,
            messages: messages
        )
    }

    func loadTaskBoard() -> TaskBoard? {
        var messages: [String] = []
        return readTaskBoard(messages: &messages)
    }

    private struct AppServerSnapshot {
        var account: AccountInfo?
        var limitId: String?
        var limitName: String?
        var primary: RateWindow?
        var secondary: RateWindow?
        var credits: CreditsInfo?
        var cloudLifetimeTokens: Int64?
    }

    private func readAppServer(messages: inout [String]) -> AppServerSnapshot {
        guard let codexPath = firstExistingPath([
            "/Applications/Codex.app/Contents/Resources/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            "/usr/bin/codex"
        ]) else {
            messages.append("未找到 codex 可执行文件")
            return AppServerSnapshot()
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: codexPath)
        process.arguments = ["app-server"]

        let input = Pipe()
        let output = Pipe()
        let error = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = error

        do {
            try process.run()
        } catch {
            messages.append("app-server 启动失败")
            return AppServerSnapshot()
        }

        func writeMessage(_ request: [String: Any]) {
            if let data = try? JSONSerialization.data(withJSONObject: request) {
                input.fileHandleForWriting.write(data)
                input.fileHandleForWriting.write(Data("\n".utf8))
            }
        }

        let responseGroup = DispatchGroup()
        [2, 3, 4].forEach { _ in responseGroup.enter() }

        let lock = NSLock()
        var buffer = Data()
        var snapshot = AppServerSnapshot()
        var completed = Set<Int>()
        var sentAccountRequests = false
        var appServerMessages: [String] = []

        func markComplete(_ id: Int) {
            lock.lock()
            let inserted = completed.insert(id).inserted
            lock.unlock()
            if inserted {
                responseGroup.leave()
            }
        }

        func parseLine(_ lineData: Data) {
            guard
                let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                let id = object["id"] as? Int
            else { return }

            if id == 1 {
                lock.lock()
                let shouldSend = !sentAccountRequests
                sentAccountRequests = true
                lock.unlock()

                if shouldSend {
                    writeMessage(["method": "initialized"])
                    writeMessage(["id": 2, "method": "account/read", "params": ["refreshToken": false]])
                    writeMessage(["id": 3, "method": "account/rateLimits/read"])
                    writeMessage(["id": 4, "method": "account/usage/read"])
                }
                return
            }

            if let errorObject = object["error"] as? [String: Any] {
                let message = errorObject["message"] as? String ?? "未知错误"
                lock.lock()
                appServerMessages.append("app-server \(id): \(message)")
                lock.unlock()
                markComplete(id)
                return
            }

            guard let result = object["result"] as? [String: Any] else {
                markComplete(id)
                return
            }

            lock.lock()
            switch id {
            case 2:
                snapshot.account = parseAccount(result)
            case 3:
                parseRateLimits(result, into: &snapshot)
            case 4:
                snapshot.cloudLifetimeTokens = parseCloudLifetimeTokens(result)
            default:
                break
            }
            lock.unlock()

            if [2, 3, 4].contains(id) {
                markComplete(id)
            }
        }

        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }

            lock.lock()
            buffer.append(data)
            var lines: [Data] = []
            while let newline = buffer.firstIndex(of: 10) {
                lines.append(buffer.subdata(in: buffer.startIndex..<newline))
                buffer.removeSubrange(buffer.startIndex...newline)
            }
            lock.unlock()

            for line in lines where !line.isEmpty {
                parseLine(line)
            }
        }

        writeMessage([
            "id": 1,
            "method": "initialize",
            "params": [
                "clientInfo": [
                    "name": "codexu",
                    "title": "codexU",
                    "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.1"
                ],
                "capabilities": [
                    "experimentalApi": true,
                    "optOutNotificationMethods": []
                ]
            ]
        ])

        if responseGroup.wait(timeout: .now() + 12) == .timedOut {
            lock.lock()
            appServerMessages.append("app-server 响应超时")
            lock.unlock()
        }

        output.fileHandleForReading.readabilityHandler = nil
        try? input.fileHandleForWriting.close()
        if process.isRunning {
            process.terminate()
            DispatchQueue.global(qos: .utility).async {
                process.waitUntilExit()
            }
        }

        lock.lock()
        messages.append(contentsOf: appServerMessages)
        let finalSnapshot = snapshot
        lock.unlock()

        return finalSnapshot
    }

    private func parseAccount(_ result: [String: Any]) -> AccountInfo? {
        guard let account = result["account"] as? [String: Any],
              let type = account["type"] as? String else { return nil }

        return AccountInfo(
            type: type,
            planType: account["planType"] as? String,
            emailPresent: account["email"] != nil && !(account["email"] is NSNull)
        )
    }

    private func parseRateLimits(_ result: [String: Any], into snapshot: inout AppServerSnapshot) {
        let selected: [String: Any]?
        if let byId = result["rateLimitsByLimitId"] as? [String: Any],
           let codex = byId["codex"] as? [String: Any] {
            selected = codex
        } else {
            selected = result["rateLimits"] as? [String: Any]
        }

        guard let limits = selected else { return }
        snapshot.limitId = limits["limitId"] as? String
        snapshot.limitName = limits["limitName"] as? String
        snapshot.primary = parseRateWindow(limits["primary"])
        snapshot.secondary = parseRateWindow(limits["secondary"])

        var resetCredits: Int?
        if let reset = result["rateLimitResetCredits"] as? [String: Any] {
            resetCredits = intValue(reset["availableCount"])
        }

        if let credits = limits["credits"] as? [String: Any] {
            snapshot.credits = CreditsInfo(
                hasCredits: credits["hasCredits"] as? Bool ?? false,
                unlimited: credits["unlimited"] as? Bool ?? false,
                balance: stringValue(credits["balance"]),
                resetCredits: resetCredits
            )
        } else if resetCredits != nil {
            snapshot.credits = CreditsInfo(hasCredits: false, unlimited: false, balance: nil, resetCredits: resetCredits)
        }
    }

    private func parseRateWindow(_ value: Any?) -> RateWindow? {
        guard let object = value as? [String: Any],
              let used = doubleValue(object["usedPercent"])
        else { return nil }

        let resetDate: Date?
        if let timestamp = doubleValue(object["resetsAt"]) {
            resetDate = Date(timeIntervalSince1970: timestamp)
        } else {
            resetDate = nil
        }

        return RateWindow(
            usedPercent: used,
            windowDurationMins: intValue(object["windowDurationMins"]),
            resetsAt: resetDate
        )
    }

    private func parseCloudLifetimeTokens(_ result: [String: Any]) -> Int64? {
        guard let summary = result["summary"] as? [String: Any] else { return nil }
        return int64Value(summary["lifetimeTokens"])
    }

    private func readLocalUsage(messages: inout [String]) -> LocalUsage? {
        guard let dbPath = firstExistingPath([
            NSHomeDirectory() + "/.codex/state_5.sqlite",
            NSHomeDirectory() + "/.codex/sqlite/state_5.sqlite"
        ]) else {
            messages.append("未找到 Codex state_5.sqlite")
            return nil
        }

        guard let sqlitePath = firstExistingPath([
            "/usr/bin/sqlite3",
            "/opt/homebrew/bin/sqlite3",
            "/opt/homebrew/share/android-commandlinetools/platform-tools/sqlite3"
        ]) else {
            messages.append("未找到 sqlite3")
            return nil
        }

        let calendar = Calendar.current
        let now = Date()
        let dayStart = calendar.startOfDay(for: now)
        let sevenDayStart = calendar.date(byAdding: .day, value: -6, to: dayStart) ?? dayStart
        let dayFormatter = DateFormatter()
        dayFormatter.calendar = calendar
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter.dateFormat = "yyyy-MM-dd"
        let labelFormatter = DateFormatter()
        labelFormatter.calendar = calendar
        labelFormatter.locale = Locale(identifier: "zh_CN")
        labelFormatter.dateFormat = "M/d"

        let totalsQuery = """
        SELECT
          COALESCE(SUM(tokens_used), 0) AS lifetimeTokens,
          COALESCE(SUM(CASE WHEN updated_at >= \(Int(dayStart.timeIntervalSince1970)) THEN tokens_used ELSE 0 END), 0) AS todayTokens,
          COALESCE(SUM(CASE WHEN updated_at >= \(Int(sevenDayStart.timeIntervalSince1970)) THEN tokens_used ELSE 0 END), 0) AS sevenDayTokens,
          COUNT(*) AS threadCount,
          COALESCE(MAX(updated_at), 0) AS lastUpdatedAt
        FROM threads;
        """

        let recentQuery = """
        SELECT id, title, tokens_used AS tokens, updated_at AS updatedAt, model, cwd, archived
        FROM threads
        ORDER BY updated_at DESC
        LIMIT 5;
        """

        let dailyQuery = """
        SELECT date(updated_at, 'unixepoch', 'localtime') AS day, COALESCE(SUM(tokens_used), 0) AS tokens
        FROM threads
        WHERE updated_at >= \(Int(sevenDayStart.timeIntervalSince1970))
        GROUP BY day
        ORDER BY day ASC;
        """

        guard
            let totalsObject = runSQLiteJSON(sqlitePath: sqlitePath, dbPath: dbPath, query: totalsQuery).first,
            let recentObjects = Optional(runSQLiteJSON(sqlitePath: sqlitePath, dbPath: dbPath, query: recentQuery)),
            let dailyObjects = Optional(runSQLiteJSON(sqlitePath: sqlitePath, dbPath: dbPath, query: dailyQuery))
        else {
            messages.append("SQLite 查询失败")
            return nil
        }

        let recent = recentObjects.map { object in
            LocalThread(
                id: object["id"] as? String ?? UUID().uuidString,
                title: object["title"] as? String ?? "Untitled",
                tokens: int64Value(object["tokens"]) ?? 0,
                updatedAt: dateFromEpoch(object["updatedAt"]),
                model: object["model"] as? String,
                cwd: object["cwd"] as? String ?? "",
                archived: (intValue(object["archived"]) ?? 0) != 0
            )
        }

        let tokensByDay = Dictionary(uniqueKeysWithValues: dailyObjects.compactMap { object -> (String, Int64)? in
            guard let day = object["day"] as? String else { return nil }
            return (day, int64Value(object["tokens"]) ?? 0)
        })

        let dailyBuckets = (0..<7).compactMap { index -> DailyTokenBucket? in
            guard let date = calendar.date(byAdding: .day, value: index - 6, to: dayStart) else { return nil }
            let key = dayFormatter.string(from: date)
            return DailyTokenBucket(
                id: key,
                label: index == 6 ? "今天" : labelFormatter.string(from: date),
                tokens: tokensByDay[key] ?? 0
            )
        }

        return LocalUsage(
            lifetimeTokens: int64Value(totalsObject["lifetimeTokens"]) ?? 0,
            todayTokens: int64Value(totalsObject["todayTokens"]) ?? 0,
            sevenDayTokens: int64Value(totalsObject["sevenDayTokens"]) ?? 0,
            threadCount: intValue(totalsObject["threadCount"]) ?? 0,
            lastUpdatedAt: dateFromEpoch(totalsObject["lastUpdatedAt"]),
            dailyBuckets: dailyBuckets,
            recentThreads: recent
        )
    }

    private func readTaskBoard(messages: inout [String]) -> TaskBoard? {
        let calendar = Calendar.current
        let now = Date()
        let dayStart = calendar.startOfDay(for: now)
        let activeCutoff = now.addingTimeInterval(-2 * 60 * 60)

        var activeItems: [TaskItem] = []
        var pendingItems: [TaskItem] = []
        var doneItems: [TaskItem] = []

        if let dbPath = firstExistingPath([
            NSHomeDirectory() + "/.codex/state_5.sqlite",
            NSHomeDirectory() + "/.codex/sqlite/state_5.sqlite"
        ]), let sqlitePath = firstExistingPath([
            "/usr/bin/sqlite3",
            "/opt/homebrew/bin/sqlite3",
            "/opt/homebrew/share/android-commandlinetools/platform-tools/sqlite3"
        ]) {
            let todayThreadsQuery = """
            SELECT id, title, preview, cwd, tokens_used AS tokens, updated_at AS updatedAt, recency_at AS recencyAt, model
            FROM threads
            WHERE archived = 0
              AND preview <> ''
              AND (
                updated_at >= \(Int(dayStart.timeIntervalSince1970))
                OR recency_at >= \(Int(dayStart.timeIntervalSince1970))
                OR created_at >= \(Int(dayStart.timeIntervalSince1970))
              )
            ORDER BY recency_at DESC, updated_at DESC
            LIMIT 24;
            """

            let archivedTodayQuery = """
            SELECT id, title, preview, cwd, tokens_used AS tokens, COALESCE(archived_at, updated_at) AS updatedAt, model
            FROM threads
            WHERE archived = 1
              AND COALESCE(archived_at, updated_at) >= \(Int(dayStart.timeIntervalSince1970))
            ORDER BY COALESCE(archived_at, updated_at) DESC
            LIMIT 12;
            """

            let todayThreads = runSQLiteJSON(sqlitePath: sqlitePath, dbPath: dbPath, query: todayThreadsQuery)
            for object in todayThreads {
                let updatedAt = dateFromEpoch(object["recencyAt"]) ?? dateFromEpoch(object["updatedAt"])
                let kind: TaskColumnKind = (updatedAt ?? .distantPast) >= activeCutoff ? .active : .pending
                let item = makeThreadTaskItem(object: object, updatedAt: updatedAt, kind: kind)
                if kind == .active {
                    activeItems.append(item)
                } else {
                    pendingItems.append(item)
                }
            }

            doneItems = runSQLiteJSON(sqlitePath: sqlitePath, dbPath: dbPath, query: archivedTodayQuery).map { object in
                makeThreadTaskItem(object: object, updatedAt: dateFromEpoch(object["updatedAt"]), kind: .done)
            }
        } else {
            messages.append("任务看板未找到 SQLite 数据源")
        }

        let scheduledItems = readAutomationTasks()

        return TaskBoard(refreshedAt: Date(), columns: [
            TaskColumn(id: .active, title: "进行中", count: activeItems.count, items: Array(activeItems.prefix(3))),
            TaskColumn(id: .pending, title: "待处理", count: pendingItems.count, items: Array(pendingItems.prefix(3))),
            TaskColumn(id: .scheduled, title: "定时", count: scheduledItems.count, items: Array(scheduledItems.prefix(3))),
            TaskColumn(id: .done, title: "完成", count: doneItems.count, items: Array(doneItems.prefix(3)))
        ])
    }

    private func makeThreadTaskItem(object: [String: Any], updatedAt: Date?, kind: TaskColumnKind) -> TaskItem {
        let rawId = object["id"] as? String ?? UUID().uuidString
        let title = normalizedTitle(object["title"] as? String, fallback: object["preview"] as? String)
        let cwd = object["cwd"] as? String ?? ""
        let tokens = int64Value(object["tokens"]) ?? 0
        let compactId = rawId.replacingOccurrences(of: "-", with: "")
        let code = "COD-" + compactId.suffix(4).uppercased()
        let chip: String

        switch kind {
        case .active:
            chip = tokens >= 5_000_000 ? "High" : "Active"
        case .pending:
            chip = tokens >= 2_000_000 ? "Medium" : "Idle"
        case .scheduled:
            chip = "Cron"
        case .done:
            chip = "Done"
        }

        let detailParts = [
            shortWorkspaceName(cwd),
            tokens > 0 ? formatTokens(tokens) : nil
        ].compactMap { $0 }.filter { !$0.isEmpty }

        return TaskItem(
            id: rawId + kind.rawValue,
            code: String(code),
            title: title,
            detail: detailParts.joined(separator: " · "),
            chip: chip,
            updatedAt: updatedAt,
            tokens: tokens,
            kind: kind
        )
    }

    private func readAutomationTasks() -> [TaskItem] {
        let root = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex/automations")
        guard let enumerator = fileManager.enumerator(at: root, includingPropertiesForKeys: nil) else {
            return []
        }

        var items: [TaskItem] = []
        for case let url as URL in enumerator where url.lastPathComponent == "automation.toml" {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let fields = parseSimpleTOML(text)
            guard (fields["status"] ?? "").uppercased() == "ACTIVE" else { continue }

            let id = fields["id"] ?? url.deletingLastPathComponent().lastPathComponent
            let name = fields["name"] ?? id
            let kind = fields["kind"] ?? "cron"
            let schedule = scheduleSummary(fields["rrule"])
            let detail = [kind.uppercased(), schedule].filter { !$0.isEmpty }.joined(separator: " · ")

            items.append(TaskItem(
                id: "automation-" + id,
                code: "AUTO-" + id.prefix(4).uppercased(),
                title: name,
                detail: detail,
                chip: kind == "heartbeat" ? "Wake" : "Cron",
                updatedAt: dateFromEpoch(fields["updated_at"]),
                tokens: nil,
                kind: .scheduled
            ))
        }

        return items.sorted { $0.title < $1.title }
    }

    private func runSQLiteJSON(sqlitePath: String, dbPath: String, query: String) -> [[String: Any]] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: sqlitePath)
        process.arguments = ["-readonly", "-json", dbPath, query]

        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error

        do {
            try process.run()
        } catch {
            return []
        }

        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard
            process.terminationStatus == 0,
            let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }

        return json
    }

    private func firstExistingPath(_ paths: [String]) -> String? {
        paths.first { fileManager.isExecutableFile(atPath: $0) || fileManager.fileExists(atPath: $0) }
    }
}

private func parseSimpleTOML(_ text: String) -> [String: String] {
    var fields: [String: String] = [:]

    for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty, !line.hasPrefix("#"), let separator = line.firstIndex(of: "=") else {
            continue
        }

        let key = line[..<separator].trimmingCharacters(in: .whitespacesAndNewlines)
        var value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)

        if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
            value.removeFirst()
            value.removeLast()
        }

        fields[key] = value
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\\"", with: "\"")
    }

    return fields
}

private func normalizedTitle(_ title: String?, fallback: String?) -> String {
    let raw = [title, fallback]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .first { !$0.isEmpty } ?? "Untitled"

    let singleLine = raw
        .replacingOccurrences(of: "\n", with: " ")
        .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)

    if singleLine.count <= 48 { return singleLine }
    return String(singleLine.prefix(45)) + "..."
}

private func shortWorkspaceName(_ path: String) -> String {
    guard !path.isEmpty else { return "" }
    let url = URL(fileURLWithPath: path)
    let name = url.lastPathComponent
    if !name.isEmpty { return name }
    return path
}

private func relativeTimeText(_ date: Date) -> String {
    let seconds = max(0, Int(Date().timeIntervalSince(date)))
    if seconds < 60 { return "刚刚" }
    let minutes = seconds / 60
    if minutes < 60 { return "\(minutes) 分钟前" }
    let hours = minutes / 60
    if hours < 24 { return "\(hours) 小时前" }
    return "\(hours / 24) 天前"
}

private func scheduleSummary(_ rrule: String?) -> String {
    guard let rrule, !rrule.isEmpty else { return "" }

    var timeText = ""
    if let range = rrule.range(of: #"T(\d{2})(\d{2})(\d{2})"#, options: .regularExpression) {
        let match = String(rrule[range])
        let start = match.index(after: match.startIndex)
        let hourEnd = match.index(start, offsetBy: 2)
        let minuteEnd = match.index(hourEnd, offsetBy: 2)
        timeText = "\(match[start..<hourEnd]):\(match[hourEnd..<minuteEnd])"
    }

    if rrule.contains("FREQ=DAILY") {
        return timeText.isEmpty ? "每天" : "每天 \(timeText)"
    }
    if rrule.contains("FREQ=WEEKLY") {
        return timeText.isEmpty ? "每周" : "每周 \(timeText)"
    }
    if rrule.contains("FREQ=HOURLY") {
        return "每小时"
    }
    return timeText
}

private func intValue(_ value: Any?) -> Int? {
    if let int = value as? Int { return int }
    if let int64 = value as? Int64 { return Int(int64) }
    if let double = value as? Double { return Int(double) }
    if let string = value as? String { return Int(string) }
    return nil
}

private func int64Value(_ value: Any?) -> Int64? {
    if let int = value as? Int { return Int64(int) }
    if let int64 = value as? Int64 { return int64 }
    if let double = value as? Double { return Int64(double) }
    if let string = value as? String { return Int64(string) }
    return nil
}

private func doubleValue(_ value: Any?) -> Double? {
    if let double = value as? Double { return double }
    if let int = value as? Int { return Double(int) }
    if let int64 = value as? Int64 { return Double(int64) }
    if let string = value as? String { return Double(string) }
    return nil
}

private func stringValue(_ value: Any?) -> String? {
    if let string = value as? String { return string }
    if let number = value as? NSNumber { return number.stringValue }
    return nil
}

private func dateFromEpoch(_ value: Any?) -> Date? {
    guard var seconds = doubleValue(value), seconds > 0 else { return nil }
    if seconds > 10_000_000_000 {
        seconds /= 1000
    }
    return Date(timeIntervalSince1970: seconds)
}

struct UsageWidgetView: View {
    @ObservedObject var store: UsageStore

    static let widgetWidth: CGFloat = 820
    static let widgetDefaultHeight: CGFloat = 620
    static let widgetMinHeight: CGFloat = 540
    static let widgetMaxHeight: CGFloat = 820

    private var snapshot: UsageSnapshot { store.snapshot }
    private var primary: RateWindow? { snapshot.primary }

    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: 10) {
                widgetContent
                    .glassEffect(
                        .regular.tint(Color.primary.opacity(0.025)),
                        in: .rect(cornerRadius: 24, style: .continuous)
                    )
            }
        } else {
            widgetContent
        }
    }

    private var widgetContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 12) {
                    if shouldShowEnvironmentChecklist {
                        environmentChecklistSection
                    }
                    usageOverviewSection
                    taskBoardSection
                }
                .padding(.bottom, 2)
            }
            footer
        }
        .padding(.horizontal, 16)
        .padding(.top, 18)
        .padding(.bottom, 14)
        .frame(width: Self.widgetWidth, alignment: .topLeading)
        .frame(minHeight: Self.widgetMinHeight, maxHeight: .infinity, alignment: .topLeading)
    }

    private var header: some View {
        HStack(spacing: 10) {
            HStack(spacing: 9) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 34, height: 34)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .accessibilityHidden(true)
                Text("codexU")
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
            }
            Spacer()
            accountPill
            planPill
            iconButton(systemName: store.isRefreshing ? "hourglass" : "arrow.clockwise") {
                store.refresh()
            }
            iconButton(systemName: "xmark") {
                NSApp.terminate(nil)
            }
        }
    }

    private var environmentChecklistSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(title: "环境检查", detail: "首次使用")
            ForEach(environmentDiagnostics) { item in
                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: item.systemName)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(item.tint)
                        .frame(width: 18, height: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title)
                            .font(.system(size: 11, weight: .semibold))
                        Text(item.detail)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                }
            }
        }
        .padding(12)
        .sectionBackground()
    }

    private var planPill: some View {
        statusPill(planLabel)
    }

    private var accountPill: some View {
        statusPill(accountLabel)
    }

    private func statusPill(_ label: String) -> some View {
        Text(label)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.primary.opacity(0.07))
            )
    }

    private func iconButton(systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .iconButtonStyle()
        .foregroundStyle(.secondary)
    }

    private var usageOverviewSection: some View {
        HStack(alignment: .center, spacing: 26) {
            GaugeRing(
                percent: primary?.remainingPercent ?? 0,
                available: primary != nil,
                lineWidth: 13
            )
            .frame(width: 145, height: 145)
            .overlay {
                VStack(spacing: 3) {
                    Text(primaryText)
                        .font(.system(size: 38, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    Text("剩余额度")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 13) {
                VStack(alignment: .leading, spacing: 11) {
                    WindowRow(title: "5 小时额度窗口", window: snapshot.primary, accent: Color(red: 0.08, green: 0.62, blue: 0.48))
                    WindowRow(title: "7 天额度窗口", window: snapshot.secondary, accent: Color(red: 0.18, green: 0.44, blue: 0.72))
                }

                HStack(spacing: 12) {
                    TokenMetricCard(title: "今日", value: formatTokens(snapshot.local?.todayTokens), tint: Color(red: 0.08, green: 0.62, blue: 0.48))
                    TokenMetricCard(title: "近 7 天", value: formatTokens(snapshot.local?.sevenDayTokens), tint: Color(red: 0.92, green: 0.58, blue: 0.12))
                    TokenMetricCard(title: "累计", value: formatTokens(snapshot.local?.lifetimeTokens), tint: Color(red: 0.18, green: 0.44, blue: 0.72))
                    MiniTrendCard(buckets: snapshot.local?.dailyBuckets ?? [])
                }
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 16)
        .sectionBackground()
    }

    private var quotaSection: some View {
        HStack(spacing: 14) {
            GaugeRing(
                percent: primary?.remainingPercent ?? 0,
                available: primary != nil,
                lineWidth: 9
            )
            .frame(width: 86, height: 86)
            .overlay {
                VStack(spacing: 0) {
                    Text(primaryText)
                        .font(.system(size: 23, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    Text("5h 剩余")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                SectionTitle(title: "账户额度", detail: quotaDetail)
                WindowRow(title: "5 小时", window: snapshot.primary, accent: Color(red: 0.08, green: 0.62, blue: 0.48))
                WindowRow(title: "7 天", window: snapshot.secondary, accent: Color(red: 0.18, green: 0.44, blue: 0.72))
            }
        }
        .padding(12)
        .sectionBackground()
    }

    private var tokenSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(title: "Token 消耗", detail: localThreadCountLabel)

            HStack(alignment: .firstTextBaseline, spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("今日")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(formatTokens(snapshot.local?.todayTokens))
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                }
                Spacer(minLength: 10)
                VStack(alignment: .trailing, spacing: 3) {
                    Text("累计")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(formatTokens(snapshot.local?.lifetimeTokens))
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                }
            }

            HStack {
                Text("近 7 天合计")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(formatTokens(snapshot.local?.sevenDayTokens))
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .monospacedDigit()
            }
        }
        .padding(12)
        .sectionBackground()
    }

    private var dailyTokenSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(title: "每日 Token", detail: "近 7 天")
            DailyTokenChart(buckets: snapshot.local?.dailyBuckets ?? [])
        }
        .padding(12)
        .sectionBackground()
    }

    private var taskBoardSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(title: "今日任务看板", detail: taskBoardSummary)
            HStack(alignment: .top, spacing: 8) {
                ForEach(taskBoardColumns) { column in
                    TaskBoardColumnView(column: column)
                        .frame(maxWidth: .infinity, alignment: .top)
                }
            }
        }
        .padding(12)
        .sectionBackground()
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 7, height: 7)
            Text(statusText)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            Text("刷新 \(timeOnly(snapshot.refreshedAt))")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            Text("⌘U")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
    }

    private var accountLabel: String {
        guard let account = snapshot.account else { return "本机统计模式" }
        if account.type == "chatgpt" {
            return account.emailPresent ? "ChatGPT 登录" : "ChatGPT"
        }
        return account.type
    }

    private var planLabel: String {
        snapshot.account?.planType?.uppercased() ?? "LOCAL"
    }

    private var primaryText: String {
        guard let primary else { return "--" }
        return "\(Int(primary.remainingPercent.rounded()))%"
    }

    private var creditsLabel: String {
        guard let credits = snapshot.credits else { return "--" }
        if credits.unlimited { return "∞" }
        return credits.balance ?? (credits.hasCredits ? "yes" : "0")
    }

    private var resetCreditsLabel: String {
        guard let count = snapshot.credits?.resetCredits else { return "--" }
        return "\(count)"
    }

    private var quotaDetail: String {
        guard let reset = snapshot.primary?.resetsAt else { return "额度状态" }
        return "5h 重置 \(timeOnly(reset))"
    }

    private var localThreadCountLabel: String {
        guard let count = snapshot.local?.threadCount else { return "本机统计" }
        return "\(count) 线程"
    }

    private var taskBoardSummary: String {
        guard let board = snapshot.taskBoard else { return "读取中" }
        return "\(board.totalCount) 事项 · \(timeOnly(board.refreshedAt))"
    }

    private var taskBoardColumns: [TaskColumn] {
        snapshot.taskBoard?.columns ?? [
            TaskColumn(id: .active, title: "进行中", count: 0, items: []),
            TaskColumn(id: .pending, title: "待处理", count: 0, items: []),
            TaskColumn(id: .scheduled, title: "定时", count: 0, items: []),
            TaskColumn(id: .done, title: "完成", count: 0, items: [])
        ]
    }

    private var shouldShowEnvironmentChecklist: Bool {
        if snapshot.messages.contains("正在读取 codexU 数据") { return false }
        return (!snapshot.messages.isEmpty && (snapshot.primary == nil || snapshot.local == nil))
            || snapshot.account == nil
            || snapshot.local == nil
    }

    private var environmentDiagnostics: [DiagnosticItem] {
        var items: [DiagnosticItem] = []
        let messages = snapshot.messages.joined(separator: "\n")

        if snapshot.primary == nil || snapshot.account == nil {
            if messages.contains("未找到 codex") {
                items.append(DiagnosticItem(
                    id: "codex-missing",
                    title: "未找到 Codex",
                    detail: "请先安装 Codex App，或确认 codex CLI 位于 /Applications/Codex.app、/opt/homebrew/bin 或 /usr/local/bin。",
                    systemName: "magnifyingglass",
                    tint: Color(red: 0.86, green: 0.55, blue: 0.18)
                ))
            } else if messages.contains("app-server") {
                items.append(DiagnosticItem(
                    id: "app-server",
                    title: "Codex 账户接口暂不可用",
                    detail: "确认 Codex 已登录后点击刷新；本机 token 统计仍可继续显示。",
                    systemName: "exclamationmark.triangle.fill",
                    tint: Color(red: 0.86, green: 0.55, blue: 0.18)
                ))
            } else {
                items.append(DiagnosticItem(
                    id: "quota-unavailable",
                    title: "账户额度读取中",
                    detail: "如果长时间无数据，请确认 Codex 已安装并完成登录。",
                    systemName: "person.crop.circle.badge.questionmark",
                    tint: Color(red: 0.18, green: 0.44, blue: 0.72)
                ))
            }
        }

        if snapshot.local == nil {
            if messages.contains("state_5.sqlite") {
                items.append(DiagnosticItem(
                    id: "sqlite-db",
                    title: "未找到本机 Codex 统计库",
                    detail: "打开 Codex 并至少完成一次会话后，再回到小组件点击刷新。",
                    systemName: "externaldrive.badge.questionmark",
                    tint: Color(red: 0.86, green: 0.55, blue: 0.18)
                ))
            } else if messages.contains("sqlite3") {
                items.append(DiagnosticItem(
                    id: "sqlite-cli",
                    title: "未找到 sqlite3",
                    detail: "请安装 macOS Command Line Tools，或通过 Homebrew 安装 sqlite。",
                    systemName: "terminal",
                    tint: Color(red: 0.86, green: 0.55, blue: 0.18)
                ))
            } else {
                items.append(DiagnosticItem(
                    id: "local-usage",
                    title: "本机统计暂不可用",
                    detail: "本机 token 和任务看板依赖 ~/.codex 的本地状态文件。",
                    systemName: "chart.bar.doc.horizontal",
                    tint: Color(red: 0.18, green: 0.44, blue: 0.72)
                ))
            }
        }

        if items.isEmpty {
            items = snapshot.messages.prefix(3).enumerated().map { index, message in
                DiagnosticItem(
                    id: "message-\(index)",
                    title: "运行提示",
                    detail: message,
                    systemName: "info.circle.fill",
                    tint: Color(red: 0.18, green: 0.44, blue: 0.72)
                )
            }
        }

        return items
    }

    private var statusColor: Color {
        if primary == nil { return Color(red: 0.86, green: 0.55, blue: 0.18) }
        if (primary?.remainingPercent ?? 0) < 15 { return Color(red: 0.82, green: 0.22, blue: 0.18) }
        return Color(red: 0.08, green: 0.62, blue: 0.48)
    }

    private var statusText: String {
        if let first = snapshot.messages.first { return first }
        if snapshot.primary != nil { return "app-server + SQLite" }
        return "SQLite only"
    }
}

struct SectionTitle: View {
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
            Spacer()
            Text(detail)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }
}

struct SectionBackgroundModifier: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
                .glassEffect(
                    .regular.tint(Color.primary.opacity(0.035)),
                    in: .rect(cornerRadius: 18, style: .continuous)
                )
        } else {
            content
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.primary.opacity(0.045))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(Color.primary.opacity(0.055), lineWidth: 0.8)
                        )
                )
        }
    }
}

extension View {
    func sectionBackground() -> some View {
        modifier(SectionBackgroundModifier())
    }

    func iconButtonStyle() -> some View {
        modifier(IconButtonStyleModifier())
    }
}

struct IconButtonStyleModifier: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
                .buttonStyle(.glass)
        } else {
            content
                .buttonStyle(.plain)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.primary.opacity(0.07))
                )
        }
    }
}

struct GaugeRing: View {
    let percent: Double
    let available: Bool
    let lineWidth: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.16), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: available ? CGFloat(max(0, min(1, percent / 100))) : 0.0)
                .stroke(
                    AngularGradient(
                        colors: [
                            Color(red: 0.08, green: 0.62, blue: 0.48),
                            Color(red: 0.67, green: 0.86, blue: 0.42),
                            Color(red: 0.18, green: 0.44, blue: 0.72),
                            Color(red: 0.08, green: 0.62, blue: 0.48)
                        ],
                        center: .center
                    ),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
        }
    }
}

struct DailyTokenChart: View {
    let buckets: [DailyTokenBucket]

    private var maxTokens: Int64 {
        max(buckets.map(\.tokens).max() ?? 0, 1)
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 6) {
            ForEach(buckets) { bucket in
                DailyTokenBar(bucket: bucket, maxTokens: maxTokens)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 112)
    }
}

struct DailyTokenBar: View {
    let bucket: DailyTokenBucket
    let maxTokens: Int64

    private var barHeight: CGFloat {
        let ratio = Double(bucket.tokens) / Double(maxTokens)
        return max(4, CGFloat(ratio) * 54)
    }

    var body: some View {
        VStack(spacing: 5) {
            Text(formatTokens(bucket.tokens))
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.72)
                .foregroundStyle(.secondary)
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.white.opacity(0.12))
                    .frame(height: 58)
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(bucket.tokens == 0 ? Color.white.opacity(0.22) : Color(red: 0.08, green: 0.62, blue: 0.48))
                    .frame(height: barHeight)
            }
            Text(bucket.label)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(bucket.label == "今天" ? .primary : .secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }
}

struct WindowRow: View {
    let title: String
    let window: RateWindow?
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                Spacer()
                Text(detail)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.white.opacity(0.14))
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(accent)
                        .frame(width: max(4, geometry.size.width * CGFloat((window?.usedPercent ?? 0) / 100)))
                }
            }
            .frame(height: 6)
        }
    }

    private var detail: String {
        guard let window else { return "--" }
        let used = formatUsagePercent(window.usedPercent)
        if let resetsAt = window.resetsAt {
            return "已用 \(used) · \(resetDateTime(resetsAt)) 重置"
        }
        return "已用 \(used)"
    }
}

struct TokenMetricCard: View {
    let title: String
    let value: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle()
                    .fill(tint)
                    .frame(width: 7, height: 7)
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Text(value)
                .font(.system(size: 21, weight: .bold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.72)
            Text("Tokens")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 78, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.13))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.8)
                )
        )
    }
}

struct MiniTrendCard: View {
    let buckets: [DailyTokenBucket]

    private var maxTokens: Int64 {
        max(buckets.map(\.tokens).max() ?? 0, 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("近 7 天使用趋势")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            HStack(alignment: .bottom, spacing: 6) {
                ForEach(buckets) { bucket in
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(bucket.tokens == 0 ? Color(red: 0.56, green: 0.68, blue: 0.82).opacity(0.35) : Color(red: 0.18, green: 0.48, blue: 0.84).opacity(bucket.label == "今天" ? 1 : 0.55))
                        .frame(width: 12, height: miniBarHeight(bucket.tokens))
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)

            HStack {
                Text("一")
                Spacer()
                Text("三")
                Spacer()
                Text("五")
                Spacer()
                Text("今")
            }
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(.secondary)
        }
        .padding(10)
        .frame(width: 132, alignment: .leading)
        .frame(minHeight: 78, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.13))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.8)
                )
        )
    }

    private func miniBarHeight(_ tokens: Int64) -> CGFloat {
        let ratio = Double(tokens) / Double(maxTokens)
        return max(6, CGFloat(ratio) * 34)
    }
}

struct TaskBoardColumnView: View {
    let column: TaskColumn

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: taskColumnIcon(column.id))
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(taskAccentColor(column.id))
                Text(column.title)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                Text("\(column.count)")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Image(systemName: "ellipsis")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }

            if column.items.isEmpty {
                VStack(spacing: 5) {
                    Image(systemName: "circle.dashed")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.tertiary)
                    Text("暂无")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 66)
            } else {
                ForEach(column.items) { item in
                    TaskIssueCard(item: item)
                }
                if column.count > column.items.count {
                    Text("+ \(column.count - column.items.count) more")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                        .padding(.leading, 6)
                }
            }
        }
        .padding(8)
        .frame(minHeight: 274, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(taskColumnFill(column.id))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(taskAccentColor(column.id).opacity(0.12), lineWidth: 0.8)
                )
        )
    }
}

struct TaskIssueCard: View {
    let item: TaskItem

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(item.code)
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                if let updatedAt = item.updatedAt {
                    Text(relativeTimeText(updatedAt))
                        .font(.system(size: 8, weight: .medium))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }

            Text(item.title)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .minimumScaleFactor(0.9)

            if !item.detail.isEmpty {
                Text(item.detail)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            HStack(spacing: 5) {
                TaskChip(text: item.chip, kind: item.kind)
                Spacer(minLength: 4)
                TaskAvatar(text: taskAvatarText(item), kind: item.kind)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.68))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.8)
                )
        )
    }
}

struct TaskAvatar: View {
    let text: String
    let kind: TaskColumnKind

    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .bold, design: .rounded))
            .foregroundStyle(taskAccentColor(kind).opacity(0.85))
            .frame(width: 18, height: 18)
            .background(
                Circle()
                    .fill(Color.primary.opacity(0.08))
            )
    }
}

struct TaskChip: View {
    let text: String
    let kind: TaskColumnKind

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: chipIcon)
                .font(.system(size: 8, weight: .bold))
            Text(text)
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .lineLimit(1)
        }
        .foregroundStyle(chipColor)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(
            Capsule(style: .continuous)
                .fill(chipColor.opacity(0.13))
        )
    }

    private var chipColor: Color {
        switch text.lowercased() {
        case "high", "urgent":
            return Color(red: 0.9, green: 0.36, blue: 0.06)
        case "medium":
            return Color(red: 0.86, green: 0.55, blue: 0.12)
        case "active":
            return Color(red: 0.05, green: 0.55, blue: 0.32)
        case "cron", "wake":
            return Color(red: 0.37, green: 0.39, blue: 0.74)
        case "done":
            return Color(red: 0.06, green: 0.43, blue: 0.76)
        default:
            return taskAccentColor(kind)
        }
    }

    private var chipIcon: String {
        switch text.lowercased() {
        case "cron", "wake":
            return "clock.fill"
        case "done":
            return "checkmark.circle.fill"
        default:
            return "chart.bar.fill"
        }
    }
}

struct InfoChip: View {
    let title: String
    let value: String

    var body: some View {
        HStack(spacing: 5) {
            Text(title)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .monospacedDigit()
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.white.opacity(0.13))
        )
    }
}

struct MetricTile: View {
    let title: String
    let value: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Circle()
                    .fill(tint)
                    .frame(width: 6, height: 6)
                Text(title)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            Text(value)
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.12))
        )
    }
}

private func formatTokens(_ value: Int64?) -> String {
    guard let value else { return "--" }
    let absValue = abs(Double(value))
    if absValue >= 1_000_000 {
        return String(format: "%.1fM", Double(value) / 1_000_000)
    }
    if absValue >= 1_000 {
        return String(format: "%.1fK", Double(value) / 1_000)
    }
    return "\(value)"
}

private func formatUsagePercent(_ value: Double) -> String {
    if value > 0, value < 1 {
        return "<1%"
    }
    return "\(Int(value.rounded()))%"
}

private func taskAccentColor(_ kind: TaskColumnKind) -> Color {
    switch kind {
    case .active:
        return Color(red: 0.88, green: 0.50, blue: 0.05)
    case .pending:
        return Color(red: 0.40, green: 0.43, blue: 0.48)
    case .scheduled:
        return Color(red: 0.07, green: 0.55, blue: 0.31)
    case .done:
        return Color(red: 0.07, green: 0.43, blue: 0.78)
    }
}

private func taskColumnFill(_ kind: TaskColumnKind) -> Color {
    taskAccentColor(kind).opacity(0.065)
}

private func taskColumnIcon(_ kind: TaskColumnKind) -> String {
    switch kind {
    case .active:
        return "record.circle"
    case .pending:
        return "circle"
    case .scheduled:
        return "clock"
    case .done:
        return "checkmark.circle.fill"
    }
}

private func taskAvatarText(_ item: TaskItem) -> String {
    if item.code.hasPrefix("AUTO") { return "B" }
    let source = item.detail.split(separator: "·").first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if let first = source.first {
        return String(first).uppercased()
    }
    return "C"
}

private func timeOnly(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_CN")
    formatter.dateFormat = "HH:mm"
    return formatter.string(from: date)
}

private func resetDateTime(_ date: Date) -> String {
    if Calendar.current.isDateInToday(date) {
        return timeOnly(date)
    }

    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_CN")
    formatter.dateFormat = "M/d HH:mm"
    return formatter.string(from: date)
}

private func isoString(_ date: Date?) -> String? {
    guard let date else { return nil }
    let formatter = ISO8601DateFormatter()
    return formatter.string(from: date)
}

private func jsonValue<T>(_ value: T?) -> Any {
    value.map { $0 as Any } ?? NSNull()
}

private func dumpJSON(_ snapshot: UsageSnapshot) {
    var object: [String: Any] = [
        "refreshedAt": isoString(snapshot.refreshedAt) ?? "",
        "messages": snapshot.messages
    ]

    if let account = snapshot.account {
        object["account"] = [
            "type": account.type,
            "planType": jsonValue(account.planType),
            "emailPresent": account.emailPresent
        ] as [String: Any]
    }

    if let primary = snapshot.primary {
        object["primary"] = [
            "usedPercent": primary.usedPercent,
            "remainingPercent": primary.remainingPercent,
            "windowDurationMins": jsonValue(primary.windowDurationMins),
            "resetsAt": jsonValue(isoString(primary.resetsAt))
        ] as [String: Any]
    }

    if let secondary = snapshot.secondary {
        object["secondary"] = [
            "usedPercent": secondary.usedPercent,
            "remainingPercent": secondary.remainingPercent,
            "windowDurationMins": jsonValue(secondary.windowDurationMins),
            "resetsAt": jsonValue(isoString(secondary.resetsAt))
        ] as [String: Any]
    }

    if let credits = snapshot.credits {
        object["credits"] = [
            "hasCredits": credits.hasCredits,
            "unlimited": credits.unlimited,
            "balance": jsonValue(credits.balance),
            "resetCredits": jsonValue(credits.resetCredits)
        ] as [String: Any]
    }

    if let local = snapshot.local {
        object["local"] = [
            "todayTokens": local.todayTokens,
            "sevenDayTokens": local.sevenDayTokens,
            "lifetimeTokens": local.lifetimeTokens,
            "threadCount": local.threadCount,
            "lastUpdatedAt": jsonValue(isoString(local.lastUpdatedAt)),
            "dailyBuckets": local.dailyBuckets.map { bucket in
                [
                    "day": bucket.id,
                    "label": bucket.label,
                    "tokens": bucket.tokens
                ] as [String: Any]
            }
        ] as [String: Any]
    }

    if let taskBoard = snapshot.taskBoard {
        object["taskBoard"] = [
            "refreshedAt": isoString(taskBoard.refreshedAt) ?? "",
            "totalCount": taskBoard.totalCount,
            "columns": taskBoard.columns.map { column in
                [
                    "id": column.id.rawValue,
                    "title": column.title,
                    "count": column.count,
                    "items": column.items.map { item in
                        [
                            "id": item.id,
                            "code": item.code,
                            "title": item.title,
                            "detail": item.detail,
                            "chip": item.chip,
                            "updatedAt": jsonValue(isoString(item.updatedAt)),
                            "tokens": jsonValue(item.tokens)
                        ] as [String: Any]
                    }
                ] as [String: Any]
            }
        ] as [String: Any]
    }

    if let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
       let text = String(data: data, encoding: .utf8) {
        print(text)
    }
}

private func fourCharCode(_ value: String) -> OSType {
    value.utf8.reduce(0) { result, byte in
        (result << 8) + OSType(byte)
    }
}

private func debugLog(_ message: String) {
    guard ProcessInfo.processInfo.environment["CODEX_USAGE_WIDGET_DEBUG"] == "1" else { return }

    let formatter = ISO8601DateFormatter()
    let line = "\(formatter.string(from: Date())) \(message)\n"
    let url = URL(fileURLWithPath: "/tmp/codexu.log")

    guard let data = line.data(using: .utf8) else { return }

    if FileManager.default.fileExists(atPath: url.path),
       let handle = try? FileHandle(forWritingTo: url) {
        handle.seekToEndOfFile()
        handle.write(data)
        try? handle.close()
    } else {
        try? data.write(to: url, options: .atomic)
    }
}

private func firstExecutablePath(_ paths: [String]) -> String? {
    paths.first { FileManager.default.isExecutableFile(atPath: $0) }
}

final class DraggableHostingView<Content: View>: NSHostingView<Content> {
    override var mouseDownCanMoveWindow: Bool { true }
}

final class GlassHostingContainer<Content: View>: NSView {
    private let cornerRadius: CGFloat

    init(rootView: Content, cornerRadius: CGFloat) {
        self.cornerRadius = cornerRadius
        super.init(frame: .zero)

        wantsLayer = true
        layer?.cornerRadius = cornerRadius

        let host = DraggableHostingView(rootView: rootView)
        host.frame = bounds
        host.autoresizingMask = [.width, .height]

        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: bounds)
            glass.autoresizingMask = [.width, .height]
            glass.cornerRadius = cornerRadius
            glass.style = .clear
            glass.tintColor = nil
            glass.contentView = host
            addSubview(glass)
        } else {
            let material = NSVisualEffectView(frame: bounds)
            material.autoresizingMask = [.width, .height]
            material.material = .hudWindow
            material.blendingMode = .behindWindow
            material.state = .active
            material.wantsLayer = true
            material.layer?.cornerRadius = cornerRadius
            material.layer?.masksToBounds = true
            material.addSubview(host)
            addSubview(material)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var mouseDownCanMoveWindow: Bool { true }
}

final class DesktopWidgetWindow: NSPanel {
    private static let desktopLevel = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1)

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .resizable],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true
        isMovableByWindowBackground = true
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        level = Self.desktopLevel
        hidesOnDeactivate = false
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    func moveToDesktopLayer() {
        level = Self.desktopLevel
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        orderFrontRegardless()
    }

    func moveToFrontLayer() {
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let store = UsageStore()
    private var window: DesktopWidgetWindow?
    private var statusItem: NSStatusItem?
    private var globalHotKeyRef: EventHotKeyRef?
    private var globalHotKeyHandler: EventHandlerRef?
    private var isFrontMode = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        debugLog("app launched bundle=\(Bundle.main.bundlePath)")

        let width = UsageWidgetView.widgetWidth
        let height = UsageWidgetView.widgetDefaultHeight
        let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let origin = CGPoint(
            x: max(screenFrame.minX + 16, screenFrame.maxX - width - 28),
            y: max(screenFrame.minY + 16, screenFrame.maxY - height - 36)
        )

        let panel = DesktopWidgetWindow(contentRect: NSRect(origin: origin, size: CGSize(width: width, height: height)))
        panel.delegate = self
        panel.minSize = CGSize(width: UsageWidgetView.widgetWidth, height: UsageWidgetView.widgetMinHeight)
        panel.maxSize = CGSize(width: UsageWidgetView.widgetWidth, height: UsageWidgetView.widgetMaxHeight)
        panel.contentMinSize = panel.minSize
        panel.contentMaxSize = panel.maxSize
        panel.contentView = GlassHostingContainer(rootView: UsageWidgetView(store: store), cornerRadius: 24)
        panel.moveToDesktopLayer()
        window = panel

        setupStatusItem()
        registerGlobalHotKey()
        store.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        unregisterGlobalHotKey()
        store.stop()
    }

    func toggleWindowLayer() {
        guard let window else { return }
        if isFrontMode {
            window.moveToDesktopLayer()
            isFrontMode = false
        } else {
            window.moveToFrontLayer()
            isFrontMode = true
        }
    }

    @objc private func statusItemClicked() {
        toggleWindowLayer()
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem = item

        guard let button = item.button else { return }
        if let image = NSImage(systemSymbolName: "gauge.with.dots.needle.67percent", accessibilityDescription: "codexU") {
            image.isTemplate = true
            button.image = image
        } else {
            button.title = "C"
        }
        button.toolTip = "codexU：点击切换前台/桌面层，快捷键 ⌘U"
        button.target = self
        button.action = #selector(statusItemClicked)
    }

    private func registerGlobalHotKey() {
        debugLog("register global hotkey command+u")
        var eventSpec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData in
                guard let userData else { return noErr }
                let delegate = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
                DispatchQueue.main.async {
                    delegate.toggleWindowLayer()
                }
                return noErr
            },
            1,
            &eventSpec,
            Unmanaged.passUnretained(self).toOpaque(),
            &globalHotKeyHandler
        )
        guard handlerStatus == noErr else {
            debugLog("InstallEventHandler failed status=\(handlerStatus)")
            return
        }

        let hotKeyID = EventHotKeyID(signature: fourCharCode("CDXU"), id: 1)
        let hotKeyStatus = RegisterEventHotKey(
            UInt32(kVK_ANSI_U),
            UInt32(cmdKey),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &globalHotKeyRef
        )
        if hotKeyStatus == noErr {
            debugLog("global hotkey registered")
        } else {
            debugLog("RegisterEventHotKey failed status=\(hotKeyStatus)")
        }
    }

    private func unregisterGlobalHotKey() {
        if let globalHotKeyRef {
            UnregisterEventHotKey(globalHotKeyRef)
        }
        if let globalHotKeyHandler {
            RemoveEventHandler(globalHotKeyHandler)
        }
        globalHotKeyRef = nil
        globalHotKeyHandler = nil
    }
}

@main
struct codexUMain {
    static func main() {
        if CommandLine.arguments.contains("--dump-json") {
            dumpJSON(CodexUsageReader().load())
            return
        }

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
