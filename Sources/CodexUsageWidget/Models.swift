import Foundation
import SwiftUI

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

struct TokenBreakdown: Equatable {
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

struct PricedTokenUsage: Equatable {
    var tokens: TokenBreakdown
    var estimatedCostUSD: Double

    static let zero = PricedTokenUsage(tokens: .zero, estimatedCostUSD: 0)

    mutating func add(tokens addedTokens: TokenBreakdown, costUSD: Double) {
        tokens.add(addedTokens)
        estimatedCostUSD += costUSD
    }
}

struct DetailedUsage: Equatable {
    let today: PricedTokenUsage
    let sevenDay: PricedTokenUsage
    let month: PricedTokenUsage
    let lifetime: PricedTokenUsage
    let parsedFileCount: Int
    let tokenEventCount: Int
}

struct ModelUsageItem: Identifiable, Equatable {
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

    // 检查是否包含已知提供商关键词
    if lower.contains("openai") { return "OpenAI" }
    if lower.contains("anthropic") { return "Anthropic" }
    if lower.contains("google") { return "Google" }
    if lower.contains("deepseek") { return "DeepSeek" }
    if lower.contains("alibaba") || lower.contains("tongyi") { return "Alibaba" }
    if lower.contains("meta") || lower.contains("facebook") { return "Meta" }

    return "AI"
}

struct LocalUsage: Equatable {
    let lifetimeTokens: Int64
    let todayTokens: Int64
    let sevenDayTokens: Int64
    let threadCount: Int
    let lastUpdatedAt: Date?
    let dailyBuckets: [DailyTokenBucket]
    let recentThreads: [LocalThread]
    let todayModelUsage: [ModelUsageItem]
    let sevenDayModelUsage: [ModelUsageItem]
    let lifetimeModelUsage: [ModelUsageItem]
    let detailedUsage: DetailedUsage?
}

enum ModelUsagePeriod: String, CaseIterable {
    case today
    case sevenDay
    case lifetime

    var labelZh: String {
        switch self {
        case .today: return "今日"
        case .sevenDay: return "近七天"
        case .lifetime: return "累计"
        }
    }

    var labelEn: String {
        switch self {
        case .today: return "Today"
        case .sevenDay: return "7 Days"
        case .lifetime: return "All"
        }
    }
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

enum UsageProvider: String, CaseIterable, Equatable {
    case codex
    case mimocode

    static let storageKey = "ModelMeter.usageProvider"

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

    static func stored(defaults: UserDefaults = .standard) -> UsageProvider {
        guard let rawValue = defaults.string(forKey: storageKey),
              let provider = UsageProvider(rawValue: rawValue)
        else { return .codex }
        return provider
    }

    func persist(defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: Self.storageKey)
    }
}

struct DiagnosticItem: Identifiable {
    let id: String
    let title: String
    let detail: String
    let systemName: String
    let tint: Color
}
