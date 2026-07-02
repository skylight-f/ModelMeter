import Foundation
import Combine


struct ModelTokenPrice {
    let model: String
    let inputPerMillion: Double
    let cachedInputPerMillion: Double
    let outputPerMillion: Double
    let currency: Currency

    enum Currency: String {
        case usd = "$"
        case cny = "¥"
    }
}

struct SessionUsageSource {
    let rolloutPath: String
    let model: String?
}

struct SessionUsageDelta {
    let date: Date
    let tokens: TokenBreakdown
}

struct SessionUsageCacheEntry {
    let fileSize: Int64
    let modificationDate: Date?
    let hasTokenEvents: Bool
    let tokenEventCount: Int
    let deltas: [SessionUsageDelta]
}

struct DetailedUsageAccumulator {
    var today = PricedTokenUsage.zero
    var sevenDay = PricedTokenUsage.zero
    var month = PricedTokenUsage.zero
    var lifetime = PricedTokenUsage.zero
    var parsedFileCount = 0
    var tokenEventCount = 0

    mutating func add(
        _ tokens: TokenBreakdown,
        at date: Date,
        price: ModelTokenPrice,
        dayStart: Date,
        sevenDayStart: Date,
        monthStart: Date
    ) {
        let cost = estimatedCostUSD(tokens: tokens, price: price)
        lifetime.add(tokens: tokens, costUSD: cost)
        if date >= monthStart {
            month.add(tokens: tokens, costUSD: cost)
        }
        if date >= sevenDayStart {
            sevenDay.add(tokens: tokens, costUSD: cost)
        }
        if date >= dayStart {
            today.add(tokens: tokens, costUSD: cost)
        }
    }

    func makeUsage() -> DetailedUsage {
        DetailedUsage(
            today: today,
            sevenDay: sevenDay,
            month: month,
            lifetime: lifetime,
            parsedFileCount: parsedFileCount,
            tokenEventCount: tokenEventCount
        )
    }
}

final class UsageStore: ObservableObject {
    @Published var provider: UsageProvider
    @Published var snapshot: UsageSnapshot
    @Published var isRefreshing = false
    @Published var discoveredProviders: [DiscoveredProvider] = []
    @Published var selectedDiscoveredProvider: DiscoveredProvider?

    private var fullTimer: Timer?
    private var taskBoardTimer: Timer?
    private var isRefreshingTaskBoard = false

    init(provider: UsageProvider = .stored()) {
        self.provider = provider
        self.snapshot = .empty(provider: provider)
        discoverProviders()
    }

    func discoverProviders() {
        discoveredProviders = CodexUsageReader.discoverProviders()
        if let savedId = UserDefaults.standard.string(forKey: "ModelMeter.selectedProviderId"),
           let found = discoveredProviders.first(where: { $0.id == savedId }) {
            selectedDiscoveredProvider = found
        } else {
            selectedDiscoveredProvider = discoveredProviders.first
        }
    }

    func selectDiscoveredProvider(_ discoveredProvider: DiscoveredProvider) {
        selectedDiscoveredProvider = discoveredProvider
        UserDefaults.standard.set(discoveredProvider.id, forKey: "ModelMeter.selectedProviderId")

        // 同步更新 provider 属性
        if let usageProvider = UsageProvider(rawValue: discoveredProvider.id) {
            selectProvider(usageProvider)
        }
    }

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
        let provider = provider

        DispatchQueue.global(qos: .utility).async {
            let snapshot = CodexUsageReader(provider: provider).load()
            DispatchQueue.main.async {
                self.snapshot = snapshot
                self.isRefreshing = false
            }
        }
    }

    func selectProvider(_ provider: UsageProvider) {
        guard self.provider != provider else { return }
        provider.persist()
        self.provider = provider
        snapshot = .empty(provider: provider)
        refresh()

        // 同步更新 discoveredProviders 选择器
        if let discovered = discoveredProviders.first(where: { $0.id == provider.rawValue }) {
            selectedDiscoveredProvider = discovered
        }
    }

    private func refreshTaskBoard() {
        guard !isRefreshing, !isRefreshingTaskBoard else { return }
        isRefreshingTaskBoard = true
        let provider = provider

        DispatchQueue.global(qos: .utility).async {
            let taskBoard = CodexUsageReader(provider: provider).loadTaskBoard()
            DispatchQueue.main.async {
                if self.provider == provider {
                    self.snapshot = self.snapshot.replacingTaskBoard(taskBoard)
                }
                self.isRefreshingTaskBoard = false
            }
        }
    }
}

final class CodexUsageReader {
    private let provider: UsageProvider
    private let fileManager = FileManager.default
    private static var sessionUsageCache: [String: SessionUsageCacheEntry] = [:]

    init(provider: UsageProvider = .codex) {
        self.provider = provider
    }

    static func discoverProviders() -> [DiscoveredProvider] {
        var providers: [DiscoveredProvider] = []
        let home = NSHomeDirectory()

        // Codex
        let codexPaths = [
            home + "/.codex/state_5.sqlite",
            home + "/.codex/sqlite/state_5.sqlite"
        ]
        if codexPaths.contains(where: { FileManager.default.fileExists(atPath: $0) }) {
            providers.append(DiscoveredProvider(
                id: "codex",
                name: "Codex",
                shortName: "Codex",
                icon: "brain.head.profile",
                databasePaths: codexPaths,
                type: .codex
            ))
        }

        // MimoCode
        let mimoPaths = [home + "/.local/share/mimocode/mimocode.db"]
        if mimoPaths.contains(where: { FileManager.default.fileExists(atPath: $0) }) {
            providers.append(DiscoveredProvider(
                id: "mimocode",
                name: "MimoCode",
                shortName: "Mimo",
                icon: "sparkles",
                databasePaths: mimoPaths,
                type: .mimocode
            ))
        }

        // Claude Code
        let claudePaths = [
            home + "/.claude/state.db",
            home + "/.claude/sqlite/state.db"
        ]
        if claudePaths.contains(where: { FileManager.default.fileExists(atPath: $0) }) {
            providers.append(DiscoveredProvider(
                id: "claude",
                name: "Claude Code",
                shortName: "Claude",
                icon: "ant",
                databasePaths: claudePaths,
                type: .generic
            ))
        }

        // Cursor
        let cursorPaths = [
            home + "/.cursor/state.vscsqlite",
            home + "/Library/Application Support/Cursor/User/workspaceStorage/state.vscsqlite"
        ]
        if cursorPaths.contains(where: { FileManager.default.fileExists(atPath: $0) }) {
            providers.append(DiscoveredProvider(
                id: "cursor",
                name: "Cursor",
                shortName: "Cursor",
                icon: "arrow.left.arrow.right",
                databasePaths: cursorPaths,
                type: .generic
            ))
        }

        // Windsurf
        let windsurfPaths = [
            home + "/.codeium/windsurf/state.vscsqlite"
        ]
        if windsurfPaths.contains(where: { FileManager.default.fileExists(atPath: $0) }) {
            providers.append(DiscoveredProvider(
                id: "windsurf",
                name: "Windsurf",
                shortName: "Windsurf",
                icon: "wind",
                databasePaths: windsurfPaths,
                type: .generic
            ))
        }

        return providers
    }

    func load() -> UsageSnapshot {
        var messages: [String] = []
        if provider == .mimocode {
            let account = readMimoAccount()
            let local = readMimoLocalUsage(messages: &messages)
            let taskBoard = readMimoTaskBoard(messages: &messages)

            return UsageSnapshot(
                provider: provider,
                refreshedAt: Date(),
                account: account,
                limitId: nil,
                limitName: nil,
                primary: nil,
                secondary: nil,
                credits: nil,
                cloudLifetimeTokens: nil,
                local: local,
                taskBoard: taskBoard,
                messages: messages
            )
        }

        let appServer = readAppServer(messages: &messages)
        let local = readLocalUsage(messages: &messages)
        let taskBoard = readTaskBoard(messages: &messages)

        return UsageSnapshot(
            provider: provider,
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
        if provider == .mimocode {
            return readMimoTaskBoard(messages: &messages)
        }
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
                    "title": "ModelMeter",
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

        var todayModelUsage: [ModelUsageItem] = []
        var sevenDayModelUsage: [ModelUsageItem] = []
        var lifetimeModelUsage: [ModelUsageItem] = []
        let detailedUsage = readDetailedUsage(
            sqlitePath: sqlitePath,
            dbPath: dbPath,
            dayStart: dayStart,
            sevenDayStart: sevenDayStart,
            todayModelUsage: &todayModelUsage,
            sevenDayModelUsage: &sevenDayModelUsage,
            lifetimeModelUsage: &lifetimeModelUsage,
            messages: &messages
        )

        return LocalUsage(
            lifetimeTokens: int64Value(totalsObject["lifetimeTokens"]) ?? 0,
            todayTokens: int64Value(totalsObject["todayTokens"]) ?? 0,
            sevenDayTokens: int64Value(totalsObject["sevenDayTokens"]) ?? 0,
            threadCount: intValue(totalsObject["threadCount"]) ?? 0,
            lastUpdatedAt: dateFromEpoch(totalsObject["lastUpdatedAt"]),
            dailyBuckets: dailyBuckets,
            recentThreads: recent,
            todayModelUsage: todayModelUsage,
            sevenDayModelUsage: sevenDayModelUsage,
            lifetimeModelUsage: lifetimeModelUsage,
            detailedUsage: detailedUsage
        )
    }

    private func readDetailedUsage(
        sqlitePath: String,
        dbPath: String,
        dayStart: Date,
        sevenDayStart: Date,
        todayModelUsage: inout [ModelUsageItem],
        sevenDayModelUsage: inout [ModelUsageItem],
        lifetimeModelUsage: inout [ModelUsageItem],
        messages: inout [String]
    ) -> DetailedUsage? {
        let sourceQuery = """
        SELECT rollout_path AS rolloutPath, model, model_provider AS modelProvider
        FROM threads
        WHERE rollout_path IS NOT NULL
          AND rollout_path <> ''
          AND tokens_used > 0
        ORDER BY updated_at ASC;
        """

        var seenPaths = Set<String>()
        var modelProviders: [String: String] = [:]
        let sources = runSQLiteJSON(sqlitePath: sqlitePath, dbPath: dbPath, query: sourceQuery).compactMap { object -> SessionUsageSource? in
            guard let path = object["rolloutPath"] as? String, !path.isEmpty, seenPaths.insert(path).inserted else {
                return nil
            }
            if let model = object["model"] as? String, let provider = object["modelProvider"] as? String {
                modelProviders[model] = provider
            }
            return SessionUsageSource(rolloutPath: path, model: object["model"] as? String)
        }

        guard !sources.isEmpty else {
            messages.append("未找到 Codex session 日志")
            return nil
        }

        let calendar = Calendar.current
        var monthComponents = calendar.dateComponents([.year, .month], from: Date())
        monthComponents.day = 1
        monthComponents.hour = 0
        monthComponents.minute = 0
        monthComponents.second = 0
        let monthStart = calendar.date(from: monthComponents) ?? dayStart

        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plainFormatter = ISO8601DateFormatter()
        plainFormatter.formatOptions = [.withInternetDateTime]

        var accumulator = DetailedUsageAccumulator()
        var todayUsageByModel: [String: PricedTokenUsage] = [:]
        var sevenDayUsageByModel: [String: PricedTokenUsage] = [:]
        var lifetimeUsageByModel: [String: PricedTokenUsage] = [:]
        for source in sources {
            guard let entry = cachedSessionUsage(
                source: source,
                fractionalFormatter: fractionalFormatter,
                plainFormatter: plainFormatter
            ) else { continue }

            if entry.hasTokenEvents {
                accumulator.parsedFileCount += 1
                accumulator.tokenEventCount += entry.tokenEventCount
            }

            let price = modelTokenPrice(for: source.model)
            let modelName = normalizedModelName(source.model, fallback: price.model)
            for delta in entry.deltas {
                accumulator.add(
                    delta.tokens,
                    at: delta.date,
                    price: price,
                    dayStart: dayStart,
                    sevenDayStart: sevenDayStart,
                    monthStart: monthStart
                )
                let costUSD = estimatedCostUSD(tokens: delta.tokens, price: price)
                if delta.date >= dayStart {
                    var usage = todayUsageByModel[modelName] ?? .zero
                    usage.add(tokens: delta.tokens, costUSD: costUSD)
                    todayUsageByModel[modelName] = usage
                }
                if delta.date >= sevenDayStart {
                    var usage = sevenDayUsageByModel[modelName] ?? .zero
                    usage.add(tokens: delta.tokens, costUSD: costUSD)
                    sevenDayUsageByModel[modelName] = usage
                }
                var lifetimeUsage = lifetimeUsageByModel[modelName] ?? .zero
                lifetimeUsage.add(tokens: delta.tokens, costUSD: costUSD)
                lifetimeUsageByModel[modelName] = lifetimeUsage
            }
        }

        guard accumulator.parsedFileCount > 0, accumulator.tokenEventCount > 0 else {
            messages.append("未找到 Codex token_count 事件")
            return nil
        }

        todayModelUsage = sortedModelUsageItems(todayUsageByModel, providers: modelProviders)
        sevenDayModelUsage = sortedModelUsageItems(sevenDayUsageByModel, providers: modelProviders)
        lifetimeModelUsage = sortedModelUsageItems(lifetimeUsageByModel, providers: modelProviders)
        return accumulator.makeUsage()
    }

    private func cachedSessionUsage(
        source: SessionUsageSource,
        fractionalFormatter: ISO8601DateFormatter,
        plainFormatter: ISO8601DateFormatter
    ) -> SessionUsageCacheEntry? {
        let url = URL(fileURLWithPath: source.rolloutPath)
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let fileSize = (attributes[.size] as? NSNumber)?.int64Value
        else { return nil }

        let modificationDate = attributes[.modificationDate] as? Date
        if let cached = Self.sessionUsageCache[source.rolloutPath],
           cached.fileSize == fileSize,
           cached.modificationDate == modificationDate {
            return cached
        }

        let tokenCountPattern = #""type":"token_count""#
        let tokenCountNeedle = Data(tokenCountPattern.utf8)
        if let parsed = parseSessionUsageWithGrep(
            url: url,
            tokenCountPattern: tokenCountPattern,
            tokenCountNeedle: tokenCountNeedle,
            fractionalFormatter: fractionalFormatter,
            plainFormatter: plainFormatter
        ) {
            let entry = SessionUsageCacheEntry(
                fileSize: fileSize,
                modificationDate: modificationDate,
                hasTokenEvents: parsed.hasTokenEvents,
                tokenEventCount: parsed.tokenEventCount,
                deltas: parsed.deltas
            )
            Self.sessionUsageCache[source.rolloutPath] = entry
            return entry
        }

        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        var buffer = Data()
        var previous = TokenBreakdown.zero
        var sawTokenEvent = false
        var tokenEventCount = 0
        var deltas: [SessionUsageDelta] = []

        while true {
            let chunk = try? handle.read(upToCount: 64 * 1024)
            guard let chunk, !chunk.isEmpty else {
                break
            }
            buffer.append(chunk)

            while let newline = buffer.firstIndex(of: 10) {
                let lineData = buffer.subdata(in: buffer.startIndex..<newline)
                buffer.removeSubrange(buffer.startIndex...newline)
                processUsageLine(
                    lineData,
                    tokenCountNeedle: tokenCountNeedle,
                    fractionalFormatter: fractionalFormatter,
                    plainFormatter: plainFormatter,
                    previous: &previous,
                    sawTokenEvent: &sawTokenEvent,
                    tokenEventCount: &tokenEventCount,
                    deltas: &deltas
                )
            }
        }

        if !buffer.isEmpty {
            processUsageLine(
                buffer,
                tokenCountNeedle: tokenCountNeedle,
                fractionalFormatter: fractionalFormatter,
                plainFormatter: plainFormatter,
                previous: &previous,
                sawTokenEvent: &sawTokenEvent,
                tokenEventCount: &tokenEventCount,
                deltas: &deltas
            )
        }

        let entry = SessionUsageCacheEntry(
            fileSize: fileSize,
            modificationDate: modificationDate,
            hasTokenEvents: sawTokenEvent,
            tokenEventCount: tokenEventCount,
            deltas: deltas
        )
        Self.sessionUsageCache[source.rolloutPath] = entry
        return entry
    }

    private func parseSessionUsageWithGrep(
        url: URL,
        tokenCountPattern: String,
        tokenCountNeedle: Data,
        fractionalFormatter: ISO8601DateFormatter,
        plainFormatter: ISO8601DateFormatter
    ) -> (hasTokenEvents: Bool, tokenEventCount: Int, deltas: [SessionUsageDelta])? {
        let grepPath = "/usr/bin/grep"
        guard fileManager.isExecutableFile(atPath: grepPath) else { return nil }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: grepPath)
        process.arguments = ["-a", "-F", tokenCountPattern, url.path]

        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return nil
        }

        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 || process.terminationStatus == 1 else {
            return nil
        }

        var buffer = data
        var previous = TokenBreakdown.zero
        var sawTokenEvent = false
        var tokenEventCount = 0
        var deltas: [SessionUsageDelta] = []

        while let newline = buffer.firstIndex(of: 10) {
            let lineData = buffer.subdata(in: buffer.startIndex..<newline)
            buffer.removeSubrange(buffer.startIndex...newline)
            processUsageLine(
                lineData,
                tokenCountNeedle: tokenCountNeedle,
                fractionalFormatter: fractionalFormatter,
                plainFormatter: plainFormatter,
                previous: &previous,
                sawTokenEvent: &sawTokenEvent,
                tokenEventCount: &tokenEventCount,
                deltas: &deltas
            )
        }

        if !buffer.isEmpty {
            processUsageLine(
                buffer,
                tokenCountNeedle: tokenCountNeedle,
                fractionalFormatter: fractionalFormatter,
                plainFormatter: plainFormatter,
                previous: &previous,
                sawTokenEvent: &sawTokenEvent,
                tokenEventCount: &tokenEventCount,
                deltas: &deltas
            )
        }

        return (sawTokenEvent, tokenEventCount, deltas)
    }

    private func processUsageLine(
        _ lineData: Data,
        tokenCountNeedle: Data,
        fractionalFormatter: ISO8601DateFormatter,
        plainFormatter: ISO8601DateFormatter,
        previous: inout TokenBreakdown,
        sawTokenEvent: inout Bool,
        tokenEventCount: inout Int,
        deltas: inout [SessionUsageDelta]
    ) {
        guard lineData.range(of: tokenCountNeedle) != nil,
              let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
              let timestamp = object["timestamp"] as? String,
              let payload = object["payload"] as? [String: Any],
              payload["type"] as? String == "token_count",
              let info = payload["info"] as? [String: Any],
              let totalUsage = info["total_token_usage"] as? [String: Any],
              let date = fractionalFormatter.date(from: timestamp) ?? plainFormatter.date(from: timestamp)
        else { return }

        sawTokenEvent = true
        tokenEventCount += 1

        let current = TokenBreakdown(
            inputTokens: int64Value(totalUsage["input_tokens"]) ?? 0,
            cachedInputTokens: int64Value(totalUsage["cached_input_tokens"]) ?? 0,
            outputTokens: int64Value(totalUsage["output_tokens"]) ?? 0,
            reasoningOutputTokens: int64Value(totalUsage["reasoning_output_tokens"]) ?? 0,
            totalTokens: int64Value(totalUsage["total_tokens"]) ?? 0
        )

        var delta = current.delta(from: previous)
        if delta.hasNegativeValue {
            delta = current
        }
        previous = current

        guard !delta.isZero else { return }
        deltas.append(SessionUsageDelta(date: date, tokens: delta))
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

    private func readMimoAccount() -> AccountInfo? {
        guard let dbPath = mimoDatabasePath(),
              let sqlitePath = sqliteExecutablePath()
        else { return nil }

        let query = """
        SELECT a.email AS email
        FROM account a
        LEFT JOIN account_state s ON s.active_account_id = a.id
        ORDER BY s.active_account_id IS NULL ASC, a.time_updated DESC
        LIMIT 1;
        """

        let email = runSQLiteJSON(sqlitePath: sqlitePath, dbPath: dbPath, query: query).first?["email"] as? String
        return AccountInfo(type: "mimocode", planType: "MimoCode", emailPresent: email != nil && !(email?.isEmpty ?? true))
    }

    private func readMimoLocalUsage(messages: inout [String]) -> LocalUsage? {
        guard let dbPath = mimoDatabasePath() else {
            messages.append("未找到 MimoCode mimocode.db")
            return nil
        }

        guard let sqlitePath = sqliteExecutablePath() else {
            messages.append("未找到 sqlite3")
            return nil
        }

        let calendar = Calendar.current
        let now = Date()
        let dayStart = calendar.startOfDay(for: now)
        let sevenDayStart = calendar.date(byAdding: .day, value: -6, to: dayStart) ?? dayStart
        var monthComponents = calendar.dateComponents([.year, .month], from: now)
        monthComponents.day = 1
        monthComponents.hour = 0
        monthComponents.minute = 0
        monthComponents.second = 0
        let monthStart = calendar.date(from: monthComponents) ?? dayStart

        let eventQuery = """
        SELECT
          session_id AS sessionId,
          time_created AS timeCreated,
          json_extract(data, '$.tokens.total') AS totalTokens,
          json_extract(data, '$.tokens.input') AS inputTokens,
          json_extract(data, '$.tokens.output') AS outputTokens,
          json_extract(data, '$.tokens.reasoning') AS reasoningTokens,
          json_extract(data, '$.tokens.cache.read') AS cachedInputTokens,
          json_extract(data, '$.modelID') AS model,
          json_extract(data, '$.providerID') AS provider
        FROM message
        WHERE json_extract(data, '$.tokens.total') IS NOT NULL
        ORDER BY session_id ASC, time_created ASC, id ASC;
        """

        let eventObjects = runSQLiteJSON(sqlitePath: sqlitePath, dbPath: dbPath, query: eventQuery)
        guard !eventObjects.isEmpty else {
            messages.append("未找到 MimoCode token 事件")
            return nil
        }

        var accumulator = DetailedUsageAccumulator()
        var previousBySession: [String: TokenBreakdown] = [:]
        var tokensBySession: [String: Int64] = [:]
        var tokensByDay: [String: Int64] = [:]
        var todayUsageByModel: [String: PricedTokenUsage] = [:]
        var sevenDayUsageByModel: [String: PricedTokenUsage] = [:]
        var lifetimeUsageByModel: [String: PricedTokenUsage] = [:]
        var modelProviders: [String: String] = [:]

        let dayFormatter = DateFormatter()
        dayFormatter.calendar = calendar
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter.dateFormat = "yyyy-MM-dd"

        for object in eventObjects {
            guard let sessionId = object["sessionId"] as? String,
                  let date = dateFromEpoch(object["timeCreated"])
            else { continue }

            let uncachedInputTokens = int64Value(object["inputTokens"]) ?? 0
            let cachedInputTokens = int64Value(object["cachedInputTokens"]) ?? 0
            let current = TokenBreakdown(
                inputTokens: uncachedInputTokens + cachedInputTokens,
                cachedInputTokens: cachedInputTokens,
                outputTokens: int64Value(object["outputTokens"]) ?? 0,
                reasoningOutputTokens: int64Value(object["reasoningTokens"]) ?? 0,
                totalTokens: int64Value(object["totalTokens"]) ?? 0
            )

            var delta = current.delta(from: previousBySession[sessionId] ?? .zero)
            if delta.hasNegativeValue {
                delta = current
            }
            previousBySession[sessionId] = current
            guard !delta.isZero else { continue }

            accumulator.parsedFileCount += 1
            accumulator.tokenEventCount += 1
            accumulator.add(
                delta,
                at: date,
                price: modelTokenPrice(for: object["model"] as? String),
                dayStart: dayStart,
                sevenDayStart: sevenDayStart,
                monthStart: monthStart
            )
            let price = modelTokenPrice(for: object["model"] as? String)
            let modelName = normalizedModelName(object["model"] as? String, fallback: price.model)
            let providerID = (object["provider"] as? String) ?? ""
            let costUSD = estimatedCostUSD(tokens: delta, price: price)

            // 存储 provider 信息
            if !providerID.isEmpty {
                modelProviders[modelName] = providerID
            }

            if date >= dayStart {
                var usage = todayUsageByModel[modelName] ?? .zero
                usage.add(tokens: delta, costUSD: costUSD)
                todayUsageByModel[modelName] = usage
            }
            if date >= sevenDayStart {
                var usage = sevenDayUsageByModel[modelName] ?? .zero
                usage.add(tokens: delta, costUSD: costUSD)
                sevenDayUsageByModel[modelName] = usage
                tokensByDay[dayFormatter.string(from: date), default: 0] += delta.visibleTotalTokens
            }
            var lifetimeUsage = lifetimeUsageByModel[modelName] ?? .zero
            lifetimeUsage.add(tokens: delta, costUSD: costUSD)
            lifetimeUsageByModel[modelName] = lifetimeUsage
            tokensBySession[sessionId, default: 0] += delta.visibleTotalTokens
        }

        let totals = accumulator.makeUsage()
        let labelFormatter = DateFormatter()
        labelFormatter.calendar = calendar
        labelFormatter.locale = Locale(identifier: "zh_CN")
        labelFormatter.dateFormat = "M/d"
        let dailyBuckets = (0..<7).compactMap { index -> DailyTokenBucket? in
            guard let date = calendar.date(byAdding: .day, value: index - 6, to: dayStart) else { return nil }
            let key = dayFormatter.string(from: date)
            return DailyTokenBucket(
                id: key,
                label: index == 6 ? "今天" : labelFormatter.string(from: date),
                tokens: tokensByDay[key] ?? 0
            )
        }

        let sessionCountQuery = "SELECT COUNT(*) AS threadCount, COALESCE(MAX(time_updated), 0) AS lastUpdatedAt FROM session;"
        let sessionCount = runSQLiteJSON(sqlitePath: sqlitePath, dbPath: dbPath, query: sessionCountQuery).first ?? [:]

        let recentQuery = """
        SELECT id, title, directory, time_updated AS updatedAt, time_archived AS archivedAt
        FROM session
        ORDER BY time_updated DESC
        LIMIT 5;
        """

        let recent = runSQLiteJSON(sqlitePath: sqlitePath, dbPath: dbPath, query: recentQuery).map { object in
            let sessionId = object["id"] as? String ?? UUID().uuidString
            return LocalThread(
                id: sessionId,
                title: normalizedTitle(object["title"] as? String, fallback: nil),
                tokens: tokensBySession[sessionId] ?? 0,
                updatedAt: dateFromEpoch(object["updatedAt"]),
                model: nil,
                cwd: object["directory"] as? String ?? "",
                archived: dateFromEpoch(object["archivedAt"]) != nil
            )
        }

        return LocalUsage(
            lifetimeTokens: totals.lifetime.tokens.visibleTotalTokens,
            todayTokens: totals.today.tokens.visibleTotalTokens,
            sevenDayTokens: totals.sevenDay.tokens.visibleTotalTokens,
            threadCount: intValue(sessionCount["threadCount"]) ?? 0,
            lastUpdatedAt: dateFromEpoch(sessionCount["lastUpdatedAt"]),
            dailyBuckets: dailyBuckets,
            recentThreads: recent,
            todayModelUsage: sortedModelUsageItems(todayUsageByModel, providers: modelProviders),
            sevenDayModelUsage: sortedModelUsageItems(sevenDayUsageByModel, providers: modelProviders),
            lifetimeModelUsage: sortedModelUsageItems(lifetimeUsageByModel, providers: modelProviders),
            detailedUsage: totals
        )
    }

    private func readMimoTaskBoard(messages: inout [String]) -> TaskBoard? {
        guard let dbPath = mimoDatabasePath(),
              let sqlitePath = sqliteExecutablePath()
        else {
            messages.append("任务看板未找到 MimoCode SQLite 数据源")
            return nil
        }

        let calendar = Calendar.current
        let now = Date()
        let dayStart = calendar.startOfDay(for: now)
        let activeCutoff = now.addingTimeInterval(-2 * 60 * 60)
        let dayStartMs = Int(dayStart.timeIntervalSince1970 * 1000)

        let todayQuery = """
        SELECT id, title, directory, time_updated AS updatedAt, time_archived AS archivedAt
        FROM session
        WHERE time_archived IS NULL
          AND (
            time_updated >= \(dayStartMs)
            OR time_created >= \(dayStartMs)
          )
        ORDER BY time_updated DESC
        LIMIT 24;
        """

        let archivedQuery = """
        SELECT id, title, directory, COALESCE(time_archived, time_updated) AS updatedAt, time_archived AS archivedAt
        FROM session
        WHERE time_archived IS NOT NULL
          AND time_archived >= \(dayStartMs)
        ORDER BY time_archived DESC
        LIMIT 12;
        """

        var activeItems: [TaskItem] = []
        var pendingItems: [TaskItem] = []

        for object in runSQLiteJSON(sqlitePath: sqlitePath, dbPath: dbPath, query: todayQuery) {
            let updatedAt = dateFromEpoch(object["updatedAt"])
            let kind: TaskColumnKind = (updatedAt ?? .distantPast) >= activeCutoff ? .active : .pending
            let item = makeMimoSessionTaskItem(object: object, updatedAt: updatedAt, kind: kind)
            if kind == .active {
                activeItems.append(item)
            } else {
                pendingItems.append(item)
            }
        }

        let doneItems = runSQLiteJSON(sqlitePath: sqlitePath, dbPath: dbPath, query: archivedQuery).map { object in
            makeMimoSessionTaskItem(object: object, updatedAt: dateFromEpoch(object["updatedAt"]), kind: .done)
        }

        return TaskBoard(refreshedAt: Date(), columns: [
            TaskColumn(id: .active, title: "进行中", count: activeItems.count, items: Array(activeItems.prefix(3))),
            TaskColumn(id: .pending, title: "待处理", count: pendingItems.count, items: Array(pendingItems.prefix(3))),
            TaskColumn(id: .scheduled, title: "定时", count: 0, items: []),
            TaskColumn(id: .done, title: "完成", count: doneItems.count, items: Array(doneItems.prefix(3)))
        ])
    }

    private func makeMimoSessionTaskItem(object: [String: Any], updatedAt: Date?, kind: TaskColumnKind) -> TaskItem {
        let rawId = object["id"] as? String ?? UUID().uuidString
        let compactId = rawId.replacingOccurrences(of: "-", with: "")
        let code = "MIMO-" + compactId.suffix(4).uppercased()
        let chip: String

        switch kind {
        case .active:
            chip = "Active"
        case .pending:
            chip = "Idle"
        case .scheduled:
            chip = "Cron"
        case .done:
            chip = "Done"
        }

        return TaskItem(
            id: rawId + kind.rawValue,
            code: String(code),
            title: normalizedTitle(object["title"] as? String, fallback: nil),
            detail: shortWorkspaceName(object["directory"] as? String ?? ""),
            chip: chip,
            updatedAt: updatedAt,
            tokens: nil,
            kind: kind
        )
    }

    private func mimoDatabasePath() -> String? {
        firstExistingPath([
            NSHomeDirectory() + "/.local/share/mimocode/mimocode.db"
        ])
    }

    private func sqliteExecutablePath() -> String? {
        firstExistingPath([
            "/usr/bin/sqlite3",
            "/opt/homebrew/bin/sqlite3",
            "/opt/homebrew/share/android-commandlinetools/platform-tools/sqlite3"
        ])
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

