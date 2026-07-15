import Foundation

struct MimoCodeRuntimeProvider: RuntimeUsageProvider {
    let scope: RuntimeScope = .mimoCode

    func loadSnapshot(context: RuntimeLoadContext) -> RuntimeUsageSnapshot {
        var messages: [String] = []
        let reader = MimoCodeLocalReader()
        let account = reader.loadAccount(context: context)
        let local = reader.loadLocalUsage(context: context, messages: &messages)
        let taskBoard = reader.loadTaskBoard(context: context, messages: &messages)

        if local == nil {
            messages.append("暂无 MimoCode 本机用量记录")
        }

        let snapshot = UsageSnapshot(
            refreshedAt: context.now,
            account: account,
            limitId: scope.runtimeId,
            limitName: "MimoCode local",
            fiveHourQuota: nil,
            sevenDayQuota: nil,
            credits: nil,
            cloudLifetimeTokens: nil,
            local: local,
            taskBoard: taskBoard,
            messages: messages
        )

        return RuntimeUsageSnapshot(
            scope: scope,
            snapshot: snapshot,
            status: local == nil ? .unavailable : .localOnly,
            quotaSourceLabel: "MimoCode local records; quota unavailable",
            usageSourceLabel: "MimoCode local database"
        )
    }

    func loadTaskBoard(context: RuntimeLoadContext) -> TaskBoard? {
        var messages: [String] = []
        return MimoCodeLocalReader().loadTaskBoard(context: context, messages: &messages)
    }
}

private final class MimoCodeLocalReader {
    func loadAccount(context: RuntimeLoadContext) -> AccountInfo? {
        guard let database = databaseURL(context: context), let sqlite = sqliteURL() else { return nil }
        let query = """
        SELECT a.email AS email
        FROM account a
        LEFT JOIN account_state s ON s.active_account_id = a.id
        ORDER BY s.active_account_id IS NULL ASC, a.time_updated DESC
        LIMIT 1;
        """
        let email = runSQLite(sqlite: sqlite, database: database, query: query).first?["email"] as? String
        return AccountInfo(
            type: "local",
            planType: "MimoCode",
            emailPresent: !(email?.isEmpty ?? true)
        )
    }

    func loadLocalUsage(context: RuntimeLoadContext, messages: inout [String]) -> LocalUsage? {
        guard let database = databaseURL(context: context) else {
            messages.append("未找到 MimoCode mimocode.db")
            return nil
        }
        guard let sqlite = sqliteURL() else {
            messages.append("未找到 sqlite3")
            return nil
        }

        let query = """
        SELECT
          session_id AS sessionId,
          time_created AS timeCreated,
          json_extract(data, '$.tokens.total') AS totalTokens,
          json_extract(data, '$.tokens.input') AS inputTokens,
          json_extract(data, '$.tokens.output') AS outputTokens,
          json_extract(data, '$.tokens.reasoning') AS reasoningTokens,
          json_extract(data, '$.tokens.cache.read') AS cachedInputTokens,
          json_extract(data, '$.modelID') AS model,
          json_extract(data, '$.providerID') AS provider,
          json_extract(data, '$.time.completed') AS timeCompleted
        FROM message
        WHERE json_extract(data, '$.tokens.total') IS NOT NULL
        ORDER BY session_id ASC, time_created ASC, id ASC;
        """
        let events = runSQLite(sqlite: sqlite, database: database, query: query)
        guard !events.isEmpty else {
            messages.append("未找到 MimoCode token 事件")
            return nil
        }

        let calendar = context.statistics.calendar
        let dayStart = calendar.startOfDay(for: context.now)
        let twentyFourHourStart = calendar.date(byAdding: .hour, value: -24, to: context.now) ?? dayStart
        let sevenDayStart = calendar.date(byAdding: .day, value: -6, to: dayStart) ?? dayStart
        let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: context.now)) ?? dayStart
        let thirtyDayStart = calendar.date(byAdding: .day, value: -29, to: dayStart) ?? dayStart
        var sessionTokens: [String: Int64] = [:]
        var dailyTokens: [String: Int64] = [:]
        var todayModels: [String: MimoModelAccumulator] = [:]
        var twentyFourHourModels: [String: MimoModelAccumulator] = [:]
        var sevenDayModels: [String: MimoModelAccumulator] = [:]
        var monthModels: [String: MimoModelAccumulator] = [:]
        var thirtyDayModels: [String: MimoModelAccumulator] = [:]
        var lifetimeModels: [String: MimoModelAccumulator] = [:]
        var sevenDayTrendModels: [String: (date: Date, models: [String: MimoModelAccumulator])] = [:]
        var todayDetailed = PricedTokenUsage.zero
        var twentyFourHourDetailed = PricedTokenUsage.zero
        var sevenDayDetailed = PricedTokenUsage.zero
        var monthDetailed = PricedTokenUsage.zero
        var thirtyDayDetailed = PricedTokenUsage.zero
        var lifetimeDetailed = PricedTokenUsage.zero
        var tokenEventCount = 0
        var lifetimeTokens: Int64 = 0
        var todayTokens: Int64 = 0
        var sevenDayTokens: Int64 = 0
        var lastUpdatedAt: Date?

        for event in events {
            guard let sessionId = mimoString(event["sessionId"]),
                  let date = mimoDate(event["timeCreated"])
            else { continue }

            let cached = mimoInt64(event["cachedInputTokens"]) ?? 0
            let current = TokenBreakdown(
                inputTokens: (mimoInt64(event["inputTokens"]) ?? 0) + cached,
                cachedInputTokens: cached,
                outputTokens: mimoInt64(event["outputTokens"]) ?? 0,
                reasoningOutputTokens: mimoInt64(event["reasoningTokens"]) ?? 0,
                totalTokens: mimoInt64(event["totalTokens"]) ?? 0
            )
            guard !current.isZero else { continue }

            let model = mimoModelName(mimoString(event["model"]))
            let provider = mimoProviderName(mimoString(event["provider"]), model: model)
            let key = "\(provider)|\(model)"
            let price = modelUsageTokenPrice(for: model)
            let estimatedCost = estimatedModelUsageCost(tokens: current, price: price)
            let completedAt = mimoDate(event["timeCompleted"])
            let duration = completedAt.map { max(0, $0.timeIntervalSince(date)) }
            let visibleTokens = current.visibleTotalTokens
            tokenEventCount += 1
            lifetimeTokens += visibleTokens
            sessionTokens[sessionId, default: 0] += visibleTokens
            lifetimeDetailed.add(tokens: current, costUSD: 0)
            add(tokens: current, cost: estimatedCost, model: model, provider: provider, duration: duration, key: key, to: &lifetimeModels)
            if date >= sevenDayStart {
                sevenDayTokens += visibleTokens
                dailyTokens[context.statistics.dayKey(for: date), default: 0] += visibleTokens
                sevenDayDetailed.add(tokens: current, costUSD: 0)
                add(tokens: current, cost: estimatedCost, model: model, provider: provider, duration: duration, key: key, to: &sevenDayModels)
                let dayKey = context.statistics.dayKey(for: date)
                var trendDay = sevenDayTrendModels[dayKey] ?? (calendar.startOfDay(for: date), [:])
                add(tokens: current, cost: estimatedCost, model: model, provider: provider, duration: duration, key: key, to: &trendDay.models)
                sevenDayTrendModels[dayKey] = trendDay
            }
            if date >= monthStart {
                monthDetailed.add(tokens: current, costUSD: 0)
                add(tokens: current, cost: estimatedCost, model: model, provider: provider, duration: duration, key: key, to: &monthModels)
            }
            if date >= thirtyDayStart {
                thirtyDayDetailed.add(tokens: current, costUSD: 0)
                add(tokens: current, cost: estimatedCost, model: model, provider: provider, duration: duration, key: key, to: &thirtyDayModels)
            }
            if date >= twentyFourHourStart {
                twentyFourHourDetailed.add(tokens: current, costUSD: 0)
                add(tokens: current, cost: estimatedCost, model: model, provider: provider, duration: duration, key: key, to: &twentyFourHourModels)
            }
            if date >= dayStart {
                todayTokens += visibleTokens
                todayDetailed.add(tokens: current, costUSD: 0)
                add(tokens: current, cost: estimatedCost, model: model, provider: provider, duration: duration, key: key, to: &todayModels)
            }
            lastUpdatedAt = maxDate(lastUpdatedAt, date)
        }

        let sessions = loadSessions(sqlite: sqlite, database: database)
        let recentThreads = sessions.prefix(5).map { session in
            LocalThread(
                id: session.id,
                title: session.title,
                tokens: sessionTokens[session.id] ?? 0,
                updatedAt: session.updatedAt,
                model: nil,
                cwd: session.directory,
                archived: session.archivedAt != nil
            )
        }

        return LocalUsage(
            lifetimeTokens: lifetimeTokens,
            todayTokens: todayTokens,
            sevenDayTokens: sevenDayTokens,
            threadCount: sessions.count,
            lastUpdatedAt: lastUpdatedAt ?? sessions.compactMap(\.updatedAt).max(),
            dailyBuckets: sevenDayBuckets(
                dailyTokens: dailyTokens,
                dayStart: dayStart,
                calendar: calendar,
                statistics: context.statistics
            ),
            recentThreads: recentThreads,
            detailedUsage: DetailedUsage(
                today: todayDetailed,
                twentyFourHour: twentyFourHourDetailed,
                sevenDay: sevenDayDetailed,
                month: monthDetailed,
                thirtyDay: thirtyDayDetailed,
                lifetime: lifetimeDetailed,
                parsedFileCount: tokenEventCount > 0 ? 1 : 0,
                tokenEventCount: tokenEventCount
            ),
            usageTrend: nil,
            projectBoard: nil,
            toolUsages: [],
            skillUsages: [],
            modelUsage: ModelUsageBreakdown(
                today: makeModelItems(todayModels),
                twentyFourHour: makeModelItems(twentyFourHourModels),
                sevenDay: makeModelItems(sevenDayModels),
                month: makeModelItems(monthModels),
                thirtyDay: makeModelItems(thirtyDayModels),
                lifetime: makeModelItems(lifetimeModels),
                sevenDayTrend: makeTrendDays(
                    values: sevenDayTrendModels,
                    dayStart: dayStart,
                    calendar: calendar,
                    statistics: context.statistics
                )
            )
        )
    }

    func loadTaskBoard(context: RuntimeLoadContext, messages: inout [String]) -> TaskBoard? {
        guard let database = databaseURL(context: context), let sqlite = sqliteURL() else {
            messages.append("任务看板未找到 MimoCode SQLite 数据源")
            return nil
        }

        let sessions = loadSessions(sqlite: sqlite, database: database)
        let dayStart = context.statistics.calendar.startOfDay(for: context.now)
        let activeCutoff = context.now.addingTimeInterval(-2 * 60 * 60)
        var columns: [TaskColumnKind: [TaskItem]] = [:]

        for session in sessions where (session.updatedAt ?? .distantPast) >= dayStart || (session.archivedAt ?? .distantPast) >= dayStart {
            let kind: TaskColumnKind
            if session.archivedAt != nil {
                kind = .done
            } else if (session.updatedAt ?? .distantPast) >= activeCutoff {
                kind = .active
            } else {
                kind = .pending
            }
            columns[kind, default: []].append(makeTaskItem(session: session, kind: kind))
        }

        return TaskBoard(refreshedAt: context.now, columns: [
            makeColumn(.active, title: "进行中", items: columns[.active] ?? []),
            makeColumn(.pending, title: "待处理", items: columns[.pending] ?? []),
            makeColumn(.scheduled, title: "定时", items: []),
            makeColumn(.done, title: "完成", items: columns[.done] ?? [])
        ])
    }

    private func makeColumn(_ kind: TaskColumnKind, title: String, items: [TaskItem]) -> TaskColumn {
        TaskColumn(id: kind, title: title, count: items.count, items: Array(items.prefix(3)))
    }

    private func makeTaskItem(session: MimoSession, kind: TaskColumnKind) -> TaskItem {
        let compactId = session.id.replacingOccurrences(of: "-", with: "")
        let chip: String
        switch kind {
        case .active: chip = "Active"
        case .pending: chip = "Idle"
        case .scheduled: chip = "Cron"
        case .done: chip = "Done"
        }
        return TaskItem(
            id: session.id + kind.rawValue,
            code: "MIMO-" + compactId.suffix(4).uppercased(),
            title: session.title,
            detail: URL(fileURLWithPath: session.directory).lastPathComponent,
            chip: chip,
            updatedAt: session.updatedAt,
            tokens: nil,
            kind: kind
        )
    }

    private func loadSessions(sqlite: URL, database: URL) -> [MimoSession] {
        let query = """
        SELECT id, title, directory, time_updated AS updatedAt, time_archived AS archivedAt
        FROM session
        ORDER BY time_updated DESC;
        """
        return runSQLite(sqlite: sqlite, database: database, query: query).compactMap { object in
            guard let id = mimoString(object["id"]) else { return nil }
            let rawTitle = mimoString(object["title"])?.trimmingCharacters(in: .whitespacesAndNewlines)
            return MimoSession(
                id: id,
                title: rawTitle.flatMap { $0.isEmpty ? nil : $0 } ?? "Untitled",
                directory: mimoString(object["directory"]) ?? "",
                updatedAt: mimoDate(object["updatedAt"]),
                archivedAt: mimoDate(object["archivedAt"])
            )
        }
    }

    private func sevenDayBuckets(
        dailyTokens: [String: Int64],
        dayStart: Date,
        calendar: Calendar,
        statistics: StatisticsContext
    ) -> [DailyTokenBucket] {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M/d"
        return (0..<7).compactMap { index in
            guard let date = calendar.date(byAdding: .day, value: index - 6, to: dayStart) else { return nil }
            let key = statistics.dayKey(for: date)
            return DailyTokenBucket(
                id: key,
                label: index == 6 ? "今天" : formatter.string(from: date),
                tokens: dailyTokens[key] ?? 0
            )
        }
    }

    private func add(
        tokens: TokenBreakdown,
        cost: Double,
        model: String,
        provider: String,
        duration: TimeInterval?,
        key: String,
        to values: inout [String: MimoModelAccumulator]
    ) {
        var value = values[key] ?? MimoModelAccumulator(model: model, provider: provider)
        value.add(tokens, cost: cost, duration: duration)
        values[key] = value
    }

    private func makeModelItems(_ values: [String: MimoModelAccumulator]) -> [ModelUsageItem] {
        values.map { _, value in
            let price = modelUsageTokenPrice(for: value.model)
            return ModelUsageItem(
                model: value.model,
                provider: value.provider,
                tokens: value.tokens.visibleTotalTokens,
                uncachedInputTokens: value.tokens.uncachedInputTokens,
                cachedInputTokens: value.tokens.billableCachedInputTokens,
                outputTokens: value.tokens.outputTokens,
                estimatedCostUSD: value.estimatedCost,
                inputPricePerMillion: price.inputPerMillion,
                cachedInputPricePerMillion: price.cachedInputPerMillion,
                outputPricePerMillion: price.outputPerMillion,
                currency: price.currency,
                endToEndTokensPerSecond: value.endToEndTokensPerSecond
            )
        }
        .sorted { $0.tokens == $1.tokens ? $0.model < $1.model : $0.tokens > $1.tokens }
    }

    private func makeTrendDays(
        values: [String: (date: Date, models: [String: MimoModelAccumulator])],
        dayStart: Date,
        calendar: Calendar,
        statistics: StatisticsContext
    ) -> [ModelUsageTrendDay] {
        (0..<7).compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: offset - 6, to: dayStart) else { return nil }
            let dayKey = statistics.dayKey(for: date)
            let models: [String: MimoModelAccumulator] = values[dayKey]?.models ?? [:]
            let segments: [ModelUsageTrendSegment] = models.values.map {
                ModelUsageTrendSegment(model: $0.model, provider: $0.provider, tokens: $0.tokens.visibleTotalTokens)
            }
            .filter { $0.tokens > 0 }
            .sorted { $0.tokens == $1.tokens ? $0.id < $1.id : $0.tokens > $1.tokens }
            return ModelUsageTrendDay(id: dayKey, date: date, segments: segments)
        }
    }

    private func databaseURL(context: RuntimeLoadContext) -> URL? {
        let url = context.homeDirectory.appendingPathComponent(".local/share/mimocode/mimocode.db")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private func sqliteURL() -> URL? {
        ["/usr/bin/sqlite3", "/opt/homebrew/bin/sqlite3"].lazy
            .map(URL.init(fileURLWithPath:))
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private func runSQLite(sqlite: URL, database: URL, query: String) -> [[String: Any]] {
        let process = Process()
        let output = Pipe()
        process.executableURL = sqlite
        process.arguments = ["-json", database.path, query]
        process.standardOutput = output
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return []
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let objects = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }
        return objects
    }
}

private struct MimoSession {
    let id: String
    let title: String
    let directory: String
    let updatedAt: Date?
    let archivedAt: Date?
}

private struct MimoModelAccumulator {
    let model: String
    let provider: String
    var tokens = TokenBreakdown.zero
    var generatedTokens: Int64 = 0
    var durationSeconds: TimeInterval = 0
    var estimatedCost: Double = 0

    mutating func add(_ value: TokenBreakdown, cost: Double, duration: TimeInterval?) {
        tokens.add(value)
        estimatedCost += cost
        guard let duration, duration > 0 else { return }
        generatedTokens += max(value.outputTokens + value.reasoningOutputTokens, 0)
        durationSeconds += duration
    }

    var endToEndTokensPerSecond: Double? {
        guard durationSeconds > 0, generatedTokens > 0 else { return nil }
        return Double(generatedTokens) / durationSeconds
    }
}

private func mimoString(_ value: Any?) -> String? {
    if let value = value as? String { return value }
    if let value { return String(describing: value) }
    return nil
}

private func mimoInt64(_ value: Any?) -> Int64? {
    if let value = value as? Int64 { return value }
    if let value = value as? Int { return Int64(value) }
    if let value = value as? Double { return Int64(value) }
    if let value = value as? NSNumber { return value.int64Value }
    if let value = value as? String { return Int64(value) }
    return nil
}

private func mimoDate(_ value: Any?) -> Date? {
    guard let epoch = mimoInt64(value), epoch > 0 else { return nil }
    let seconds = epoch > 10_000_000_000 ? Double(epoch) / 1_000 : Double(epoch)
    return Date(timeIntervalSince1970: seconds)
}

private func mimoModelName(_ value: String?) -> String {
    let raw = (value ?? "unknown").trimmingCharacters(in: .whitespacesAndNewlines)
    let model = raw.isEmpty ? "unknown" : raw
    return model.count <= 28 ? model : String(model.prefix(25)) + "..."
}

private func mimoProviderName(_ value: String?, model: String) -> String {
    let raw = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    return raw.isEmpty ? modelProviderName(for: model) : raw
}

private func maxDate(_ lhs: Date?, _ rhs: Date?) -> Date? {
    switch (lhs, rhs) {
    case let (lhs?, rhs?): return max(lhs, rhs)
    case let (lhs?, nil): return lhs
    case let (nil, rhs?): return rhs
    case (nil, nil): return nil
    }
}
