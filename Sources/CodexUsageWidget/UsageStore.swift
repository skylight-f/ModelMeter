import Foundation
import Combine


struct SessionUsageSource {
    let rolloutPath: String
    let model: String?
    let modelProvider: String?
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
    var thirtyDay = PricedTokenUsage.zero
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
        thirtyDayStart: Date,
        sevenDayStart: Date,
        monthStart: Date
    ) {
        let rawCost = estimatedCostUSD(tokens: tokens, price: price)
        let cost = convertToDisplayCurrency(rawCost, from: price.currency)
        lifetime.add(tokens: tokens, costUSD: cost)
        if date >= monthStart {
            month.add(tokens: tokens, costUSD: cost)
        }
        if date >= sevenDayStart {
            sevenDay.add(tokens: tokens, costUSD: cost)
        }
        if date >= thirtyDayStart {
            thirtyDay.add(tokens: tokens, costUSD: cost)
        }
        if date >= dayStart {
            today.add(tokens: tokens, costUSD: cost)
        }
    }

    func makeUsage() -> DetailedUsage {
        DetailedUsage(
            today: today,
            thirtyDay: thirtyDay,
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
    @Published var promptRegistry: PromptRegistry
    @Published var agentProfiles: [AgentProfile]
    @Published var exportPaths: [String: String]
    @Published var isRefreshing = false
    @Published var isRefreshingPromptRegistry = false
    @Published var discoveredProviders: [DiscoveredProvider] = []
    @Published var selectedDiscoveredProvider: DiscoveredProvider?
    @Published var discoveryNotice: String?

    @Published var modelConsumptions: [ModelConsumptionStat] = []
    @Published var modelConsumptionDetails: [String: ModelConsumptionDetail] = [:]
    @Published var projectActivities: [ProjectActivityStat] = []
    @Published var requestStats: RequestStats = RequestStats(totalRequests: 0, totalTokens: 0, avgTokensPerRequest: 0, uniqueModels: 0, uniqueProjects: 0)

    private static let agentProfilesStorageKey = "AgentDesk.agentProfiles"
    private static let exportPathsStorageKey = "AgentDesk.exportPaths"
    private var fullTimer: Timer?
    private var snapshotCache: [UsageProvider: UsageSnapshot] = [:]
    private var refreshingProviders = Set<UsageProvider>()
    private var discoveryNoticeWorkItem: DispatchWorkItem?

    init(provider: UsageProvider = .stored()) {
        self.provider = provider
        let cachedSnapshot = AgentDeskDatabase.shared.loadUsageSnapshot(provider: provider)
        self.snapshot = cachedSnapshot ?? .empty(provider: provider)
        self.promptRegistry = .empty
        AgentDeskDatabase.shared.migrateLegacyAgentProfilesIfNeeded(storageKey: Self.agentProfilesStorageKey)
        AgentDeskDatabase.shared.migrateLegacyExportPathsIfNeeded(storageKey: Self.exportPathsStorageKey)
        self.agentProfiles = Self.loadAgentProfiles()
        self.exportPaths = Self.loadExportPaths()
        self.snapshotCache[provider] = self.snapshot
        discoverProviders()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handlePreferencesDidChange),
            name: .modelMeterPreferencesDidChange,
            object: nil
        )
    }

    @objc private func handlePreferencesDidChange() {
        let newProvider = UsageProvider.stored()
        if newProvider != provider {
            provider = newProvider
            refresh()
            refreshAnalytics()
        }
    }

    func discoverProviders() {
        applyDiscoveredProviders(CodexUsageReader.discoverProviders())
    }

    func rediscoverProvidersManually() {
        let previousIds = Set(discoveredProviders.map(\.id))
        let discovered = CodexUsageReader.discoverProviders()
        let discoveredIds = Set(discovered.map(\.id))
        let newCount = discoveredIds.subtracting(previousIds).count

        applyDiscoveredProviders(discovered)

        let notice: String
        if discovered.isEmpty {
            notice = "未发现数据源"
        } else if newCount == 0 {
            notice = "未发现新数据源"
        } else {
            notice = "发现\(newCount)个新增数据源"
        }
        showDiscoveryNotice(notice)
    }

    private func applyDiscoveredProviders(_ discovered: [DiscoveredProvider]) {
        discoveredProviders = discovered

        if let current = discovered.first(where: { $0.id == provider.rawValue }) {
            selectedDiscoveredProvider = current
            return
        }

        if let savedId = AgentDeskDatabase.shared.string(forKey: "AgentDesk.selectedProviderId"),
           let found = discovered.first(where: { $0.id == savedId }) {
            selectedDiscoveredProvider = found
            return
        }

        selectedDiscoveredProvider = discovered.first
    }

    private func showDiscoveryNotice(_ notice: String) {
        discoveryNoticeWorkItem?.cancel()
        discoveryNotice = notice

        let workItem = DispatchWorkItem { [weak self] in
            self?.discoveryNotice = nil
        }
        discoveryNoticeWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: workItem)
    }

    func selectDiscoveredProvider(_ discoveredProvider: DiscoveredProvider) {
        selectedDiscoveredProvider = discoveredProvider
        AgentDeskDatabase.shared.set(discoveredProvider.id, forKey: "AgentDesk.selectedProviderId")

        if let usageProvider = UsageProvider(rawValue: discoveredProvider.id) {
            selectProvider(usageProvider)
        }
    }

    func start() {
        refresh()
        refreshAnalytics(period: .today)
        fullTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            self?.refresh()
            self?.refreshAnalytics(period: .today)
        }
    }

    func stop() {
        fullTimer?.invalidate()
    }

    func refresh() {
        discoverProviders()
        let provider = provider
        guard !refreshingProviders.contains(provider) else { return }
        refreshingProviders.insert(provider)
        syncRefreshingState()

        DispatchQueue.global(qos: .utility).async {
            let snapshot = CodexUsageReader(provider: provider).load()
            let workspaceHints = snapshot.local?.recentThreads.map(\.cwd) ?? []
            let promptRegistry = CodexUsageReader.loadPromptRegistry(workspaceHints: workspaceHints)
            DispatchQueue.main.async {
                let cached = self.snapshotCache[provider]
                    ?? AgentDeskDatabase.shared.loadUsageSnapshot(provider: provider)
                let merged = cached.map { snapshot.merging(with: $0) } ?? snapshot
                if merged.hasPersistableContent {
                    AgentDeskDatabase.shared.saveUsageSnapshot(merged)
                }
                self.snapshotCache[provider] = snapshot.hasPersistableContent ? merged : (cached ?? snapshot)
                if self.provider == provider {
                    self.snapshot = self.snapshotCache[provider] ?? snapshot
                }
                self.promptRegistry = promptRegistry
                self.refreshingProviders.remove(provider)
                self.syncRefreshingState()
            }
        }
    }

    func refreshPromptRegistry() {
        let workspaceHints = snapshot.local?.recentThreads.map(\.cwd) ?? []
        isRefreshingPromptRegistry = true
        DispatchQueue.global(qos: .utility).async {
            let promptRegistry = CodexUsageReader.loadPromptRegistry(workspaceHints: workspaceHints)
            DispatchQueue.main.async {
                self.promptRegistry = promptRegistry
                self.isRefreshingPromptRegistry = false
            }
        }
    }

    func selectProvider(_ provider: UsageProvider) {
        guard self.provider != provider else { return }
        provider.persist()
        self.provider = provider

        if let cached = snapshotCache[provider] {
            snapshot = cached
        } else if let persisted = AgentDeskDatabase.shared.loadUsageSnapshot(provider: provider) {
            snapshot = persisted
            snapshotCache[provider] = persisted
        } else {
            let empty = UsageSnapshot.empty(provider: provider)
            snapshot = empty
            snapshotCache[provider] = empty
        }

        syncRefreshingState()
        refresh()
        refreshAnalytics()

        if let discovered = discoveredProviders.first(where: { $0.id == provider.rawValue }) {
            selectedDiscoveredProvider = discovered
        }
    }

    func refreshAnalytics(period: ModelUsagePeriod = .today) {
        let currentProvider = provider
        DispatchQueue.global(qos: .utility).async {
            let (consumptions, details) = Self.fetchModelConsumptions(provider: currentProvider, period: period)
            let requestStats = Self.fetchRequestStats(provider: currentProvider)

            DispatchQueue.main.async {
                self.modelConsumptions = consumptions
                self.modelConsumptionDetails = details
                self.requestStats = requestStats
            }
        }
    }

    private static func fetchModelConsumptions(provider: UsageProvider, period: ModelUsagePeriod) -> ([ModelConsumptionStat], [String: ModelConsumptionDetail]) {
        var results: [String: (tokens: Int64, requests: Int, provider: String, lastUsed: Date)] = [:]
        let now = Date()
        let calendar = Calendar.current

        let timeFilter: String
        switch period {
        case .today:
            let dayStart = Int(calendar.startOfDay(for: now).timeIntervalSince1970)
            timeFilter = "AND updated_at >= \(dayStart)"
        case .twentyFourHour:
            let cutoff = Int(now.addingTimeInterval(-24 * 60 * 60).timeIntervalSince1970)
            timeFilter = "AND updated_at >= \(cutoff)"
        case .sevenDay:
            let cutoff = Int(now.addingTimeInterval(-7 * 24 * 60 * 60).timeIntervalSince1970)
            timeFilter = "AND updated_at >= \(cutoff)"
        case .thirtyDay:
            let cutoff = Int(now.addingTimeInterval(-30 * 24 * 60 * 60).timeIntervalSince1970)
            timeFilter = "AND updated_at >= \(cutoff)"
        case .lifetime:
            timeFilter = ""
        }

        if provider == .codex, let sqlitePath = sqlitePath(), let codexDb = codexDbPath() {
            let query = """
            SELECT model, SUM(tokens_used) as total, COUNT(*) as cnt, MAX(updated_at) as last_used
            FROM threads WHERE archived = 0 AND model IS NOT NULL AND tokens_used > 0 \(timeFilter)
            GROUP BY model ORDER BY total DESC
            """
            for row in runSQLite(sqlitePath: sqlitePath, dbPath: codexDb, query: query) {
                let model = row["model"] ?? "unknown"
                let tokens = int64Value(row["total"]) ?? 0
                let count = int64Value(row["cnt"]) ?? 0
                let lastUsedTs = doubleValue(row["last_used"]) ?? 0
                let lastUsed = Date(timeIntervalSince1970: lastUsedTs)
                results[model] = (tokens: tokens, requests: Int(count), provider: "Codex", lastUsed: lastUsed)
            }
        }

        if provider == .mimocode, let sqlitePath = sqlitePath(), let mimoDb = mimoDbPath() {
            let mimoTimeFilter: String
            switch period {
            case .today:
                let dayStartMs = Int(calendar.startOfDay(for: now).timeIntervalSince1970 * 1000)
                mimoTimeFilter = "AND m.time_created >= \(dayStartMs)"
            case .twentyFourHour:
                let cutoffMs = Int(now.addingTimeInterval(-24 * 60 * 60).timeIntervalSince1970 * 1000)
                mimoTimeFilter = "AND m.time_created >= \(cutoffMs)"
            case .sevenDay:
                let cutoffMs = Int(now.addingTimeInterval(-7 * 24 * 60 * 60).timeIntervalSince1970 * 1000)
                mimoTimeFilter = "AND m.time_created >= \(cutoffMs)"
            case .thirtyDay:
                let cutoffMs = Int(now.addingTimeInterval(-30 * 24 * 60 * 60).timeIntervalSince1970 * 1000)
                mimoTimeFilter = "AND m.time_created >= \(cutoffMs)"
            case .lifetime:
                mimoTimeFilter = ""
            }
            let query = """
            SELECT json_extract(m.data, '$.modelID') as model,
                   SUM(json_extract(m.data, '$.tokens.total')) as total,
                   COUNT(*) as cnt,
                   MAX(m.time_created/1000) as last_used
            FROM message m
            WHERE json_extract(m.data, '$.tokens.total') IS NOT NULL \(mimoTimeFilter)
            GROUP BY model ORDER BY total DESC
            """
            for row in runSQLite(sqlitePath: sqlitePath, dbPath: mimoDb, query: query) {
                let model = row["model"] ?? "unknown"
                let tokens = int64Value(row["total"]) ?? 0
                let count = int64Value(row["cnt"]) ?? 0
                let lastUsedTs = doubleValue(row["last_used"]) ?? 0
                let lastUsed = Date(timeIntervalSince1970: lastUsedTs)
                results[model] = (tokens: tokens, requests: Int(count), provider: "MimoCode", lastUsed: lastUsed)
            }
        }

        var details: [String: ModelConsumptionDetail] = [:]
        let stats = results.map { key, value in
            details[key] = ModelConsumptionDetail(lastUsed: value.lastUsed)
            return ModelConsumptionStat(
                model: key,
                provider: value.provider,
                totalTokens: value.tokens,
                requestCount: value.requests,
                avgTokens: value.requests > 0 ? value.tokens / Int64(value.requests) : 0,
                lastUsed: value.lastUsed
            )
        }
        .sorted { $0.totalTokens > $1.totalTokens }

        return (stats, details)
    }

    private static func fetchProjectActivities(provider: UsageProvider) -> [ProjectActivityStat] {
        var results: [String: (sessions: Int, tokens: Int64)] = [:]

        if provider == .codex, let sqlitePath = sqlitePath(), let codexDb = codexDbPath() {
            let query = """
            SELECT cwd, COUNT(*) as sessions, SUM(tokens_used) as tokens
            FROM threads WHERE archived = 0 AND tokens_used > 0
            GROUP BY cwd ORDER BY tokens DESC LIMIT 8
            """
            for row in runSQLite(sqlitePath: sqlitePath, dbPath: codexDb, query: query) {
                let path = row["cwd"] ?? "unknown"
                let name = URL(fileURLWithPath: path).lastPathComponent
                let sessions = Int(int64Value(row["sessions"]) ?? 0)
                let tokens = int64Value(row["tokens"]) ?? 0
                let existing = results[name]
                results[name] = (
                    sessions: (existing?.sessions ?? 0) + sessions,
                    tokens: (existing?.tokens ?? 0) + tokens
                )
            }
        }

        if provider == .mimocode, let sqlitePath = sqlitePath(), let mimoDb = mimoDbPath() {
            let query = """
            SELECT p.worktree, COUNT(DISTINCT s.id) as sessions
            FROM session s
            JOIN project p ON s.project_id = p.id
            WHERE p.worktree IS NOT NULL AND p.worktree != '' AND p.worktree != '/'
            GROUP BY p.worktree ORDER BY sessions DESC LIMIT 8
            """
            for row in runSQLite(sqlitePath: sqlitePath, dbPath: mimoDb, query: query) {
                let path = row["worktree"] ?? "unknown"
                let name = URL(fileURLWithPath: path).lastPathComponent
                guard !name.isEmpty && name != "/" else { continue }
                let sessions = Int(int64Value(row["sessions"]) ?? 0)
                let existing = results[name]
                results[name] = (
                    sessions: (existing?.sessions ?? 0) + sessions,
                    tokens: existing?.tokens ?? 0
                )
            }
        }

        return results.map { key, value in
            ProjectActivityStat(name: key, path: key, sessionCount: value.sessions, totalTokens: value.tokens)
        }
        .sorted { $0.sessionCount > $1.sessionCount }
    }

    private static func fetchRequestStats(provider: UsageProvider) -> RequestStats {
        var totalRequests = 0
        var totalTokens: Int64 = 0
        var models = Set<String>()
        var projects = Set<String>()

        if provider == .codex, let sqlitePath = sqlitePath(), let codexDb = codexDbPath() {
            let query = "SELECT COUNT(*) as cnt, SUM(tokens_used) as total, model, cwd FROM threads WHERE archived = 0"
            for row in runSQLite(sqlitePath: sqlitePath, dbPath: codexDb, query: query) {
                totalRequests += 1
                totalTokens += int64Value(row["total"]) ?? 0
                if let m = row["model"], !m.isEmpty { models.insert(m) }
                if let p = row["cwd"], !p.isEmpty { projects.insert(p) }
            }
        }

        if provider == .mimocode, let sqlitePath = sqlitePath(), let mimoDb = mimoDbPath() {
            let query = """
            SELECT COUNT(*) as cnt,
                   SUM(json_extract(data, '$.tokens.total')) as total,
                   json_extract(data, '$.modelID') as model
            FROM message WHERE json_extract(data, '$.tokens.total') IS NOT NULL
            """
            for row in runSQLite(sqlitePath: sqlitePath, dbPath: mimoDb, query: query) {
                totalRequests += Int(int64Value(row["cnt"]) ?? 0)
                totalTokens += int64Value(row["total"]) ?? 0
                if let m = row["model"], !m.isEmpty { models.insert(m) }
            }
        }

        return RequestStats(
            totalRequests: totalRequests,
            totalTokens: totalTokens,
            avgTokensPerRequest: totalRequests > 0 ? totalTokens / Int64(totalRequests) : 0,
            uniqueModels: models.count,
            uniqueProjects: projects.count
        )
    }

    private static func sqlitePath() -> String? {
        let fm = FileManager.default
        for path in ["/usr/bin/sqlite3", "/opt/homebrew/bin/sqlite3"] {
            if fm.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    private static func codexDbPath() -> String? {
        let path = NSHomeDirectory() + "/.codex/state_5.sqlite"
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }

    private static func mimoDbPath() -> String? {
        let path = NSHomeDirectory() + "/.local/share/mimocode/mimocode.db"
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }

    private static func runSQLite(sqlitePath: String, dbPath: String, query: String) -> [[String: String]] {
        let rows = NativeSQLite.queryRows(dbPath: dbPath, sql: query)
        return rows.map { dict in
            dict.compactMapValues { value in
                value
            }
        }
    }

    func createAgentProfile() -> AgentProfile {
        let index = agentProfiles.count + 1
        let profile = AgentProfile.starter(name: "Profile \(index)")
        agentProfiles.insert(profile, at: 0)
        persistAgentProfiles()
        return profile
    }

    func duplicateAgentProfile(id: String) -> AgentProfile? {
        guard var profile = agentProfiles.first(where: { $0.id == id }) else { return nil }
        profile = AgentProfile(
            id: UUID().uuidString,
            name: "\(profile.name) Copy",
            summary: profile.summary,
            persona: profile.persona,
            workingStyle: profile.workingStyle,
            constraints: profile.constraints,
            selectedAssetIDs: profile.selectedAssetIDs,
            updatedAt: Date()
        )
        agentProfiles.insert(profile, at: 0)
        persistAgentProfiles()
        return profile
    }

    func saveAgentProfile(_ profile: AgentProfile) {
        if let index = agentProfiles.firstIndex(where: { $0.id == profile.id }) {
            agentProfiles[index] = profile
        } else {
            agentProfiles.insert(profile, at: 0)
        }
        persistAgentProfiles()
    }

    func deleteAgentProfile(id: String) {
        agentProfiles.removeAll { $0.id == id }
        persistAgentProfiles()
    }

    func exportPath(profileID: String, tool: AgentTargetTool) -> String {
        exportPaths[exportPathKey(profileID: profileID, tool: tool)] ?? ""
    }

    func setExportPath(_ path: String, profileID: String, tool: AgentTargetTool) {
        exportPaths[exportPathKey(profileID: profileID, tool: tool)] = path
        persistExportPaths()
    }

    func persistAgentProfiles() {
        AgentDeskDatabase.shared.saveAgentProfiles(agentProfiles)
    }

    private static func loadAgentProfiles() -> [AgentProfile] {
        let profiles = AgentDeskDatabase.shared.loadAgentProfiles()
        guard !profiles.isEmpty else {
            return [AgentProfile.starter()]
        }
        return profiles.sorted { $0.updatedAt > $1.updatedAt }
    }

    private func persistExportPaths() {
        AgentDeskDatabase.shared.saveExportPaths(exportPaths)
    }

    private static func loadExportPaths() -> [String: String] {
        AgentDeskDatabase.shared.loadExportPaths()
    }

    private func exportPathKey(profileID: String, tool: AgentTargetTool) -> String {
        "\(profileID)::\(tool.rawValue)"
    }

    private func syncRefreshingState() {
        isRefreshing = refreshingProviders.contains(provider)
    }
}
