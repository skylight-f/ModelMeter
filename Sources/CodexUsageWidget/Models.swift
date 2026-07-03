import Foundation
import SwiftUI

import Cocoa
import Carbon.HIToolbox
import SwiftUI

struct RateWindow: Equatable, Codable {
    let usedPercent: Double
    let windowDurationMins: Int?
    let resetsAt: Date?

    var remainingPercent: Double {
        max(0, min(100, 100 - usedPercent))
    }
}

struct CreditsInfo: Equatable, Codable {
    let hasCredits: Bool
    let unlimited: Bool
    let balance: String?
    let resetCredits: Int?
}

struct AccountInfo: Equatable, Codable {
    let type: String
    let planType: String?
    let emailPresent: Bool
}

struct LocalThread: Identifiable, Equatable, Codable {
    let id: String
    let title: String
    let tokens: Int64
    let updatedAt: Date?
    let model: String?
    let cwd: String
    let archived: Bool
}

struct DailyTokenBucket: Identifiable, Equatable, Codable {
    let id: String
    let label: String
    let tokens: Int64
}

struct TokenBreakdown: Equatable, Codable {
    var inputTokens: Int64
    var cachedInputTokens: Int64
    var outputTokens: Int64
    var reasoningOutputTokens: Int64
    var totalTokens: Int64

    static let zero = TokenBreakdown(
        inputTokens: 0,
        cachedInputTokens: 0,
        outputTokens: 0,
        reasoningOutputTokens: 0,
        totalTokens: 0
    )

    var billableCachedInputTokens: Int64 {
        min(max(cachedInputTokens, 0), max(inputTokens, 0))
    }

    var uncachedInputTokens: Int64 {
        max(0, inputTokens - billableCachedInputTokens)
    }

    var visibleTotalTokens: Int64 {
        max(totalTokens, inputTokens + outputTokens)
    }

    var splitTotalTokens: Int64 {
        max(uncachedInputTokens + billableCachedInputTokens + max(outputTokens, 0), 0)
    }

    var isZero: Bool {
        inputTokens == 0
            && cachedInputTokens == 0
            && outputTokens == 0
            && reasoningOutputTokens == 0
            && totalTokens == 0
    }

    var hasNegativeValue: Bool {
        inputTokens < 0
            || cachedInputTokens < 0
            || outputTokens < 0
            || reasoningOutputTokens < 0
            || totalTokens < 0
    }

    mutating func add(_ other: TokenBreakdown) {
        inputTokens += other.inputTokens
        cachedInputTokens += other.cachedInputTokens
        outputTokens += other.outputTokens
        reasoningOutputTokens += other.reasoningOutputTokens
        totalTokens += other.totalTokens
    }

    func delta(from previous: TokenBreakdown) -> TokenBreakdown {
        TokenBreakdown(
            inputTokens: inputTokens - previous.inputTokens,
            cachedInputTokens: cachedInputTokens - previous.cachedInputTokens,
            outputTokens: outputTokens - previous.outputTokens,
            reasoningOutputTokens: reasoningOutputTokens - previous.reasoningOutputTokens,
            totalTokens: totalTokens - previous.totalTokens
        )
    }
}

struct PricedTokenUsage: Equatable, Codable {
    var tokens: TokenBreakdown
    var estimatedCostUSD: Double

    static let zero = PricedTokenUsage(tokens: .zero, estimatedCostUSD: 0)

    mutating func add(tokens addedTokens: TokenBreakdown, costUSD: Double) {
        tokens.add(addedTokens)
        estimatedCostUSD += costUSD
    }
}

struct DetailedUsage: Equatable, Codable {
    let today: PricedTokenUsage
    let thirtyDay: PricedTokenUsage
    let sevenDay: PricedTokenUsage
    let month: PricedTokenUsage
    let lifetime: PricedTokenUsage
    let parsedFileCount: Int
    let tokenEventCount: Int
}

struct ModelUsageItem: Identifiable, Equatable, Codable {
    let model: String
    let provider: String
    let tokens: Int64
    let uncachedInputTokens: Int64
    let cachedInputTokens: Int64
    let outputTokens: Int64
    let estimatedCostUSD: Double
    let inputPricePerMillion: Double
    let cachedInputPricePerMillion: Double
    let outputPricePerMillion: Double
    let currency: ModelTokenPrice.Currency
    let avgTokensPerSecond: Double

    var id: String { model }
}

func modelProvider(from model: String) -> String {
    let lower = model.lowercased()

    // OpenAI
    if lower.hasPrefix("gpt-") || lower.hasPrefix("o1") || lower.hasPrefix("o3") || lower.hasPrefix("chatgpt") {
        return "OpenAI"
    }
    if lower.contains("codex") && !lower.contains("claude") {
        return "OpenAI"
    }

    // Anthropic
    if lower.hasPrefix("claude") {
        return "Anthropic"
    }

    // Google
    if lower.hasPrefix("gemini") || lower.hasPrefix("gemma") || lower.hasPrefix("palm") {
        return "Google"
    }

    // DeepSeek
    if lower.hasPrefix("deepseek") || lower.hasPrefix("ds-") || lower.contains("deepseek") {
        return "DeepSeek"
    }

    // MimoCode
    if lower.hasPrefix("mimo") || lower.contains("mimocode") {
        return "MimoCode"
    }

    // Zhipu
    if lower.hasPrefix("glm") || lower.contains("zhipu") {
        return "Zhipu AI"
    }

    // Alibaba
    if lower.hasPrefix("qwen") || lower.contains("qwen") {
        return "Alibaba"
    }

    // Meta
    if lower.hasPrefix("llama") || lower.hasPrefix("codellama") || lower.contains("llama") {
        return "Meta"
    }

    // Mistral
    if lower.hasPrefix("mistral") || lower.hasPrefix("mixtral") || lower.contains("mistral") {
        return "Mistral"
    }

    // Cohere
    if lower.hasPrefix("command") || lower.hasPrefix("c4ai") {
        return "Cohere"
    }

    // xAI
    if lower.hasPrefix("grok") {
        return "xAI"
    }

    // 01.AI
    if lower.hasPrefix("yi-") {
        return "01.AI"
    }

    // Moonshot
    if lower.hasPrefix("moonshot") || lower.hasPrefix("kimi") {
        return "Moonshot"
    }

    // MiniMax
    if lower.hasPrefix("minimax") || lower.contains("minimax") {
        return "MiniMax"
    }

    // 检查是否包含已知提供商关键词
    if lower.contains("openai") { return "OpenAI" }
    if lower.contains("anthropic") { return "Anthropic" }
    if lower.contains("google") { return "Google" }
    if lower.contains("deepseek") { return "DeepSeek" }
    if lower.contains("mimo") || lower.contains("mimocode") { return "MimoCode" }
    if lower.contains("zhipu") || lower.contains("glm") { return "Zhipu AI" }
    if lower.contains("alibaba") || lower.contains("tongyi") { return "Alibaba" }
    if lower.contains("meta") || lower.contains("facebook") { return "Meta" }
    if lower.contains("minimax") { return "MiniMax" }

    return "AI"
}

struct LocalUsage: Equatable, Codable {
    let lifetimeTokens: Int64
    let todayTokens: Int64
    let thirtyDayTokens: Int64
    let sevenDayTokens: Int64
    let threadCount: Int
    let lastUpdatedAt: Date?
    let dailyBuckets: [DailyTokenBucket]
    let sevenDayModelBuckets: [String: [DailyTokenBucket]]
    let recentThreads: [LocalThread]
    let todayModelUsage: [ModelUsageItem]
    let twentyFourHourModelUsage: [ModelUsageItem]
    let sevenDayModelUsage: [ModelUsageItem]
    let thirtyDayModelUsage: [ModelUsageItem]
    let lifetimeModelUsage: [ModelUsageItem]
    let detailedUsage: DetailedUsage?
}

enum ModelUsagePeriod: String, CaseIterable, Codable {
    case twentyFourHour
    case today
    case sevenDay
    case thirtyDay
    case lifetime

    var labelZh: String {
        switch self {
        case .today: return "今日"
        case .twentyFourHour: return "24小时"
        case .sevenDay: return "7天"
        case .thirtyDay: return "30天"
        case .lifetime: return "累计"
        }
    }

    var labelEn: String {
        switch self {
        case .today: return "Today"
        case .twentyFourHour: return "24h"
        case .sevenDay: return "7d"
        case .thirtyDay: return "30 Days"
        case .lifetime: return "All"
        }
    }
}

enum TaskColumnKind: String, Equatable, Codable {
    case active
    case pending
    case scheduled
    case done
}

struct TaskItem: Identifiable, Equatable, Codable {
    let id: String
    let rawThreadId: String
    let code: String
    let title: String
    let detail: String
    let chip: String
    let updatedAt: Date?
    let tokens: Int64?
    let kind: TaskColumnKind
}

struct TaskColumn: Identifiable, Equatable, Codable {
    let id: TaskColumnKind
    let title: String
    let count: Int
    let items: [TaskItem]
}

struct TaskBoard: Equatable, Codable {
    let refreshedAt: Date
    let columns: [TaskColumn]

    var totalCount: Int {
        columns.reduce(0) { $0 + $1.count }
    }
}

struct UsageSnapshot: Equatable, Codable {
    let provider: UsageProvider
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

    static let empty = UsageSnapshot.empty(provider: .codex)

    static func empty(provider: UsageProvider) -> UsageSnapshot {
        UsageSnapshot(
            provider: provider,
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
            messages: ["正在读取 \(provider.displayName) 数据"]
        )
    }

    func replacingTaskBoard(_ taskBoard: TaskBoard?) -> UsageSnapshot {
        UsageSnapshot(
            provider: provider,
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

    func merging(with fallback: UsageSnapshot) -> UsageSnapshot {
        UsageSnapshot(
            provider: provider,
            refreshedAt: refreshedAt,
            account: account ?? fallback.account,
            limitId: limitId ?? fallback.limitId,
            limitName: limitName ?? fallback.limitName,
            primary: primary ?? fallback.primary,
            secondary: secondary ?? fallback.secondary,
            credits: credits ?? fallback.credits,
            cloudLifetimeTokens: cloudLifetimeTokens ?? fallback.cloudLifetimeTokens,
            local: local ?? fallback.local,
            taskBoard: taskBoard ?? fallback.taskBoard,
            messages: messages.isEmpty ? fallback.messages : messages
        )
    }

    var hasPersistableContent: Bool {
        account != nil
            || primary != nil
            || secondary != nil
            || credits != nil
            || cloudLifetimeTokens != nil
            || local != nil
            || taskBoard != nil
    }
}

struct DiscoveredProvider: Identifiable, Equatable {
    let id: String
    let name: String
    let shortName: String
    let icon: String
    let databasePaths: [String]
    let type: ProviderType

    var displayName: String { name }
    var shortLabel: String { shortName }

    static func == (lhs: DiscoveredProvider, rhs: DiscoveredProvider) -> Bool {
        lhs.id == rhs.id
    }
}

enum ProviderType {
    case codex
    case mimocode
    case generic
}

enum UsageProvider: String, CaseIterable, Equatable, Codable {
    case codex
    case mimocode

    static let storageKey = "AgentDesk.usageProvider"

    var displayName: String {
        switch self {
        case .codex:
            return "Codex"
        case .mimocode:
            return "MimoCode"
        }
    }

    var shortLabel: String {
        switch self {
        case .codex:
            return "Codex"
        case .mimocode:
            return "Mimo"
        }
    }

    static func stored() -> UsageProvider {
        guard let rawValue = AgentDeskDatabase.shared.string(forKey: storageKey),
              let provider = UsageProvider(rawValue: rawValue)
        else { return .codex }
        return provider
    }

    func persist() {
        AgentDeskDatabase.shared.set(rawValue, forKey: Self.storageKey)
    }
}

struct DiagnosticItem: Identifiable {
    let id: String
    let title: String
    let detail: String
    let systemName: String
    let tint: Color
}

enum PromptAssetKind: String, CaseIterable, Equatable {
    case skill
    case prompt
    case config
}

enum PromptAssetSource: String, CaseIterable, Equatable {
    case codexSystem
    case codexUser
    case agents
    case workspace
}

struct PromptAsset: Identifiable, Equatable {
    let id: String
    let name: String
    let kind: PromptAssetKind
    let source: PromptAssetSource
    let path: String
    let summary: String
    let content: String
    let modifiedAt: Date?
    let tags: [String]
}

struct PromptRegistry: Equatable {
    let refreshedAt: Date
    let assets: [PromptAsset]

    static let empty = PromptRegistry(refreshedAt: Date(), assets: [])
}

enum AgentTargetTool: String, CaseIterable, Equatable, Codable {
    case codex
    case mimocode
}

struct AgentProfile: Identifiable, Equatable, Codable {
    let id: String
    var name: String
    var summary: String
    var persona: String
    var workingStyle: String
    var constraints: String
    var selectedAssetIDs: [String]
    var updatedAt: Date

    static func starter(name: String = "Shared Builder") -> AgentProfile {
        AgentProfile(
            id: UUID().uuidString,
            name: name,
            summary: "Shared agent profile for multi-tool collaboration.",
            persona: "",
            workingStyle: "",
            constraints: "",
            selectedAssetIDs: [],
            updatedAt: Date()
        )
    }
}

struct ModelConsumptionStat: Identifiable, Equatable {
    let id = UUID()
    let model: String
    let provider: String
    let totalTokens: Int64
    let requestCount: Int
    let avgTokens: Int64
    let lastUsed: Date

    static func == (lhs: ModelConsumptionStat, rhs: ModelConsumptionStat) -> Bool {
        lhs.model == rhs.model && lhs.totalTokens == rhs.totalTokens
    }
}

struct ModelConsumptionDetail {
    let lastUsed: Date
}

struct ProjectActivityStat: Identifiable, Equatable {
    let id = UUID()
    let name: String
    let path: String
    let sessionCount: Int
    let totalTokens: Int64

    static func == (lhs: ProjectActivityStat, rhs: ProjectActivityStat) -> Bool {
        lhs.name == rhs.name && lhs.totalTokens == rhs.totalTokens
    }
}

struct RequestStats {
    let totalRequests: Int
    let totalTokens: Int64
    let avgTokensPerRequest: Int64
    let uniqueModels: Int
    let uniqueProjects: Int
}


