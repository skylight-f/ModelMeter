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
            quotaReadSucceeded: false,
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
        let trendStart = calendar.date(byAdding: .day, value: -190, to: dayStart) ?? sevenDayStart
        let sessions = loadSessions(sqlite: sqlite, database: database)
        var sessionTokens: [String: Int64] = [:]
        var sessionLastTokenAt: [String: Date] = [:]
        var recentSessionTokens: [String: Int64] = [:]
        var recentSessionLastTokenAt: [String: Date] = [:]
        var dailyTokens: [String: Int64] = [:]
        var trendDailyUsage: [String: PricedTokenUsage] = [:]
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
            sessionLastTokenAt[sessionId] = maxDate(sessionLastTokenAt[sessionId], date)
            lifetimeDetailed.add(tokens: current, costUSD: 0)
            add(tokens: current, cost: estimatedCost, model: model, provider: provider, duration: duration, key: key, to: &lifetimeModels)
            if date >= trendStart {
                let dayKey = context.statistics.dayKey(for: date)
                var dayUsage = trendDailyUsage[dayKey] ?? .zero
                // A MimoCode database can contain models priced in different currencies.
                // Keep trend totals currency-neutral instead of combining CNY and USD.
                dayUsage.add(tokens: current, costUSD: 0)
                trendDailyUsage[dayKey] = dayUsage
            }
            if date >= sevenDayStart {
                sevenDayTokens += visibleTokens
                recentSessionTokens[sessionId, default: 0] += visibleTokens
                recentSessionLastTokenAt[sessionId] = maxDate(recentSessionLastTokenAt[sessionId], date)
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
        let projectBoard = makeProjectBoard(
            sessions: sessions,
            sessionTokens: sessionTokens,
            sessionLastTokenAt: sessionLastTokenAt,
            recentSessionTokens: recentSessionTokens,
            recentSessionLastTokenAt: recentSessionLastTokenAt
        )
        let toolUsages = loadToolUsages(
            sqlite: sqlite,
            database: database,
            sessionTokens: sessionTokens
        )
        let skillUsages = loadSkillUsages(sqlite: sqlite, database: database)

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
            usageTrend: makeUsageTrend(
                dailyUsage: trendDailyUsage,
                dayStart: dayStart,
                sevenDayStart: sevenDayStart,
                trendStart: trendStart,
                monthStart: monthStart,
                calendar: calendar,
                statistics: context.statistics
            ),
            projectBoard: projectBoard,
            toolUsages: toolUsages,
            skillUsages: skillUsages,
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

    private func makeProjectBoard(
        sessions: [MimoSession],
        sessionTokens: [String: Int64],
        sessionLastTokenAt: [String: Date],
        recentSessionTokens: [String: Int64],
        recentSessionLastTokenAt: [String: Date]
    ) -> ProjectBoard {
        ProjectBoard(
            recentProjects: makeProjects(
                sessions: sessions,
                tokensBySession: recentSessionTokens,
                lastTokenAtBySession: recentSessionLastTokenAt
            ),
            allProjects: makeProjects(
                sessions: sessions,
                tokensBySession: sessionTokens,
                lastTokenAtBySession: sessionLastTokenAt
            )
        )
    }

    private func makeProjects(
        sessions: [MimoSession],
        tokensBySession: [String: Int64],
        lastTokenAtBySession: [String: Date]
    ) -> [ProjectUsage] {
        var projects: [String: MimoProjectAccumulator] = [:]
        for session in sessions {
            let tokens = tokensBySession[session.id] ?? 0
            guard tokens > 0 else { continue }
            let path = session.projectPath.isEmpty ? session.directory : session.projectPath
            let projectID = session.projectID.isEmpty ? (path.isEmpty ? "uncategorized" : path) : session.projectID
            let name = path.isEmpty ? "未归类" : URL(fileURLWithPath: path).lastPathComponent
            var project = projects[projectID] ?? MimoProjectAccumulator(
                id: projectID,
                name: name.isEmpty ? "未归类" : name,
                fullPath: path
            )
            project.add(
                sessionID: session.id,
                tokens: tokens,
                lastActiveAt: lastTokenAtBySession[session.id] ?? session.updatedAt
            )
            projects[projectID] = project
        }
        return projects.values
            .map { $0.makeUsage() }
            .sorted {
                if $0.tokens != $1.tokens { return $0.tokens > $1.tokens }
                return ($0.lastActiveAt ?? .distantPast) > ($1.lastActiveAt ?? .distantPast)
            }
    }

    private func loadToolUsages(
        sqlite: URL,
        database: URL,
        sessionTokens: [String: Int64]
    ) -> [ToolUsage] {
        let query = """
        SELECT
          session_id AS sessionId,
          json_extract(data, '$.tool') AS tool,
          COUNT(*) AS callCount
        FROM part
        WHERE json_valid(data)
          AND json_extract(data, '$.type') = 'tool'
          AND json_extract(data, '$.tool') IS NOT NULL
        GROUP BY session_id, json_extract(data, '$.tool');
        """
        let rows = runSQLite(sqlite: sqlite, database: database, query: query)
        var callsBySession: [String: [(name: String, count: Int)]] = [:]
        for row in rows {
            guard let sessionID = mimoString(row["sessionId"]),
                  let name = mimoString(row["tool"]),
                  !name.isEmpty
            else { continue }
            let count = max(0, Int(mimoInt64(row["callCount"]) ?? 0))
            guard count > 0 else { continue }
            callsBySession[sessionID, default: []].append((name, count))
        }

        var tools: [String: MimoToolAccumulator] = [:]
        for (sessionID, calls) in callsBySession {
            let totalCalls = calls.reduce(0) { $0 + $1.count }
            let tokens = sessionTokens[sessionID] ?? 0
            for call in calls {
                var tool = tools[call.name] ?? MimoToolAccumulator(name: call.name)
                let estimatedTokens: Int64
                if totalCalls > 0, tokens > 0 {
                    estimatedTokens = Int64(
                        (Double(tokens) * Double(call.count) / Double(totalCalls)).rounded()
                    )
                } else {
                    estimatedTokens = 0
                }
                tool.add(callCount: call.count, estimatedTokens: estimatedTokens)
                tools[call.name] = tool
            }
        }
        return tools.values
            .map { $0.makeUsage() }
            .sorted {
                if $0.callCount != $1.callCount { return $0.callCount > $1.callCount }
                return $0.name < $1.name
            }
    }

    private func loadSkillUsages(sqlite: URL, database: URL) -> [SkillUsage] {
        let query = """
        SELECT
          session_id AS sessionId,
          time_created AS timeCreated,
          json_extract(data, '$.state.input.name') AS skillName,
          json_extract(data, '$.state.metadata.dir') AS skillDirectory
        FROM part
        WHERE json_valid(data)
          AND json_extract(data, '$.type') = 'tool'
          AND json_extract(data, '$.tool') = 'skill'
        ORDER BY time_created ASC;
        """
        let rows = runSQLite(sqlite: sqlite, database: database, query: query)
        var skills: [String: MimoSkillAccumulator] = [:]
        for row in rows {
            guard let sessionID = mimoString(row["sessionId"]) else { continue }
            let directory = mimoString(row["skillDirectory"])?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let rawName = mimoString(row["skillName"])?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let path: String
            if directory.isEmpty {
                path = rawName
            } else if URL(fileURLWithPath: directory).pathExtension.lowercased() == "md" {
                path = directory
            } else {
                path = URL(fileURLWithPath: directory).appendingPathComponent("SKILL.md").path
            }
            let fallbackName = directory.isEmpty ? "Skill" : URL(fileURLWithPath: directory).lastPathComponent
            let name = rawName.isEmpty ? fallbackName : rawName
            let key = path.isEmpty ? name : path
            var skill = skills[key] ?? MimoSkillAccumulator(name: name, path: path)
            skill.add(sessionID: sessionID, at: mimoDate(row["timeCreated"]))
            skills[key] = skill
        }
        return skills.values
            .map { $0.makeUsage() }
            .sorted {
                if $0.loadCount != $1.loadCount { return $0.loadCount > $1.loadCount }
                if ($0.staticTokenEstimate ?? -1) != ($1.staticTokenEstimate ?? -1) {
                    return ($0.staticTokenEstimate ?? -1) > ($1.staticTokenEstimate ?? -1)
                }
                return $0.name < $1.name
            }
    }

    func loadTaskBoard(context: RuntimeLoadContext, messages: inout [String]) -> TaskBoard? {
        guard let database = databaseURL(context: context), let sqlite = sqliteURL() else {
            messages.append("任务看板未找到 MimoCode SQLite 数据源")
            return nil
        }

        let sessions = loadSessions(sqlite: sqlite, database: database)
        let dayStart = context.statistics.calendar.startOfDay(for: context.now)
        let activeCutoff = context.now.addingTimeInterval(-2 * 60 * 60)
        let dayStartMilliseconds = Int64(dayStart.timeIntervalSince1970 * 1_000)
        let taskQuery = """
        WITH token_totals AS (
          SELECT
            session_id,
            CAST(SUM(COALESCE(json_extract(data, '$.tokens.total'), 0)) AS INTEGER) AS tokens
          FROM message
          WHERE json_valid(data)
            AND json_extract(data, '$.tokens.total') IS NOT NULL
          GROUP BY session_id
        )
        SELECT
          t.id AS taskId,
          t.session_id AS sessionId,
          t.status,
          t.summary,
          t.last_event_at AS updatedAt,
          s.title AS sessionTitle,
          s.directory,
          COALESCE(NULLIF(p.worktree, ''), s.directory) AS projectPath,
          COALESCE(token_totals.tokens, 0) AS tokens
        FROM task t
        JOIN session s ON s.id = t.session_id
        LEFT JOIN project p ON p.id = s.project_id
        LEFT JOIN token_totals ON token_totals.session_id = t.session_id
        WHERE t.last_event_at >= \(dayStartMilliseconds)
        ORDER BY t.last_event_at DESC;
        """
        let taskRows = runSQLite(sqlite: sqlite, database: database, query: taskQuery)
        var columns: [TaskColumnKind: [TaskItem]] = [:]
        var representedSessionIDs = Set<String>()

        for row in taskRows {
            guard let taskID = mimoString(row["taskId"]),
                  let sessionID = mimoString(row["sessionId"])
            else { continue }
            let status = mimoString(row["status"]) ?? "open"
            let kind = mimoTaskKind(status)
            representedSessionIDs.insert(sessionID)
            columns[kind, default: []].append(makeTaskItem(
                taskID: taskID,
                sessionID: sessionID,
                status: status,
                summary: mimoString(row["summary"]),
                sessionTitle: mimoString(row["sessionTitle"]),
                projectPath: mimoString(row["projectPath"]) ?? mimoString(row["directory"]) ?? "",
                updatedAt: mimoDate(row["updatedAt"]),
                tokens: mimoInt64(row["tokens"]),
                kind: kind
            ))
        }

        let fallbackTokens = loadSessionTokenTotals(sqlite: sqlite, database: database)
        for session in sessions where !representedSessionIDs.contains(session.id)
            && ((session.updatedAt ?? .distantPast) >= dayStart || (session.archivedAt ?? .distantPast) >= dayStart) {
            let kind: TaskColumnKind
            if session.archivedAt != nil {
                kind = .done
            } else if (session.updatedAt ?? .distantPast) >= activeCutoff {
                kind = .active
            } else {
                kind = .pending
            }
            columns[kind, default: []].append(makeTaskItem(
                session: session,
                tokens: fallbackTokens[session.id],
                kind: kind
            ))
        }

        return TaskBoard(refreshedAt: context.now, columns: [
            makeColumn(.active, title: "进行中", items: columns[.active] ?? []),
            makeColumn(.pending, title: "待处理", items: columns[.pending] ?? []),
            makeColumn(.scheduled, title: "定时", items: []),
            makeColumn(.done, title: "完成", items: columns[.done] ?? [])
        ])
    }

    private func makeColumn(_ kind: TaskColumnKind, title: String, items: [TaskItem]) -> TaskColumn {
        let sorted = items.sorted { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }
        return TaskColumn(id: kind, title: title, count: sorted.count, items: Array(sorted.prefix(3)))
    }

    private func makeTaskItem(session: MimoSession, tokens: Int64?, kind: TaskColumnKind) -> TaskItem {
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
            tokens: tokens,
            kind: kind
        )
    }

    private func makeTaskItem(
        taskID: String,
        sessionID: String,
        status: String,
        summary: String?,
        sessionTitle: String?,
        projectPath: String,
        updatedAt: Date?,
        tokens: Int64?,
        kind: TaskColumnKind
    ) -> TaskItem {
        let compactID = taskID.replacingOccurrences(of: "-", with: "")
        let trimmedSummary = summary?.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedTitle = sessionTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        return TaskItem(
            id: sessionID + taskID + kind.rawValue,
            code: "MIMO-" + compactID.suffix(4).uppercased(),
            title: trimmedSummary.flatMap { $0.isEmpty ? nil : $0 }
                ?? trimmedTitle.flatMap { $0.isEmpty ? nil : $0 }
                ?? "Untitled",
            detail: projectPath.isEmpty ? "MimoCode" : URL(fileURLWithPath: projectPath).lastPathComponent,
            chip: mimoTaskChip(status, kind: kind),
            updatedAt: updatedAt,
            tokens: tokens,
            kind: kind
        )
    }

    private func loadSessionTokenTotals(sqlite: URL, database: URL) -> [String: Int64] {
        let query = """
        SELECT
          session_id AS sessionId,
          CAST(SUM(COALESCE(json_extract(data, '$.tokens.total'), 0)) AS INTEGER) AS tokens
        FROM message
        WHERE json_valid(data)
          AND json_extract(data, '$.tokens.total') IS NOT NULL
        GROUP BY session_id;
        """
        return Dictionary(uniqueKeysWithValues: runSQLite(sqlite: sqlite, database: database, query: query).compactMap { row in
            guard let sessionID = mimoString(row["sessionId"]),
                  let tokens = mimoInt64(row["tokens"])
            else { return nil }
            return (sessionID, tokens)
        })
    }

    private func loadSessions(sqlite: URL, database: URL) -> [MimoSession] {
        let query = """
        SELECT
          s.id,
          s.project_id AS projectId,
          COALESCE(NULLIF(p.worktree, ''), s.directory) AS projectPath,
          s.title,
          s.directory,
          s.time_updated AS updatedAt,
          s.time_archived AS archivedAt
        FROM session s
        LEFT JOIN project p ON p.id = s.project_id
        ORDER BY s.time_updated DESC;
        """
        return runSQLite(sqlite: sqlite, database: database, query: query).compactMap { object in
            guard let id = mimoString(object["id"]) else { return nil }
            let rawTitle = mimoString(object["title"])?.trimmingCharacters(in: .whitespacesAndNewlines)
            return MimoSession(
                id: id,
                projectID: mimoString(object["projectId"]) ?? "",
                projectPath: mimoString(object["projectPath"]) ?? "",
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

    private func makeUsageTrend(
        dailyUsage: [String: PricedTokenUsage],
        dayStart: Date,
        sevenDayStart: Date,
        trendStart: Date,
        monthStart: Date,
        calendar: Calendar,
        statistics: StatisticsContext
    ) -> UsageTrend {
        var buckets: [UsageDayBucket] = []
        var cursor = calendar.startOfDay(for: trendStart)
        let end = calendar.startOfDay(for: dayStart)

        while cursor <= end {
            let key = statistics.dayKey(for: cursor)
            buckets.append(UsageDayBucket(
                id: key,
                date: cursor,
                usage: dailyUsage[key] ?? .zero,
                sourceQuality: .detailed
            ))
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }

        var sevenDay = PricedTokenUsage.zero
        var previousSevenDayTokens: Int64 = 0
        var month = PricedTokenUsage.zero
        let previousSevenDayStart = calendar.date(byAdding: .day, value: -7, to: sevenDayStart) ?? sevenDayStart

        for bucket in buckets {
            if bucket.date >= sevenDayStart {
                sevenDay.add(tokens: bucket.usage.tokens, costUSD: 0)
            } else if bucket.date >= previousSevenDayStart {
                previousSevenDayTokens += bucket.tokens
            }
            if bucket.date >= monthStart {
                month.add(tokens: bucket.usage.tokens, costUSD: 0)
            }
        }

        let peakDay = buckets
            .filter { $0.date >= sevenDayStart }
            .max { $0.tokens < $1.tokens }
        let changePercent: Double?
        let isNewActivity: Bool
        if previousSevenDayTokens > 0 {
            changePercent = (Double(sevenDay.tokens.visibleTotalTokens) - Double(previousSevenDayTokens))
                / Double(previousSevenDayTokens) * 100
            isNewActivity = false
        } else {
            changePercent = nil
            isNewActivity = sevenDay.tokens.visibleTotalTokens > 0
        }

        let heatmapData = makeHeatmapData(
            buckets: buckets,
            endDate: dayStart,
            weekCount: 26,
            calendar: calendar,
            statistics: statistics
        )

        return UsageTrend(
            dayBuckets: buckets,
            heatmapWeeks: heatmapData.weeks,
            heatmapThresholds: heatmapData.thresholds,
            summary: UsageTrendSummary(
                sevenDay: sevenDay,
                dailyAverageTokens: sevenDay.tokens.visibleTotalTokens / 7,
                peakDay: peakDay?.tokens ?? 0 > 0 ? peakDay : nil,
                changePercent: changePercent,
                isNewActivity: isNewActivity
            ),
            month: month,
            projectedMonthCostUSD: nil,
            activeDayCount: buckets.filter { $0.tokens > 0 }.count,
            sourceQuality: .detailed
        )
    }

    private func makeHeatmapData(
        buckets: [UsageDayBucket],
        endDate: Date,
        weekCount: Int,
        calendar: Calendar,
        statistics: StatisticsContext
    ) -> (weeks: [[UsageHeatmapDay]], thresholds: [Int64]) {
        let latestDate = calendar.startOfDay(for: endDate)
        let currentWeekStart = weekStart(for: latestDate, calendar: calendar)
        let firstWeekStart = calendar.date(
            byAdding: .weekOfYear,
            value: -(weekCount - 1),
            to: currentWeekStart
        ) ?? currentWeekStart
        let bucketByDay = Dictionary(uniqueKeysWithValues: buckets.map { ($0.id, $0) })

        let weeks: [[UsageHeatmapDay]] = (0..<weekCount).map { weekIndex in
            (0..<7).compactMap { weekdayIndex in
                guard let date = calendar.date(
                    byAdding: .day,
                    value: weekIndex * 7 + weekdayIndex,
                    to: firstWeekStart
                ) else { return nil }
                let key = statistics.dayKey(for: date)
                let isFuture = date > latestDate
                return UsageHeatmapDay(
                    id: key,
                    date: date,
                    usage: isFuture ? nil : bucketByDay[key]?.usage,
                    isFuture: isFuture
                )
            }
        }
        let values = weeks
            .flatMap { $0 }
            .filter { !$0.isFuture }
            .map(\.tokens)
            .filter { $0 > 0 }
            .sorted()
        return (weeks, heatmapThresholds(values))
    }

    private func heatmapThresholds(_ values: [Int64]) -> [Int64] {
        guard values.count >= 5 else {
            let maxValue = max(values.max() ?? 0, 1)
            return [maxValue / 5, maxValue * 2 / 5, maxValue * 3 / 5, maxValue * 4 / 5]
                .map { max($0, 1) }
        }
        return [
            quantile(values, fraction: 0.25),
            quantile(values, fraction: 0.50),
            quantile(values, fraction: 0.75),
            quantile(values, fraction: 0.90)
        ]
    }

    private func quantile(_ values: [Int64], fraction: Double) -> Int64 {
        guard !values.isEmpty else { return 1 }
        let index = min(values.count - 1, max(0, Int((Double(values.count - 1) * fraction).rounded())))
        return max(values[index], 1)
    }

    private func weekStart(for date: Date, calendar: Calendar) -> Date {
        let weekday = calendar.component(.weekday, from: date)
        let mondayOffset = (weekday + 5) % 7
        return calendar.date(
            byAdding: .day,
            value: -mondayOffset,
            to: calendar.startOfDay(for: date)
        ) ?? date
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
    let projectID: String
    let projectPath: String
    let title: String
    let directory: String
    let updatedAt: Date?
    let archivedAt: Date?
}

private struct MimoProjectAccumulator {
    let id: String
    let name: String
    let fullPath: String
    var tokens: Int64 = 0
    var sessionIDs = Set<String>()
    var lastActiveAt: Date?

    mutating func add(sessionID: String, tokens addedTokens: Int64, lastActiveAt date: Date?) {
        tokens += addedTokens
        sessionIDs.insert(sessionID)
        lastActiveAt = maxDate(lastActiveAt, date)
    }

    func makeUsage() -> ProjectUsage {
        ProjectUsage(
            id: id,
            name: name,
            fullPath: fullPath,
            tokens: tokens,
            estimatedCostUSD: nil,
            threadCount: sessionIDs.count,
            lastActiveAt: lastActiveAt,
            sourceQuality: .detailed
        )
    }
}

private struct MimoToolAccumulator {
    let name: String
    var callCount: Int = 0
    var estimatedTokens: Int64 = 0

    mutating func add(callCount addedCalls: Int, estimatedTokens addedTokens: Int64) {
        callCount += addedCalls
        estimatedTokens += addedTokens
    }

    func makeUsage() -> ToolUsage {
        ToolUsage(
            id: name,
            name: name,
            category: toolCategory(for: name),
            callCount: callCount,
            estimatedTokens: estimatedTokens > 0 ? estimatedTokens : nil,
            estimatedCostUSD: nil
        )
    }
}

private struct MimoSkillAccumulator {
    let name: String
    let path: String
    var loadCount: Int = 0
    var sessionIDs = Set<String>()
    var lastLoadedAt: Date?

    mutating func add(sessionID: String, at date: Date?) {
        loadCount += 1
        sessionIDs.insert(sessionID)
        lastLoadedAt = maxDate(lastLoadedAt, date)
    }

    func makeUsage() -> SkillUsage {
        let data = path.isEmpty ? nil : try? Data(contentsOf: URL(fileURLWithPath: path))
        let text = data.map { String(data: $0, encoding: .utf8) ?? String(decoding: $0, as: UTF8.self) }
        return SkillUsage(
            id: path.isEmpty ? name : path,
            name: name,
            path: path,
            sourceLabel: "MimoCode",
            loadCount: loadCount,
            threadCount: sessionIDs.count,
            staticTokenEstimate: text.map(estimateStaticTokens),
            staticByteCount: data.map { Int64($0.count) },
            lastLoadedAt: lastLoadedAt
        )
    }
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

private func mimoTaskKind(_ status: String) -> TaskColumnKind {
    switch status.lowercased() {
    case "in_progress", "running", "active":
        return .active
    case "scheduled", "cron":
        return .scheduled
    case "done", "completed", "abandoned", "cancelled", "canceled":
        return .done
    default:
        return .pending
    }
}

private func mimoTaskChip(_ status: String, kind: TaskColumnKind) -> String {
    let normalized = status.lowercased()
    if normalized == "abandoned" || normalized == "cancelled" || normalized == "canceled" {
        return "Stopped"
    }
    switch kind {
    case .active: return "Active"
    case .pending: return "Open"
    case .scheduled: return "Cron"
    case .done: return "Done"
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
