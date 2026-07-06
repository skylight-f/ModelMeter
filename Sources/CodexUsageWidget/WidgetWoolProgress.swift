import Foundation
import SwiftUI

struct SubscriptionMilestone: Identifiable {
    let id: String
    let title: String
    let amountUSD: Double
    let color: Color
}

let subscriptionMilestones: [SubscriptionMilestone] = [
    SubscriptionMilestone(id: "plus", title: "Plus", amountUSD: 20, color: WidgetPalette.statusInfo),
    SubscriptionMilestone(id: "pro100", title: "Pro100", amountUSD: 100, color: WidgetPalette.brandSecondary),
    SubscriptionMilestone(id: "pro200", title: "Pro200", amountUSD: 200, color: WidgetPalette.brandPrimaryLight)
]

// Used only for the full-quota monthly ceiling. Actual usage still uses per-session model prices and token splits.
let quotaValueDailyTokenLimit: Double = 200_000_000
let quotaValueBillingDays: Double = 30
let quotaValueUncachedInputShare = 0.30
let quotaValueCachedInputShare = 0.50
let quotaValueOutputShare = 0.20
let quotaValueReferencePrice = modelTokenPrice(for: "chat-latest")
let quotaValueWeightedPricePerMillion =
    quotaValueUncachedInputShare * quotaValueReferencePrice.inputPerMillion
    + quotaValueCachedInputShare * quotaValueReferencePrice.cachedInputPerMillion
    + quotaValueOutputShare * quotaValueReferencePrice.outputPerMillion
let quotaValueMonthlyTokenLimit = quotaValueDailyTokenLimit * quotaValueBillingDays
let quotaValueMonthlyMaxUSD = quotaValueMonthlyTokenLimit / 1_000_000 * quotaValueWeightedPricePerMillion

struct WoolProgressCard: View {
    let usage: PricedTokenUsage?
    let language: WidgetLanguage
    let currency: ModelTokenPrice.Currency

    private var cost: Double {
        usage?.estimatedCostUSD ?? 0
    }

    private var maxValue: Double {
        max(quotaValueMonthlyMaxUSD, subscriptionMilestones.map(\.amountUSD).max() ?? 200)
    }

    private var accent: Color {
        if cost >= 200 { return WidgetPalette.brandPrimaryLight }
        if cost >= 100 { return WidgetPalette.brandSecondary }
        if cost >= 20 { return WidgetPalette.statusInfo }
        return WidgetPalette.statusWarning
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: cost >= 20 ? "chart.line.uptrend.xyaxis" : "target")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(accent)
                Text(language.text("羊毛进度", "Value progress"))
                    .font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 8)
                Text(formatUSD(usage?.estimatedCostUSD, currency: currency))
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(currencyColor(currency))
                Text("/ \(formatCompactUSD(maxValue, currency: currency))")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }

            QuotaValueProgressBar(
                currentValue: cost,
                maxValue: maxValue,
                accent: accent,
                currency: currency
            )
            .frame(height: 18)

            HStack(spacing: 8) {
                ForEach(subscriptionMilestones) { milestone in
                    HStack(spacing: 4) {
                        Circle()
                            .fill(milestone.color)
                            .frame(width: 5, height: 5)
                        Text(milestone.title)
                            .font(.system(size: 8.5, weight: .semibold, design: .rounded))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                Text("\(language.text("满额", "Cap")) \(formatCompactUSD(maxValue, currency: currency))")
                    .font(.system(size: 8.5, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

        }
        .padding(10)
        .cardBackground(cornerRadius: 10)
    }
}