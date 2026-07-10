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

        let supportedProviderCount = providers.filter { provider in
            guard let usageProvider = UsageProvider(rawValue: provider.id) else { return false }
            return usageProvider != .all
        }.count
        if supportedProviderCount > 1 {
            providers.insert(DiscoveredProvider(
                id: UsageProvider.all.rawValue,
                name: "All Sources",
                shortName: "All",
                icon: "square.grid.2x2",
                databasePaths: [],
                type: .generic
            ), at: 0)
        }

        return providers
    }

    func load() -> UsageSnapshot {
        var messages: [String] = []
        if provider == .all {
            let sourceProviders = Self.discoverProviders()
                .compactMap { UsageProvider(rawValue: $0.id) }
                .filter { $0 != .all }
            let snapshots = sourceProviders.map { CodexUsageReader(provider: $0).load() }
            return UsageStore.aggregateSnapshot(from: snapshots).snapshot
        }

        if provider == .mimocode {
            let account = readMimoAccount()
            let local = readMimoLocalUsage(messages: &messages)

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
                messages: messages
            )
        }

        let appServer = readAppServer(messages: &messages)
        let local = readLocalUsage(messages: &messages)

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
            messages: messages
        )
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
        guard let codexPath = codexExecutablePath() else {
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
        let account = (result["account"] as? [String: Any]) ?? result
        guard
              let type = account["type"] as? String else { return nil }

        return AccountInfo(
            type: type,
            planType: account["planType"] as? String,
            emailPresent: account["email"] != nil && !(account["email"] is NSNull)
        )
    }

    private func parseRateLimits(_ result: [String: Any], into snapshot: inout AppServerSnapshot) {
        guard let selected = selectRateLimits(from: result) else { return }

        snapshot.limitId = stringValue(selected["limitId"])
        snapshot.limitName = stringValue(selected["limitName"])
        snapshot.primary = parseRateWindow(selected["primary"])
        snapshot.secondary = parseRateWindow(selected["secondary"])

        var resetCredits: Int?
        if let reset = result["rateLimitResetCredits"] as? [String: Any] {
            resetCredits = intValue(reset["availableCount"])
        }

        if let credits = selected["credits"] as? [String: Any] {
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
                ?? doubleValue(object["usedPercentage"])
                ?? doubleValue(object["used_percent"])
        else { return nil }

        let resetDate: Date?
        if let timestamp = doubleValue(object["resetsAt"]) {
            // Some app-server versions return milliseconds; older versions use seconds.
            resetDate = Date(timeIntervalSince1970: timestamp > 10_000_000_000 ? timestamp / 1_000 : timestamp)
        } else if let dateString = stringValue(object["resetsAt"]),
                  let date = ISO8601DateFormatter().date(from: dateString) {
            resetDate = date
        } else {
            resetDate = nil
        }

        return RateWindow(
            usedPercent: used,
            windowDurationMins: intValue(object["windowDurationMins"]),
            resetsAt: resetDate
        )
    }

    /// The app-server may expose a single default pool, or a map of pools keyed by
    /// product/plan.  The default is authoritative for a merged ChatGPT + Codex
    /// login; the map remains a fallback for older Codex-only installations.
    private func selectRateLimits(from result: [String: Any]) -> [String: Any]? {
        if let defaultLimits = result["rateLimits"] as? [String: Any],
           containsRateWindow(defaultLimits) {
            return defaultLimits
        }

        guard let byID = result["rateLimitsByLimitId"] as? [String: Any] else {
            return result["rateLimits"] as? [String: Any]
        }

        let pools = byID.compactMap { key, value -> (String, [String: Any])? in
            guard let limits = value as? [String: Any], containsRateWindow(limits) else { return nil }
            return (key, limits)
        }

        // Preserve the old Codex-only behavior when there is no default pool, but
        // do not require a literal "codex" key after account pools are unified.
        if let codexPool = pools.first(where: { $0.0.caseInsensitiveCompare("codex") == .orderedSame }) {
            return codexPool.1
        }
        if let chatGPTPool = pools.first(where: { $0.0.localizedCaseInsensitiveContains("chatgpt") }) {
            return chatGPTPool.1
        }
        return pools.first?.1
    }

    private func containsRateWindow(_ limits: [String: Any]) -> Bool {
        limits["primary"] is [String: Any] || limits["secondary"] is [String: Any]
    }

    private func codexExecutablePath() -> String? {
        let home = NSHomeDirectory()
        var candidates = [
            "/Applications/Codex.app/Contents/Resources/codex",
            home + "/.local/bin/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            "/usr/bin/codex"
        ]

        // Desktop apps often have a short PATH, while CLI installs commonly live
        // in ~/.local/bin.  Inspect PATH as an additional, non-exclusive source.
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            candidates.append(contentsOf: path.split(separator: ":").map { "\($0)/codex" })
        }

        return candidates.first(where: { fileManager.isExecutableFile(atPath: $0) })
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
            let model = object["model"] as? String
            let provider = object["modelProvider"] as? String
            if let model {
                let modelName = normalizedModelName(model, fallback: modelTokenPrice(for: model).model)
                let bucketKey = modelUsageBucketKey(model: modelName, provider: provider)
                if let provider {
                    modelProviders[bucketKey] = provider
                }
            }
            return SessionUsageSource(rolloutPath: path, model: model, modelProvider: provider)
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
        var todayModelTotalTokens: [String: Int64] = [:]
        var todayModelTotalTimeMs: [String: Double] = [:]
        var twentyFourHourModelTotalTokens: [String: Int64] = [:]
        var twentyFourHourModelTotalTimeMs: [String: Double] = [:]
        var sevenDayModelTotalTokens: [String: Int64] = [:]
        var sevenDayModelTotalTimeMs: [String: Double] = [:]
        var thirtyDayModelTotalTokens: [String: Int64] = [:]
        var thirtyDayModelTotalTimeMs: [String: Double] = [:]
        var lifetimeModelTotalTokens: [String: Int64] = [:]
        var lifetimeModelTotalTimeMs: [String: Double] = [:]

        func recordThroughput(
            bucketKey: String,
            outputTokens: Int64,
            durationMs: Double?,
            tokens: inout [String: Int64],
            timeMs: inout [String: Double]
        ) {
            guard outputTokens > 0, let durationMs, durationMs > 0 else { return }
            tokens[bucketKey, default: 0] += outputTokens
            timeMs[bucketKey, default: 0] += durationMs
        }

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

            for delta in entry.deltas {
                let eventModel = delta.model ?? source.model
                let eventProvider = delta.modelProvider ?? source.modelProvider
                let price = modelTokenPrice(for: eventModel)
                let modelName = normalizedModelName(eventModel, fallback: price.model)
                let bucketKey = modelUsageBucketKey(model: modelName, provider: eventProvider)

                if let eventProvider {
                    modelProviders[bucketKey] = eventProvider
                }

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
                    var usage = todayUsageByModel[bucketKey] ?? .zero
                    usage.add(tokens: delta.tokens, costUSD: rawCost)
                    todayUsageByModel[bucketKey] = usage
                    recordThroughput(
                        bucketKey: bucketKey,
                        outputTokens: delta.tokens.outputTokens + delta.tokens.reasoningOutputTokens,
                        durationMs: delta.endToEndDurationMs,
                        tokens: &todayModelTotalTokens,
                        timeMs: &todayModelTotalTimeMs
                    )
                }
                if delta.date >= twentyFourHourStart {
                    var usage = twentyFourHourUsageByModel[bucketKey] ?? .zero
                    usage.add(tokens: delta.tokens, costUSD: rawCost)
                    twentyFourHourUsageByModel[bucketKey] = usage
                    recordThroughput(
                        bucketKey: bucketKey,
                        outputTokens: delta.tokens.outputTokens + delta.tokens.reasoningOutputTokens,
                        durationMs: delta.endToEndDurationMs,
                        tokens: &twentyFourHourModelTotalTokens,
                        timeMs: &twentyFourHourModelTotalTimeMs
                    )
                }
                if delta.date >= sevenDayStart {
                    var usage = sevenDayUsageByModel[bucketKey] ?? .zero
                    usage.add(tokens: delta.tokens, costUSD: rawCost)
                    sevenDayUsageByModel[bucketKey] = usage
                    let dayKey = dayFormatter.string(from: delta.date)
                    var byDay = sevenDayTokensByModelAndDay[bucketKey] ?? [:]
                    byDay[dayKey, default: 0] += delta.tokens.visibleTotalTokens
                    sevenDayTokensByModelAndDay[bucketKey] = byDay
                    recordThroughput(
                        bucketKey: bucketKey,
                        outputTokens: delta.tokens.outputTokens + delta.tokens.reasoningOutputTokens,
                        durationMs: delta.endToEndDurationMs,
                        tokens: &sevenDayModelTotalTokens,
                        timeMs: &sevenDayModelTotalTimeMs
                    )
                }
                if delta.date >= thirtyDayStart {
                    var usage = thirtyDayUsageByModel[bucketKey] ?? .zero
                    usage.add(tokens: delta.tokens, costUSD: rawCost)
                    thirtyDayUsageByModel[bucketKey] = usage
                    recordThroughput(
                        bucketKey: bucketKey,
                        outputTokens: delta.tokens.outputTokens + delta.tokens.reasoningOutputTokens,
                        durationMs: delta.endToEndDurationMs,
                        tokens: &thirtyDayModelTotalTokens,
                        timeMs: &thirtyDayModelTotalTimeMs
                    )
                }
                var lifetimeUsage = lifetimeUsageByModel[bucketKey] ?? .zero
                lifetimeUsage.add(tokens: delta.tokens, costUSD: rawCost)
                lifetimeUsageByModel[bucketKey] = lifetimeUsage
                recordThroughput(
                    bucketKey: bucketKey,
                    outputTokens: delta.tokens.outputTokens + delta.tokens.reasoningOutputTokens,
                    durationMs: delta.endToEndDurationMs,
                    tokens: &lifetimeModelTotalTokens,
                    timeMs: &lifetimeModelTotalTimeMs
                )
            }
        }

        guard accumulator.parsedFileCount > 0, accumulator.tokenEventCount > 0 else {
            messages.append("未找到 Codex token_count 事件")
            return nil
        }

        todayModelUsage = sortedModelUsageItems(todayUsageByModel, providers: modelProviders, throughput: calculateThroughput(todayModelTotalTokens, todayModelTotalTimeMs))
        twentyFourHourModelUsage = sortedModelUsageItems(twentyFourHourUsageByModel, providers: modelProviders, throughput: calculateThroughput(twentyFourHourModelTotalTokens, twentyFourHourModelTotalTimeMs))
        sevenDayModelUsage = sortedModelUsageItems(sevenDayUsageByModel, providers: modelProviders, throughput: calculateThroughput(sevenDayModelTotalTokens, sevenDayModelTotalTimeMs))
        thirtyDayModelUsage = sortedModelUsageItems(thirtyDayUsageByModel, providers: modelProviders, throughput: calculateThroughput(thirtyDayModelTotalTokens, thirtyDayModelTotalTimeMs))
        lifetimeModelUsage = sortedModelUsageItems(lifetimeUsageByModel, providers: modelProviders, throughput: calculateThroughput(lifetimeModelTotalTokens, lifetimeModelTotalTimeMs))
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

        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        let tokenCountNeedle = Data(#""type":"token_count""#.utf8)
        let taskCompleteNeedle = Data(#""type":"task_complete""#.utf8)
        let modelNeedle = Data(#""model"#.utf8)
        let providerNeedle = Data(#""provider"#.utf8)
        var buffer = Data()
        var previous = TokenBreakdown.zero
        var currentModel = source.model
        var currentProvider = source.modelProvider
        var sawTokenEvent = false
        var tokenEventCount = 0
        var deltas: [SessionUsageDelta] = []
        var pendingDurationDeltaIndex: Int?

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
                    taskCompleteNeedle: taskCompleteNeedle,
                    modelNeedle: modelNeedle,
                    providerNeedle: providerNeedle,
                    fractionalFormatter: fractionalFormatter,
                    plainFormatter: plainFormatter,
                    previous: &previous,
                    currentModel: &currentModel,
                    currentProvider: &currentProvider,
                    sawTokenEvent: &sawTokenEvent,
                    tokenEventCount: &tokenEventCount,
                    pendingDurationDeltaIndex: &pendingDurationDeltaIndex,
                    deltas: &deltas
                )
            }
        }

        if !buffer.isEmpty {
            processUsageLine(
                buffer,
                tokenCountNeedle: tokenCountNeedle,
                taskCompleteNeedle: taskCompleteNeedle,
                modelNeedle: modelNeedle,
                providerNeedle: providerNeedle,
                fractionalFormatter: fractionalFormatter,
                plainFormatter: plainFormatter,
                previous: &previous,
                currentModel: &currentModel,
                currentProvider: &currentProvider,
                sawTokenEvent: &sawTokenEvent,
                tokenEventCount: &tokenEventCount,
                pendingDurationDeltaIndex: &pendingDurationDeltaIndex,
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
        var currentModel: String?
        var currentProvider: String?
        let modelNeedle = Data(#""model"#.utf8)
        let providerNeedle = Data(#""provider"#.utf8)
        let taskCompleteNeedle = Data(#""type":"task_complete""#.utf8)
        var sawTokenEvent = false
        var tokenEventCount = 0
        var deltas: [SessionUsageDelta] = []
        var pendingDurationDeltaIndex: Int?

        while let newline = buffer.firstIndex(of: 10) {
            let lineData = buffer.subdata(in: buffer.startIndex..<newline)
            buffer.removeSubrange(buffer.startIndex...newline)
            processUsageLine(
                lineData,
                tokenCountNeedle: tokenCountNeedle,
                taskCompleteNeedle: taskCompleteNeedle,
                modelNeedle: modelNeedle,
                providerNeedle: providerNeedle,
                fractionalFormatter: fractionalFormatter,
                plainFormatter: plainFormatter,
                previous: &previous,
                currentModel: &currentModel,
                currentProvider: &currentProvider,
                sawTokenEvent: &sawTokenEvent,
                tokenEventCount: &tokenEventCount,
                pendingDurationDeltaIndex: &pendingDurationDeltaIndex,
                deltas: &deltas
            )
        }

        if !buffer.isEmpty {
            processUsageLine(
                buffer,
                tokenCountNeedle: tokenCountNeedle,
                taskCompleteNeedle: taskCompleteNeedle,
                modelNeedle: modelNeedle,
                providerNeedle: providerNeedle,
                fractionalFormatter: fractionalFormatter,
                plainFormatter: plainFormatter,
                previous: &previous,
                currentModel: &currentModel,
                currentProvider: &currentProvider,
                sawTokenEvent: &sawTokenEvent,
                tokenEventCount: &tokenEventCount,
                pendingDurationDeltaIndex: &pendingDurationDeltaIndex,
                deltas: &deltas
            )
        }

        return (sawTokenEvent, tokenEventCount, deltas)
    }

    private func processUsageLine(
        _ lineData: Data,
        tokenCountNeedle: Data,
        taskCompleteNeedle: Data,
        modelNeedle: Data,
        providerNeedle: Data,
        fractionalFormatter: ISO8601DateFormatter,
        plainFormatter: ISO8601DateFormatter,
        previous: inout TokenBreakdown,
        currentModel: inout String?,
        currentProvider: inout String?,
        sawTokenEvent: inout Bool,
        tokenEventCount: inout Int,
        pendingDurationDeltaIndex: inout Int?,
        deltas: inout [SessionUsageDelta]
    ) {
        let hasTokenCount = lineData.range(of: tokenCountNeedle) != nil
        let hasTaskComplete = lineData.range(of: taskCompleteNeedle) != nil
        let hasModelHint = lineData.range(of: modelNeedle) != nil
        let hasProviderHint = lineData.range(of: providerNeedle) != nil
        guard hasTokenCount || hasTaskComplete || hasModelHint || hasProviderHint,
              let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any]
        else { return }

        let payload = object["payload"] as? [String: Any] ?? [:]
        if hasTaskComplete, payload["type"] as? String == "task_complete" {
            if let index = pendingDurationDeltaIndex,
               deltas.indices.contains(index),
               let durationMs = doubleValue(payload["duration_ms"]),
               durationMs > 0 {
                deltas[index].endToEndDurationMs = durationMs
            }
            pendingDurationDeltaIndex = nil
            return
        }

        let info = payload["info"] as? [String: Any] ?? [:]
        let totalUsage = info["total_token_usage"] as? [String: Any] ?? [:]
        let detectedModel = tokenEventModel(object: object, payload: payload, info: info, totalUsage: totalUsage)
        let detectedProvider = tokenEventProvider(object: object, payload: payload, info: info, totalUsage: totalUsage)
        if let detectedModel {
            currentModel = detectedModel
        }
        if let detectedProvider {
            currentProvider = detectedProvider
        }

        guard hasTokenCount,
              let timestamp = object["timestamp"] as? String,
              payload["type"] as? String == "token_count",
              !totalUsage.isEmpty,
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
        deltas.append(SessionUsageDelta(
            date: date,
            tokens: delta,
            model: detectedModel ?? currentModel,
            modelProvider: detectedProvider ?? currentProvider,
            endToEndDurationMs: nil
        ))
        pendingDurationDeltaIndex = deltas.count - 1
    }

    private func tokenEventModel(
        object: [String: Any],
        payload: [String: Any],
        info: [String: Any],
        totalUsage: [String: Any]
    ) -> String? {
        firstTokenEventString(
            keys: ["model", "model_slug", "model_id", "modelId", "modelID", "model_name", "modelName"],
            dictionaries: [info, totalUsage, payload, object]
        )
    }

    private func tokenEventProvider(
        object: [String: Any],
        payload: [String: Any],
        info: [String: Any],
        totalUsage: [String: Any]
    ) -> String? {
        firstTokenEventString(
            keys: ["model_provider", "modelProvider", "provider", "provider_id", "providerId", "providerID"],
            dictionaries: [info, totalUsage, payload, object]
        )
    }

    private func firstTokenEventString(keys: [String], dictionaries: [[String: Any]]) -> String? {
        for dictionary in dictionaries {
            if let value = firstStringValue(keys: keys, in: dictionary) {
                return value
            }
        }
        for dictionary in dictionaries {
            if let value = firstNestedStringValue(keys: keys, in: dictionary, depth: 2) {
                return value
            }
        }
        return nil
    }

    private func firstStringValue(keys: [String], in dictionary: [String: Any]) -> String? {
        for key in keys {
            if let value = stringValue(dictionary[key])?.trimmingCharacters(in: .whitespacesAndNewlines),
               !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private func firstNestedStringValue(keys: [String], in dictionary: [String: Any], depth: Int) -> String? {
        guard depth > 0 else { return nil }
        for (_, value) in dictionary {
            if let nested = value as? [String: Any] {
                if let found = firstStringValue(keys: keys, in: nested) {
                    return found
                }
                if let found = firstNestedStringValue(keys: keys, in: nested, depth: depth - 1) {
                    return found
                }
            } else if let nestedArray = value as? [[String: Any]] {
                for nested in nestedArray {
                    if let found = firstStringValue(keys: keys, in: nested) {
                        return found
                    }
                    if let found = firstNestedStringValue(keys: keys, in: nested, depth: depth - 1) {
                        return found
                    }
                }
            }
        }
        return nil
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
        var todayModelTotalTokens: [String: Int64] = [:]
        var todayModelTotalTimeMs: [String: Double] = [:]
        var twentyFourHourModelTotalTokens: [String: Int64] = [:]
        var twentyFourHourModelTotalTimeMs: [String: Double] = [:]
        var sevenDayModelTotalTokens: [String: Int64] = [:]
        var sevenDayModelTotalTimeMs: [String: Double] = [:]
        var thirtyDayModelTotalTokens: [String: Int64] = [:]
        var thirtyDayModelTotalTimeMs: [String: Double] = [:]
        var lifetimeModelTotalTokens: [String: Int64] = [:]
        var lifetimeModelTotalTimeMs: [String: Double] = [:]

        let dayFormatter = DateFormatter()
        dayFormatter.calendar = calendar
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter.dateFormat = "yyyy-MM-dd"

        func recordThroughput(
            bucketKey: String,
            outputTokens: Int64,
            durationMs: Double,
            tokens: inout [String: Int64],
            timeMs: inout [String: Double]
        ) {
            guard outputTokens > 0, durationMs > 0 else { return }
            tokens[bucketKey, default: 0] += outputTokens
            timeMs[bucketKey, default: 0] += durationMs
        }

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
            let bucketKey = modelUsageBucketKey(model: modelName, provider: providerID)
            let rawCost = estimatedCostUSD(tokens: current, price: price)

            let durationMs: Double?
            if let timeCreated = epochMilliseconds(object["timeCreated"]),
               let timeCompleted = epochMilliseconds(object["timeCompleted"]) {
                durationMs = timeCompleted - timeCreated
            } else {
                durationMs = nil
            }
            let throughputTokens = current.outputTokens + current.reasoningOutputTokens

            if !providerID.isEmpty {
                modelProviders[bucketKey] = providerID
            }

            if date >= dayStart {
                var usage = todayUsageByModel[bucketKey] ?? .zero
                usage.add(tokens: current, costUSD: rawCost)
                todayUsageByModel[bucketKey] = usage
                if let durationMs {
                    recordThroughput(
                        bucketKey: bucketKey,
                        outputTokens: throughputTokens,
                        durationMs: durationMs,
                        tokens: &todayModelTotalTokens,
                        timeMs: &todayModelTotalTimeMs
                    )
                }
            }
            if date >= twentyFourHourStart {
                var usage = twentyFourHourUsageByModel[bucketKey] ?? .zero
                usage.add(tokens: current, costUSD: rawCost)
                twentyFourHourUsageByModel[bucketKey] = usage
                if let durationMs {
                    recordThroughput(
                        bucketKey: bucketKey,
                        outputTokens: throughputTokens,
                        durationMs: durationMs,
                        tokens: &twentyFourHourModelTotalTokens,
                        timeMs: &twentyFourHourModelTotalTimeMs
                    )
                }
            }
            if date >= sevenDayStart {
                var usage = sevenDayUsageByModel[bucketKey] ?? .zero
                usage.add(tokens: current, costUSD: rawCost)
                sevenDayUsageByModel[bucketKey] = usage
                var byDay = sevenDayTokensByModelAndDay[bucketKey] ?? [:]
                byDay[dayFormatter.string(from: date), default: 0] += current.visibleTotalTokens
                sevenDayTokensByModelAndDay[bucketKey] = byDay
                tokensByDay[dayFormatter.string(from: date), default: 0] += current.visibleTotalTokens
                if let durationMs {
                    recordThroughput(
                        bucketKey: bucketKey,
                        outputTokens: throughputTokens,
                        durationMs: durationMs,
                        tokens: &sevenDayModelTotalTokens,
                        timeMs: &sevenDayModelTotalTimeMs
                    )
                }
            }
            if date >= thirtyDayStart {
                var usage = thirtyDayUsageByModel[bucketKey] ?? .zero
                usage.add(tokens: current, costUSD: rawCost)
                thirtyDayUsageByModel[bucketKey] = usage
                if let durationMs {
                    recordThroughput(
                        bucketKey: bucketKey,
                        outputTokens: throughputTokens,
                        durationMs: durationMs,
                        tokens: &thirtyDayModelTotalTokens,
                        timeMs: &thirtyDayModelTotalTimeMs
                    )
                }
            }
            var lifetimeUsage = lifetimeUsageByModel[bucketKey] ?? .zero
            lifetimeUsage.add(tokens: current, costUSD: rawCost)
            lifetimeUsageByModel[bucketKey] = lifetimeUsage
            if let durationMs {
                recordThroughput(
                    bucketKey: bucketKey,
                    outputTokens: throughputTokens,
                    durationMs: durationMs,
                    tokens: &lifetimeModelTotalTokens,
                    timeMs: &lifetimeModelTotalTimeMs
                )
            }
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
            todayModelUsage: sortedModelUsageItems(todayUsageByModel, providers: modelProviders, throughput: calculateThroughput(todayModelTotalTokens, todayModelTotalTimeMs)),
            twentyFourHourModelUsage: sortedModelUsageItems(twentyFourHourUsageByModel, providers: modelProviders, throughput: calculateThroughput(twentyFourHourModelTotalTokens, twentyFourHourModelTotalTimeMs)),
            sevenDayModelUsage: sortedModelUsageItems(sevenDayUsageByModel, providers: modelProviders, throughput: calculateThroughput(sevenDayModelTotalTokens, sevenDayModelTotalTimeMs)),
            thirtyDayModelUsage: sortedModelUsageItems(thirtyDayUsageByModel, providers: modelProviders, throughput: calculateThroughput(thirtyDayModelTotalTokens, thirtyDayModelTotalTimeMs)),
            lifetimeModelUsage: sortedModelUsageItems(lifetimeUsageByModel, providers: modelProviders, throughput: calculateThroughput(lifetimeModelTotalTokens, lifetimeModelTotalTimeMs)),
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
                result[modelUsageDisplayLabel(from: model)] = buckets
            }
        }

        return result
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
