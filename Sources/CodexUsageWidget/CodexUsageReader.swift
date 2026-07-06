import Foundation


final class CodexUsageReader {
    private let provider: UsageProvider
    private let fileManager = FileManager.default
    private static var sessionUsageCache: [String: SessionUsageCacheEntry] = [:]

    private static func evictSessionCacheIfNeeded() {
        let maxEntries = 200
        if sessionUsageCache.count > maxEntries {
            let keysToRemove = Array(sessionUsageCache.keys.prefix(sessionUsageCache.count - maxEntries))
            for key in keysToRemove {
                sessionUsageCache.removeValue(forKey: key)
            }
        }
    }

    init(provider: UsageProvider = .codex) {
        self.provider = provider
    }

    static func discoverProviders() -> [DiscoveredProvider] {
        var providers: [DiscoveredProvider] = []
        let home = NSHomeDirectory()

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

    static func loadPromptRegistry(workspaceHints: [String] = []) -> PromptRegistry {
        let fileManager = FileManager.default
        let roots = promptAssetRoots(workspaceHints: workspaceHints)
        var assets: [PromptAsset] = []
        var seenPaths = Set<String>()

        for root in roots where fileManager.fileExists(atPath: root.path) {
            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
                options: [],
                errorHandler: nil
            ) else { continue }

            for case let fileURL as URL in enumerator {
                guard shouldIncludePromptAsset(fileURL: fileURL) else { continue }
                let standardizedPath = fileURL.standardizedFileURL.path
                guard seenPaths.insert(standardizedPath).inserted else { continue }
                guard let asset = makePromptAsset(from: fileURL) else { continue }
                assets.append(asset)
            }
        }

        assets.sort { lhs, rhs in
            if lhs.source == rhs.source {
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
            return lhs.source.rawValue < rhs.source.rawValue
        }

        return PromptRegistry(refreshedAt: Date(), assets: assets)
    }

    private static func promptAssetRoots(workspaceHints: [String]) -> [URL] {
        let home = NSHomeDirectory()
        var roots: [URL] = [
            URL(fileURLWithPath: home).appendingPathComponent(".codex/skills"),
            URL(fileURLWithPath: home).appendingPathComponent(".agents/skills")
        ]

        let workspaceCandidates = Set(workspaceHints.filter { !$0.isEmpty })
        for path in workspaceCandidates {
            let workspace = URL(fileURLWithPath: path)
            roots.append(workspace.appendingPathComponent("prompts"))
            roots.append(workspace.appendingPathComponent("skills"))
            roots.append(workspace.appendingPathComponent(".prompts"))
            roots.append(workspace.appendingPathComponent(".codex/skills"))
            roots.append(workspace.appendingPathComponent(".agents/skills"))
        }

        return roots
    }

    private static func shouldIncludePromptAsset(fileURL: URL) -> Bool {
        guard
            let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey]),
            values.isRegularFile == true
        else { return false }

        let name = fileURL.lastPathComponent.lowercased()
        let parent = fileURL.deletingLastPathComponent().lastPathComponent.lowercased()
        let ext = fileURL.pathExtension.lowercased()

        if name == "skill.md" { return true }
        if ext == "prompt" { return true }
        if name.contains("prompt") { return true }
        if ["yaml", "yml", "json", "toml"].contains(ext) && (parent.contains("prompt") || parent.contains("skill")) {
            return true
        }
        if ext == "md" && (parent.contains("prompt") || parent.contains("skill")) {
            return true
        }
        return false
    }

    private static func makePromptAsset(from fileURL: URL) -> PromptAsset? {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let kind = promptAssetKind(for: fileURL)
        let source = promptAssetSource(for: fileURL)
        let name = promptAssetName(for: fileURL, content: trimmed)
        let summary = promptAssetSummary(content: trimmed)
        let preview = String(trimmed.prefix(4000))
        let resourceValues = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey])
        let modifiedAt = resourceValues?.contentModificationDate
        let tags = promptAssetTags(for: fileURL)

        return PromptAsset(
            id: fileURL.standardizedFileURL.path,
            name: name,
            kind: kind,
            source: source,
            path: fileURL.standardizedFileURL.path,
            summary: summary,
            content: preview,
            modifiedAt: modifiedAt,
            tags: tags
        )
    }

    private static func promptAssetKind(for fileURL: URL) -> PromptAssetKind {
        let name = fileURL.lastPathComponent.lowercased()
        let ext = fileURL.pathExtension.lowercased()
        if name == "skill.md" { return .skill }
        if ext == "prompt" || name.contains("prompt") { return .prompt }
        return .config
    }

    private static func promptAssetSource(for fileURL: URL) -> PromptAssetSource {
        let path = fileURL.standardizedFileURL.path
        let home = NSHomeDirectory()
        if path.hasPrefix(home + "/.codex/skills/.system/") { return .codexSystem }
        if path.hasPrefix(home + "/.codex/skills/") { return .codexUser }
        if path.hasPrefix(home + "/.agents/skills/") { return .agents }
        return .workspace
    }

    private static func promptAssetName(for fileURL: URL, content: String) -> String {
        for rawLine in content.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("#") {
                let title = line.trimmingCharacters(in: CharacterSet(charactersIn: "# " ))
                if !title.isEmpty { return title }
            }
        }
        if fileURL.lastPathComponent == "SKILL.md" {
            return fileURL.deletingLastPathComponent().lastPathComponent
        }
        return fileURL.deletingPathExtension().lastPathComponent
    }

    private static func promptAssetSummary(content: String) -> String {
        for rawLine in content.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            if line.hasPrefix("#") { continue }
            return String(line.prefix(140))
        }
        return ""
    }

    private static func promptAssetTags(for fileURL: URL) -> [String] {
        let parts = fileURL.deletingLastPathComponent().pathComponents
        let interesting = parts.filter { part in
            !part.isEmpty
                && part != "/"
                && part != ".codex"
                && part != ".agents"
                && part != "skills"
                && part != "prompts"
        }
        return Array(interesting.suffix(3))
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
                    "name": "agentdesk",
                    "title": "AgentDesk",
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
        let twentyFourHourStart = calendar.date(byAdding: .hour, value: -24, to: now) ?? dayStart
        let thirtyDayStart = calendar.date(byAdding: .day, value: -29, to: dayStart) ?? dayStart
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
          COALESCE(SUM(CASE WHEN updated_at >= \(Int(thirtyDayStart.timeIntervalSince1970)) THEN tokens_used ELSE 0 END), 0) AS thirtyDayTokens,
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
        var twentyFourHourModelUsage: [ModelUsageItem] = []
        var sevenDayModelUsage: [ModelUsageItem] = []
        var thirtyDayModelUsage: [ModelUsageItem] = []
        var lifetimeModelUsage: [ModelUsageItem] = []
        var sevenDayModelBuckets: [String: [DailyTokenBucket]] = [:]
        let detailedUsage = readDetailedUsage(
            sqlitePath: sqlitePath,
            dbPath: dbPath,
            dayStart: dayStart,
            twentyFourHourStart: twentyFourHourStart,
            thirtyDayStart: thirtyDayStart,
            sevenDayStart: sevenDayStart,
            dailyBuckets: dailyBuckets,
            todayModelUsage: &todayModelUsage,
            twentyFourHourModelUsage: &twentyFourHourModelUsage,
            sevenDayModelUsage: &sevenDayModelUsage,
            thirtyDayModelUsage: &thirtyDayModelUsage,
            lifetimeModelUsage: &lifetimeModelUsage,
            sevenDayModelBuckets: &sevenDayModelBuckets,
            messages: &messages
        )

        return LocalUsage(
            lifetimeTokens: int64Value(totalsObject["lifetimeTokens"]) ?? 0,
            todayTokens: int64Value(totalsObject["todayTokens"]) ?? 0,
            thirtyDayTokens: int64Value(totalsObject["thirtyDayTokens"]) ?? 0,
            sevenDayTokens: int64Value(totalsObject["sevenDayTokens"]) ?? 0,
            threadCount: intValue(totalsObject["threadCount"]) ?? 0,
            lastUpdatedAt: dateFromEpoch(totalsObject["lastUpdatedAt"]),
            dailyBuckets: dailyBuckets,
            sevenDayModelBuckets: sevenDayModelBuckets,
            recentThreads: recent,
            todayModelUsage: todayModelUsage,
            twentyFourHourModelUsage: twentyFourHourModelUsage,
            sevenDayModelUsage: sevenDayModelUsage,
            thirtyDayModelUsage: thirtyDayModelUsage,
            lifetimeModelUsage: lifetimeModelUsage,
            detailedUsage: detailedUsage
        )
    }

    private func readDetailedUsage(
        sqlitePath: String,
        dbPath: String,
        dayStart: Date,
        twentyFourHourStart: Date,
        thirtyDayStart: Date,
        sevenDayStart: Date,
        dailyBuckets: [DailyTokenBucket],
        todayModelUsage: inout [ModelUsageItem],
        twentyFourHourModelUsage: inout [ModelUsageItem],
        sevenDayModelUsage: inout [ModelUsageItem],
        thirtyDayModelUsage: inout [ModelUsageItem],
        lifetimeModelUsage: inout [ModelUsageItem],
        sevenDayModelBuckets: inout [String: [DailyTokenBucket]],
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
        let dayFormatter = DateFormatter()
        dayFormatter.calendar = calendar
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter.dateFormat = "yyyy-MM-dd"

        var accumulator = DetailedUsageAccumulator()
        var todayUsageByModel: [String: PricedTokenUsage] = [:]
        var twentyFourHourUsageByModel: [String: PricedTokenUsage] = [:]
        var sevenDayUsageByModel: [String: PricedTokenUsage] = [:]
        var thirtyDayUsageByModel: [String: PricedTokenUsage] = [:]
        var lifetimeUsageByModel: [String: PricedTokenUsage] = [:]
        var sevenDayTokensByModelAndDay: [String: [String: Int64]] = [:]
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
                    thirtyDayStart: thirtyDayStart,
                    sevenDayStart: sevenDayStart,
                    monthStart: monthStart
                )
                let rawCost = estimatedCostUSD(tokens: delta.tokens, price: price)
                if delta.date >= dayStart {
                    var usage = todayUsageByModel[modelName] ?? .zero
                    usage.add(tokens: delta.tokens, costUSD: rawCost)
                    todayUsageByModel[modelName] = usage
                }
                if delta.date >= twentyFourHourStart {
                    var usage = twentyFourHourUsageByModel[modelName] ?? .zero
                    usage.add(tokens: delta.tokens, costUSD: rawCost)
                    twentyFourHourUsageByModel[modelName] = usage
                }
                if delta.date >= sevenDayStart {
                    var usage = sevenDayUsageByModel[modelName] ?? .zero
                    usage.add(tokens: delta.tokens, costUSD: rawCost)
                    sevenDayUsageByModel[modelName] = usage
                    let dayKey = dayFormatter.string(from: delta.date)
                    var byDay = sevenDayTokensByModelAndDay[modelName] ?? [:]
                    byDay[dayKey, default: 0] += delta.tokens.visibleTotalTokens
                    sevenDayTokensByModelAndDay[modelName] = byDay
                }
                if delta.date >= thirtyDayStart {
                    var usage = thirtyDayUsageByModel[modelName] ?? .zero
                    usage.add(tokens: delta.tokens, costUSD: rawCost)
                    thirtyDayUsageByModel[modelName] = usage
                }
                var lifetimeUsage = lifetimeUsageByModel[modelName] ?? .zero
                lifetimeUsage.add(tokens: delta.tokens, costUSD: rawCost)
                lifetimeUsageByModel[modelName] = lifetimeUsage
            }
        }

        guard accumulator.parsedFileCount > 0, accumulator.tokenEventCount > 0 else {
            messages.append("未找到 Codex token_count 事件")
            return nil
        }

        todayModelUsage = sortedModelUsageItems(todayUsageByModel, providers: modelProviders)
        twentyFourHourModelUsage = sortedModelUsageItems(twentyFourHourUsageByModel, providers: modelProviders)
        sevenDayModelUsage = sortedModelUsageItems(sevenDayUsageByModel, providers: modelProviders)
        thirtyDayModelUsage = sortedModelUsageItems(thirtyDayUsageByModel, providers: modelProviders)
        lifetimeModelUsage = sortedModelUsageItems(lifetimeUsageByModel, providers: modelProviders)
        sevenDayModelBuckets = buildSevenDayModelBuckets(
            tokenUsageByModelAndDay: sevenDayTokensByModelAndDay,
            templateBuckets: dailyBuckets
        )
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
        } else {
            messages.append("任务看板未找到 SQLite 数据源")
        }

        let scheduledItems = readAutomationTasks()

        return TaskBoard(refreshedAt: Date(), columns: [
            TaskColumn(id: .active, title: "进行中", count: activeItems.count, items: Array(activeItems.prefix(5))),
            TaskColumn(id: .scheduled, title: "定时", count: scheduledItems.count, items: Array(scheduledItems.prefix(3)))
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
            rawThreadId: rawId,
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
                rawThreadId: id,
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
        let twentyFourHourStart = calendar.date(byAdding: .hour, value: -24, to: now) ?? dayStart
        let thirtyDayStart = calendar.date(byAdding: .day, value: -29, to: dayStart) ?? dayStart
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
          json_extract(data, '$.time.completed') AS timeCompleted,
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
        var lastCumulativeBySession: [String: TokenBreakdown] = [:]
        var tokensBySession: [String: Int64] = [:]
        var tokensByDay: [String: Int64] = [:]
        var todayUsageByModel: [String: PricedTokenUsage] = [:]
        var twentyFourHourUsageByModel: [String: PricedTokenUsage] = [:]
        var sevenDayUsageByModel: [String: PricedTokenUsage] = [:]
        var thirtyDayUsageByModel: [String: PricedTokenUsage] = [:]
        var lifetimeUsageByModel: [String: PricedTokenUsage] = [:]
        var sevenDayTokensByModelAndDay: [String: [String: Int64]] = [:]
        var modelProviders: [String: String] = [:]
        var modelTotalTokens: [String: Int64] = [:]
        var modelTotalTimeMs: [String: Double] = [:]

        let dayFormatter = DateFormatter()
        dayFormatter.calendar = calendar
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter.dateFormat = "yyyy-MM-dd"

        for object in eventObjects {
            guard let sessionId = object["sessionId"] as? String,
                  let date = dateFromEpoch(object["timeCreated"])
            else { continue }

            let outputTokens = int64Value(object["outputTokens"]) ?? 0
            let timeCreated = (object["timeCreated"] as? Double) ?? 0
            let timeCompleted = (object["timeCompleted"] as? Double) ?? 0
            if timeCompleted > timeCreated, outputTokens > 0 {
                let durationMs = timeCompleted - timeCreated
                let modelName = normalizedModelName(object["model"] as? String, fallback: "")
                if !modelName.isEmpty {
                    modelTotalTokens[modelName, default: 0] += outputTokens
                    modelTotalTimeMs[modelName, default: 0] += durationMs
                }
            }

            let uncachedInputTokens = int64Value(object["inputTokens"]) ?? 0
            let cachedInputTokens = int64Value(object["cachedInputTokens"]) ?? 0
            let current = TokenBreakdown(
                inputTokens: uncachedInputTokens + cachedInputTokens,
                cachedInputTokens: cachedInputTokens,
                outputTokens: int64Value(object["outputTokens"]) ?? 0,
                reasoningOutputTokens: int64Value(object["reasoningTokens"]) ?? 0,
                totalTokens: int64Value(object["totalTokens"]) ?? 0
            )

            lastCumulativeBySession[sessionId] = current
            guard !current.isZero else { continue }

            accumulator.parsedFileCount += 1
            accumulator.tokenEventCount += 1
            accumulator.add(
                current,
                at: date,
                price: modelTokenPrice(for: object["model"] as? String),
                dayStart: dayStart,
                thirtyDayStart: thirtyDayStart,
                sevenDayStart: sevenDayStart,
                monthStart: monthStart
            )
            let price = modelTokenPrice(for: object["model"] as? String)
            let modelName = normalizedModelName(object["model"] as? String, fallback: price.model)
            let providerID = (object["provider"] as? String) ?? ""
            let rawCost = estimatedCostUSD(tokens: current, price: price)

            if !providerID.isEmpty {
                modelProviders[modelName] = providerID
            }

            if date >= dayStart {
                var usage = todayUsageByModel[modelName] ?? .zero
                usage.add(tokens: current, costUSD: rawCost)
                todayUsageByModel[modelName] = usage
            }
            if date >= twentyFourHourStart {
                var usage = twentyFourHourUsageByModel[modelName] ?? .zero
                usage.add(tokens: current, costUSD: rawCost)
                twentyFourHourUsageByModel[modelName] = usage
            }
            if date >= sevenDayStart {
                var usage = sevenDayUsageByModel[modelName] ?? .zero
                usage.add(tokens: current, costUSD: rawCost)
                sevenDayUsageByModel[modelName] = usage
                var byDay = sevenDayTokensByModelAndDay[modelName] ?? [:]
                byDay[dayFormatter.string(from: date), default: 0] += current.visibleTotalTokens
                sevenDayTokensByModelAndDay[modelName] = byDay
                tokensByDay[dayFormatter.string(from: date), default: 0] += current.visibleTotalTokens
            }
            if date >= thirtyDayStart {
                var usage = thirtyDayUsageByModel[modelName] ?? .zero
                usage.add(tokens: current, costUSD: rawCost)
                thirtyDayUsageByModel[modelName] = usage
            }
            var lifetimeUsage = lifetimeUsageByModel[modelName] ?? .zero
            lifetimeUsage.add(tokens: current, costUSD: rawCost)
            lifetimeUsageByModel[modelName] = lifetimeUsage
            tokensBySession[sessionId, default: 0] += current.visibleTotalTokens
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
            thirtyDayTokens: totals.thirtyDay.tokens.visibleTotalTokens,
            sevenDayTokens: totals.sevenDay.tokens.visibleTotalTokens,
            threadCount: intValue(sessionCount["threadCount"]) ?? 0,
            lastUpdatedAt: dateFromEpoch(sessionCount["lastUpdatedAt"]),
            dailyBuckets: dailyBuckets,
            sevenDayModelBuckets: buildSevenDayModelBuckets(
                tokenUsageByModelAndDay: sevenDayTokensByModelAndDay,
                templateBuckets: dailyBuckets
            ),
            recentThreads: recent,
            todayModelUsage: sortedModelUsageItems(todayUsageByModel, providers: modelProviders, throughput: calculateThroughput(modelTotalTokens, modelTotalTimeMs)),
            twentyFourHourModelUsage: sortedModelUsageItems(twentyFourHourUsageByModel, providers: modelProviders, throughput: calculateThroughput(modelTotalTokens, modelTotalTimeMs)),
            sevenDayModelUsage: sortedModelUsageItems(sevenDayUsageByModel, providers: modelProviders, throughput: calculateThroughput(modelTotalTokens, modelTotalTimeMs)),
            thirtyDayModelUsage: sortedModelUsageItems(thirtyDayUsageByModel, providers: modelProviders, throughput: calculateThroughput(modelTotalTokens, modelTotalTimeMs)),
            lifetimeModelUsage: sortedModelUsageItems(lifetimeUsageByModel, providers: modelProviders, throughput: calculateThroughput(modelTotalTokens, modelTotalTimeMs)),
            detailedUsage: totals
        )
    }

    private func calculateThroughput(_ totalTokens: [String: Int64], _ totalTimeMs: [String: Double]) -> [String: Double] {
        var result: [String: Double] = [:]
        for (model, tokens) in totalTokens {
            if let timeMs = totalTimeMs[model], timeMs > 0 {
                result[model] = Double(tokens) * 1000.0 / timeMs
            }
        }
        return result
    }

    private func buildSevenDayModelBuckets(
        tokenUsageByModelAndDay: [String: [String: Int64]],
        templateBuckets: [DailyTokenBucket]
    ) -> [String: [DailyTokenBucket]] {
        var result: [String: [DailyTokenBucket]] = [:]

        for (model, usageByDay) in tokenUsageByModelAndDay {
            let buckets = templateBuckets.map { bucket in
                DailyTokenBucket(
                    id: bucket.id,
                    label: bucket.label,
                    tokens: usageByDay[bucket.id] ?? 0
                )
            }
            if buckets.contains(where: { $0.tokens > 0 }) {
                result[model] = buckets
            }
        }

        return result
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

        return TaskBoard(refreshedAt: Date(), columns: [
            TaskColumn(id: .active, title: "进行中", count: activeItems.count, items: Array(activeItems.prefix(5))),
            TaskColumn(id: .scheduled, title: "定时", count: 0, items: [])
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
            rawThreadId: rawId,
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
        NativeSQLite.queryRowsAny(dbPath: dbPath, sql: query)
    }

    private func firstExistingPath(_ paths: [String]) -> String? {
        paths.first { fileManager.isExecutableFile(atPath: $0) || fileManager.fileExists(atPath: $0) }
    }
}
