import Foundation
import SwiftUI

struct ModelUsageRow: View {
    let item: ModelUsageItem
    let language: WidgetLanguage
    let maxTokens: Int64
    var onSelect: ((ModelUsageItem) -> Void)? = nil

    private var cacheHitRate: Double {
        let totalInput = item.uncachedInputTokens + item.cachedInputTokens
        guard totalInput > 0 else { return 0 }
        return Double(item.cachedInputTokens) / Double(totalInput) * 100
    }

    private var providerColor: Color {
        let model = item.model.lowercased()
        if model.contains("mimo") { return .orange }
        if model.contains("gpt") || model.contains("codex") { return .green }
        if model.contains("claude") { return .purple }
        if model.contains("qwen") { return .blue }
        if model.contains("glm") { return .cyan }
        if model.contains("deepseek") { return .red }
        if model.contains("gemini") { return .green }
        return .gray
    }

    private var hasPriceData: Bool {
        item.inputPricePerMillion > 0 || item.outputPricePerMillion > 0
    }

    private var priceText: String {
        let symbol = item.currency.rawValue
        return "\(symbol)\(String(format: "%.2f", item.inputPricePerMillion))/\(symbol)\(String(format: "%.2f", item.cachedInputPricePerMillion))/\(symbol)\(String(format: "%.2f", item.outputPricePerMillion))"
    }

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.model)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text(item.provider)
                        .font(.system(size: 8, weight: .medium))
                        .foregroundStyle(providerColor)
                    if hasPriceData {
                        Text(priceText)
                            .font(.system(size: 7, weight: .medium, design: .rounded))
                            .foregroundStyle(currencyColor(item.currency).opacity(0.6))
                    }
                }
            }
            .frame(width: 160, alignment: .leading)

            UsageProgressBar(
                value: item.tokens,
                maxValue: maxTokens,
                color: providerColor
            )
            .frame(width: 120, height: 4)

            Spacer(minLength: 4)

            if item.avgTokensPerSecond > 0 {
                Text(String(format: "%.0f/s", item.avgTokensPerSecond))
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(speedColor(item.avgTokensPerSecond))
                    .lineLimit(1)
                    .frame(minWidth: 36, alignment: .trailing)
            } else {
                Text("-")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.tertiary)
                    .frame(minWidth: 36, alignment: .trailing)
            }

            Text(formatTokens(item.uncachedInputTokens))
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(uncachedInputColor)
                .lineLimit(1)
                .frame(minWidth: 42, alignment: .trailing)

            Text(formatTokens(item.cachedInputTokens))
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(cachedInputColor)
                .lineLimit(1)
                .frame(minWidth: 42, alignment: .trailing)

            Text(formatTokens(item.outputTokens))
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(WidgetPalette.statusSuccess)
                .lineLimit(1)
                .frame(minWidth: 42, alignment: .trailing)

            Text(formatTokens(item.tokens))
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.primary)
                .lineLimit(1)
                .frame(minWidth: 46, alignment: .trailing)

            Text(cacheHitRate > 0 ? "\(Int(cacheHitRate))%" : "-")
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(cacheHitRate >= 50 ? WidgetPalette.brandSecondary : .secondary)
                .lineLimit(1)
                .frame(minWidth: 36, alignment: .trailing)

            Text(formatUSD(item.estimatedCostUSD, currency: item.currency))
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(currencyColor(item.currency))
                .lineLimit(1)
                .frame(minWidth: 46, alignment: .trailing)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .contentShape(Rectangle())
        .onTapGesture {
            onSelect?(item)
        }
        .help(language.text(
            "\(item.provider) \(item.model): 总计 \(formatTokens(item.tokens)), 缓存命中 \(Int(cacheHitRate))%\n点击查看详情",
            "\(item.provider) \(item.model): total \(formatTokens(item.tokens)), cache hit \(Int(cacheHitRate))%\nClick for details"
        ))
    }
}

struct ModelDetailView: View {
    let item: ModelUsageItem
    let language: WidgetLanguage
    @Environment(\.dismiss) private var dismiss

    private var cacheHitRate: Double {
        let totalInput = item.uncachedInputTokens + item.cachedInputTokens
        guard totalInput > 0 else { return 0 }
        return Double(item.cachedInputTokens) / Double(totalInput) * 100
    }

    private var totalInputTokens: Int64 {
        item.uncachedInputTokens + item.cachedInputTokens
    }

    private var outputShare: Double {
        guard item.tokens > 0 else { return 0 }
        return Double(max(item.outputTokens, 0)) / Double(item.tokens) * 100
    }

    private var effectiveCostPerMillion: Double {
        guard item.tokens > 0 else { return 0 }
        return item.estimatedCostUSD / Double(item.tokens) * 1_000_000
    }

    private var hasPriceData: Bool {
        item.inputPricePerMillion > 0
            || item.cachedInputPricePerMillion > 0
            || item.outputPricePerMillion > 0
    }

    private var speedText: String {
        guard item.avgTokensPerSecond > 0 else {
            return language.text("无速度数据", "No speed data")
        }
        return String(format: "%.1f tokens/s", item.avgTokensPerSecond)
    }

    private var priceSummaryText: String {
        guard hasPriceData else {
            return language.text("未收录价格", "No price data")
        }
        let symbol = item.currency.rawValue
        return "\(symbol)\(String(format: "%.2f", item.inputPricePerMillion))/\(symbol)\(String(format: "%.2f", item.cachedInputPricePerMillion))/\(symbol)\(String(format: "%.2f", item.outputPricePerMillion))"
    }

    private var providerColor: Color {
        let model = item.model.lowercased()
        if model.contains("mimo") { return .orange }
        if model.contains("gpt") || model.contains("codex") { return .green }
        if model.contains("claude") { return .purple }
        if model.contains("qwen") { return .blue }
        if model.contains("glm") { return .cyan }
        if model.contains("deepseek") { return .red }
        if model.contains("gemini") { return .green }
        return .gray
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(item.model)
                            .font(.title2.bold())
                            .lineLimit(2)
                            .textSelection(.enabled)
                        HStack(spacing: 8) {
                            Text(item.provider)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(providerColor)
                                .textSelection(.enabled)
                            Text(priceSummaryText)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(hasPriceData ? currencyColor(item.currency) : .secondary)
                        }
                    }
                    Spacer()
                    Button(action: { dismiss() }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }

                Divider()

                LazyVGrid(columns: [
                    GridItem(.flexible()),
                    GridItem(.flexible()),
                    GridItem(.flexible())
                ], spacing: 10) {
                    DetailMetricCard(
                        title: language.text("总消耗", "Total"),
                        value: formatTokens(item.tokens),
                        color: .primary
                    )
                    DetailMetricCard(
                        title: language.text("费用", "Cost"),
                        value: formatUSD(item.estimatedCostUSD, currency: item.currency),
                        color: currencyColor(item.currency)
                    )
                    DetailMetricCard(
                        title: language.text("速度", "Speed"),
                        value: speedText,
                        color: item.avgTokensPerSecond > 0 ? speedColor(item.avgTokensPerSecond) : .secondary
                    )
                    DetailMetricCard(
                        title: language.text("总输入", "Input"),
                        value: formatTokens(totalInputTokens),
                        color: .primary
                    )
                    DetailMetricCard(
                        title: language.text("缓存率", "Cache Hit"),
                        value: totalInputTokens > 0 ? "\(Int(cacheHitRate))%" : "-",
                        color: cacheHitRate >= 50 ? WidgetPalette.brandSecondary : .secondary
                    )
                    DetailMetricCard(
                        title: language.text("输出占比", "Output Share"),
                        value: item.tokens > 0 ? "\(Int(outputShare))%" : "-",
                        color: WidgetPalette.statusSuccess
                    )
                }

                if item.tokens > 0 {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(language.text("Token 分布", "Token Distribution"))
                            .font(.subheadline.bold())
                        TokenSplitBar(tokens: TokenBreakdown(
                            inputTokens: totalInputTokens,
                            cachedInputTokens: item.cachedInputTokens,
                            outputTokens: item.outputTokens,
                            reasoningOutputTokens: 0,
                            totalTokens: item.tokens
                        ))
                        .frame(height: 12)

                        HStack(spacing: 16) {
                            LegendItem(color: uncachedInputColor, text: language.text("未缓存输入", "Uncached input"))
                            LegendItem(color: cachedInputColor, text: language.text("缓存输入", "Cached input"))
                            LegendItem(color: WidgetPalette.statusSuccess, text: language.text("输出", "Output"))
                        }
                        .font(.caption)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text(language.text("列表字段", "List Fields"))
                        .font(.subheadline.bold())
                    ModelDetailInfoRow(
                        title: language.text("未缓存输入", "Uncached Input"),
                        value: formatTokens(item.uncachedInputTokens),
                        color: uncachedInputColor
                    )
                    ModelDetailInfoRow(
                        title: language.text("缓存输入", "Cached Input"),
                        value: formatTokens(item.cachedInputTokens),
                        color: cachedInputColor
                    )
                    ModelDetailInfoRow(
                        title: language.text("输出", "Output"),
                        value: formatTokens(item.outputTokens),
                        color: WidgetPalette.statusSuccess
                    )
                    ModelDetailInfoRow(
                        title: language.text("总消耗", "Total Tokens"),
                        value: formatTokens(item.tokens),
                        color: .primary
                    )
                    ModelDetailInfoRow(
                        title: language.text("缓存命中率", "Cache Hit Rate"),
                        value: totalInputTokens > 0 ? String(format: "%.1f%%", cacheHitRate) : "-",
                        color: cacheHitRate >= 50 ? WidgetPalette.brandSecondary : .secondary
                    )
                    ModelDetailInfoRow(
                        title: language.text("估算费用", "Estimated Cost"),
                        value: formatUSD(item.estimatedCostUSD, currency: item.currency),
                        color: currencyColor(item.currency)
                    )
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text(language.text("价格与效率", "Pricing and Efficiency"))
                        .font(.subheadline.bold())
                    ModelDetailInfoRow(
                        title: language.text("输入价格 / 百万", "Input / 1M"),
                        value: formatUSDPerMillion(item.inputPricePerMillion, currency: item.currency),
                        color: currencyColor(item.currency)
                    )
                    ModelDetailInfoRow(
                        title: language.text("缓存输入价格 / 百万", "Cached Input / 1M"),
                        value: formatUSDPerMillion(item.cachedInputPricePerMillion, currency: item.currency),
                        color: currencyColor(item.currency)
                    )
                    ModelDetailInfoRow(
                        title: language.text("输出价格 / 百万", "Output / 1M"),
                        value: formatUSDPerMillion(item.outputPricePerMillion, currency: item.currency),
                        color: currencyColor(item.currency)
                    )
                    ModelDetailInfoRow(
                        title: language.text("实际均价 / 百万 token", "Effective / 1M tokens"),
                        value: item.tokens > 0 ? formatUSD(effectiveCostPerMillion, currency: item.currency) : "-",
                        color: currencyColor(item.currency)
                    )
                    ModelDetailInfoRow(
                        title: language.text("平均输出速度", "Average Output Speed"),
                        value: speedText,
                        color: item.avgTokensPerSecond > 0 ? speedColor(item.avgTokensPerSecond) : .secondary
                    )
                }
            }
            .padding(20)
        }
        .frame(width: 480, height: 560)
    }
}

struct ModelDetailInfoRow: View {
    let title: String
    let value: String
    let color: Color

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(color)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(WidgetPalette.surfaceTrack)
        )
    }
}

struct ModelConsumptionRow: View {
    let stat: ModelConsumptionStat
    let maxTokens: Int64
    let language: WidgetLanguage

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(stat.model)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(formatTokens(stat.totalTokens))
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                Text("\(stat.requestCount)次")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
            GeometryReader { geo in
                let barWidth = maxTokens > 0 ? CGFloat(stat.totalTokens) / CGFloat(maxTokens) : 0
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(WidgetPalette.controlFill(.light))
                    .frame(width: geo.size.width)
                    .overlay(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(modelColor(for: stat.model))
                            .frame(width: geo.size.width * barWidth)
                    }
            }
            .frame(height: 6)
        }
    }

    private func modelColor(for model: String) -> Color {
        if model.contains("mimo") { return .orange }
        if model.contains("gpt") { return .green }
        if model.contains("qwen") { return .blue }
        if model.contains("glm") { return .purple }
        if model.contains("deepseek") { return .cyan }
        return .gray
    }
}
