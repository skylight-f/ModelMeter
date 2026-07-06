import Foundation
import SwiftUI

struct GaugeRing: View {
    let percent: Double
    let available: Bool
    let lineWidth: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .stroke(WidgetPalette.surfaceTrack, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: available ? CGFloat(max(0, min(1, percent / 100))) : 0.0)
                .stroke(
                    AngularGradient(
                        colors: [
                            WidgetPalette.brandPrimary,
                            WidgetPalette.brandPrimaryLight,
                            WidgetPalette.brandHighlight,
                            WidgetPalette.brandPrimary
                        ],
                        center: .center
                    ),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
        }
    }
}

struct DualQuotaRing: View {
    let primary: RateWindow?
    let secondary: RateWindow?
    let language: WidgetLanguage

    var body: some View {
        ZStack {
            QuotaRingSegment(
                percent: primary?.remainingPercent ?? 0,
                available: primary != nil,
                startColor: quotaPrimaryStartColor,
                endColor: quotaPrimaryEndColor,
                trackColor: quotaPrimaryTrackColor,
                lineWidth: 16
            )
            .frame(width: 145, height: 145)

            QuotaRingSegment(
                percent: secondary?.remainingPercent ?? 0,
                available: secondary != nil,
                startColor: quotaSecondaryStartColor,
                endColor: quotaSecondaryEndColor,
                trackColor: quotaSecondaryTrackColor,
                lineWidth: 16
            )
            .frame(width: 107, height: 107)

            Circle()
                .fill(WidgetPalette.surfaceTrack)
                .frame(width: 72, height: 72)

            VStack(spacing: 4) {
                QuotaRingLabel(
                    title: "5h",
                    value: remainingText(primary),
                    color: quotaPrimaryColor
                )
                QuotaRingLabel(
                    title: "7d",
                    value: remainingText(secondary),
                    color: quotaSecondaryColor
                )
                Text(language.text("剩余", "left"))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func remainingText(_ window: RateWindow?) -> String {
        guard let window else { return "--" }
        return "\(Int(window.remainingPercent.rounded()))%"
    }
}

struct QuotaRingSegment: View {
    let percent: Double
    let available: Bool
    let startColor: RingRGBColor
    let endColor: RingRGBColor
    let trackColor: Color
    let lineWidth: CGFloat

    var body: some View {
        Canvas { context, size in
            let diameter = min(size.width, size.height)
            let progress = available ? CGFloat(max(0, min(1, percent / 100))) : 0
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let radius = max(0, (diameter - lineWidth) / 2)
            let startDegrees = -90.0

            if progress < 0.999 {
                let track = arcPath(
                    center: center,
                    radius: radius,
                    from: progress,
                    to: 1,
                    startDegrees: startDegrees
                )
                context.stroke(
                    track,
                    with: .color(trackColor),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt)
                )
            }

            if progress > 0.001 {
                let segmentCount = max(240, Int(ceil(progress * 1_080)))
                let segmentLength = progress / CGFloat(segmentCount)
                let overlap = min(segmentLength * 0.65, CGFloat(0.001))
                for index in 0..<segmentCount {
                    let rawStart = CGFloat(index) / CGFloat(segmentCount) * progress
                    let rawEnd = CGFloat(index + 1) / CGFloat(segmentCount) * progress
                    let t0 = max(0, rawStart - overlap)
                    let t1 = min(progress, rawEnd + overlap)
                    let color = startColor.mixed(to: endColor, fraction: Double(index + 1) / Double(segmentCount)).color
                    let segment = arcPath(
                        center: center,
                        radius: radius,
                        from: t0,
                        to: t1,
                        startDegrees: startDegrees
                    )
                    context.stroke(
                        segment,
                        with: .color(color),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt)
                    )
                }

                let startPoint = arcPoint(center: center, radius: radius, progress: 0, startDegrees: startDegrees)
                let endPoint = arcPoint(center: center, radius: radius, progress: progress, startDegrees: startDegrees)
                context.fill(
                    Path(ellipseIn: CGRect(x: startPoint.x - lineWidth / 2, y: startPoint.y - lineWidth / 2, width: lineWidth, height: lineWidth)),
                    with: .color(startColor.color)
                )
                context.fill(
                    Path(ellipseIn: CGRect(x: endPoint.x - lineWidth / 2, y: endPoint.y - lineWidth / 2, width: lineWidth, height: lineWidth)),
                    with: .color(endColor.color)
                )
            }
        }
    }

    private func arcPath(center: CGPoint, radius: CGFloat, from start: CGFloat, to end: CGFloat, startDegrees: Double) -> Path {
        var path = Path()
        path.addArc(
            center: center,
            radius: radius,
            startAngle: .degrees(startDegrees + Double(start) * 360),
            endAngle: .degrees(startDegrees + Double(end) * 360),
            clockwise: false
        )
        return path
    }

    private func arcPoint(center: CGPoint, radius: CGFloat, progress: CGFloat, startDegrees: Double) -> CGPoint {
        let radians = (startDegrees + Double(progress) * 360) * .pi / 180
        return CGPoint(
            x: center.x + CGFloat(cos(radians)) * radius,
            y: center.y + CGFloat(sin(radians)) * radius
        )
    }
}

struct QuotaRingLabel: View {
    let title: String
    let value: String
    let color: Color

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(title)
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(color)
            Text(value)
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.primary)
        }
    }
}

struct QuotaResetSummary: View {
    let primary: RateWindow?
    let secondary: RateWindow?
    let language: WidgetLanguage

    var body: some View {
        VStack(spacing: 4) {
            QuotaResetLine(
                title: "5h",
                window: primary,
                color: quotaPrimaryColor,
                language: language
            )
            QuotaResetLine(
                title: "7d",
                window: secondary,
                color: quotaSecondaryColor,
                language: language
            )
        }
    }
}

struct QuotaResetLine: View {
    let title: String
    let window: RateWindow?
    let color: Color
    let language: WidgetLanguage

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 5, height: 5)
            Text(title)
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .foregroundStyle(color)
                .monospacedDigit()
            Text(language.text("重置", "resets"))
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Text(resetText)
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
    }

    private var resetText: String {
        guard let resetsAt = window?.resetsAt else { return "--" }
        return resetDateTime(resetsAt, language: language)
    }
}

struct DailyTokenChart: View {
    let buckets: [DailyTokenBucket]
    let language: WidgetLanguage

    var body: some View {
        HStack(alignment: .bottom, spacing: 6) {
            ForEach(buckets) { bucket in
                DailyTokenBar(bucket: bucket, maxTokens: maxTokens, language: language)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 80)
    }

    private var maxTokens: Int64 {
        max(buckets.map(\.tokens).max() ?? 0, 1)
    }
}

struct ModelDailyTokenChart: View {
    let modelBuckets: [String: [DailyTokenBucket]]
    let modelColors: [String: Color]
    let language: WidgetLanguage
    @State private var hoveredBucket: String?
    @State private var hoveredModel: String?

    private var allBuckets: [DailyTokenBucket] {
        guard let first = modelBuckets.values.first else { return [] }
        return first
    }

    private var maxTokens: Int64 {
        let total = allBuckets.map { bucket in
            modelBuckets.values.reduce(Int64(0)) { sum, buckets in
                sum + (buckets.first(where: { $0.id == bucket.id })?.tokens ?? 0)
            }
        }.max() ?? 0
        return max(total, 1)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                HStack(spacing: 4) {
                    if let model = hoveredModel, let bucketId = hoveredBucket {
                        let total = modelBuckets[model]?.first(where: { $0.id == bucketId })?.tokens ?? 0
                        Circle()
                            .fill(modelColors[model] ?? .gray)
                            .frame(width: 6, height: 6)
                        Text(model)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.primary)
                        Text(formatTokens(total))
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundStyle(modelColors[model] ?? .gray)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(hoveredModel != nil ? WidgetPalette.surfaceTrack : Color.clear)
                )
            }
            .frame(height: 28)

            Spacer(minLength: 10)

            HStack(alignment: .bottom, spacing: 6) {
                ForEach(allBuckets) { bucket in
                    ModelStackedBar(
                        bucket: bucket,
                        modelBuckets: modelBuckets,
                        modelColors: modelColors,
                        maxTokens: maxTokens,
                        hoveredBucket: $hoveredBucket,
                        hoveredModel: $hoveredModel,
                        language: language
                    )
                }
            }
            .frame(height: 70)
        }
    }
}

struct ModelStackedBar: View {
    let bucket: DailyTokenBucket
    let modelBuckets: [String: [DailyTokenBucket]]
    let modelColors: [String: Color]
    let maxTokens: Int64
    @Binding var hoveredBucket: String?
    @Binding var hoveredModel: String?
    let language: WidgetLanguage

    private var totalTokens: Int64 {
        modelBuckets.values.reduce(Int64(0)) { sum, buckets in
            sum + (buckets.first(where: { $0.id == bucket.id })?.tokens ?? 0)
        }
    }

    private var barHeight: CGFloat {
        let ratio = Double(totalTokens) / Double(maxTokens)
        return max(4, CGFloat(ratio) * 54)
    }

    var body: some View {
        VStack(alignment: .center, spacing: 8) {
            Text(formatTokens(totalTokens))
                .font(.system(size: 8, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.72)
                .foregroundStyle(.secondary)
                .opacity(hoveredBucket == bucket.id ? 1 : 0.7)

            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(WidgetPalette.surfaceTrack)
                    .frame(height: 54)

                VStack(spacing: 0) {
                    Spacer()
                    ForEach(Array(modelBuckets.keys.sorted()), id: \.self) { model in
                        let tokens = modelBuckets[model]?.first(where: { $0.id == bucket.id })?.tokens ?? 0
                        if tokens > 0 {
                            let height = max(2, CGFloat(Double(tokens) / Double(maxTokens)) * 50)
                            let isHovered = hoveredModel == model && hoveredBucket == bucket.id
                            RoundedRectangle(cornerRadius: 2, style: .continuous)
                                .fill(modelColors[model] ?? .gray)
                                .frame(height: height)
                                .overlay(
                                    Group {
                                        if isHovered {
                                            RoundedRectangle(cornerRadius: 2, style: .continuous)
                                                .stroke(.white, lineWidth: 2)
                                        }
                                    }
                                )
                                .onHover { hovering in
                                    withAnimation(.none) {
                                        if hovering {
                                            hoveredBucket = bucket.id
                                            hoveredModel = model
                                        } else {
                                            hoveredBucket = nil
                                            hoveredModel = nil
                                        }
                                    }
                                }
                        }
                    }
                }
                .frame(height: 54)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            }

            Text(localizedDayLabel(bucket.label, language: language))
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(bucket.label == "今天" ? .primary : .secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }
}

struct DailyTokenBar: View {
    let bucket: DailyTokenBucket
    let maxTokens: Int64
    let language: WidgetLanguage

    private var barHeight: CGFloat {
        let ratio = Double(bucket.tokens) / Double(maxTokens)
        return max(4, CGFloat(ratio) * 54)
    }

    var body: some View {
        VStack(spacing: 5) {
            Text(formatTokens(bucket.tokens))
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.72)
                .foregroundStyle(.secondary)
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(WidgetPalette.surfaceTrack)
                    .frame(height: 58)
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(bucket.tokens == 0 ? WidgetPalette.dataZero : WidgetPalette.brandPrimary.opacity(bucket.label == "今天" ? 1 : 0.58))
                    .frame(height: barHeight)
            }
            Text(localizedDayLabel(bucket.label, language: language))
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(bucket.label == "今天" ? .primary : .secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }
}

struct TokenSplitBar: View {
    let tokens: TokenBreakdown?

    var body: some View {
        GeometryReader { geometry in
            let splitTotal = tokens?.splitTotalTokens ?? 0
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(WidgetPalette.surfaceTrack)

                if let tokens, splitTotal > 0 {
                    HStack(spacing: 0) {
                        Rectangle()
                            .fill(uncachedInputColor)
                            .frame(width: segmentWidth(tokens.uncachedInputTokens, total: splitTotal, available: geometry.size.width))
                        Rectangle()
                            .fill(cachedInputColor)
                            .frame(width: segmentWidth(tokens.billableCachedInputTokens, total: splitTotal, available: geometry.size.width))
                        Rectangle()
                            .fill(outputTokenColor)
                            .frame(width: segmentWidth(tokens.outputTokens, total: splitTotal, available: geometry.size.width))
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                }
            }
        }
    }

    private func segmentWidth(_ value: Int64, total: Int64, available: CGFloat) -> CGFloat {
        guard total > 0, value > 0 else { return 0 }
        return max(2, available * CGFloat(Double(value) / Double(total)))
    }
}

struct TokenSplitLegendRow: View {
    let title: String
    let value: Int64?
    let color: Color

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(title)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(formatTokens(value))
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
    }
}

struct UsageProgressBar: View {
    let value: Int64
    let maxValue: Int64
    let color: Color

    var body: some View {
        GeometryReader { geo in
            let ratio = maxValue > 0 ? CGFloat(value) / CGFloat(maxValue) : 0
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(Color.gray.opacity(0.15))
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(color)
                    .frame(width: geo.size.width * min(ratio, 1))
            }
        }
        .frame(height: 4)
    }
}

struct RingRGBColor: Equatable {
    let red: Double
    let green: Double
    let blue: Double

    var color: Color {
        Color(red: red, green: green, blue: blue)
    }

    func mixed(to other: RingRGBColor, fraction: Double) -> RingRGBColor {
        let clamped = max(0, min(1, fraction))
        return RingRGBColor(
            red: red + (other.red - red) * clamped,
            green: green + (other.green - green) * clamped,
            blue: blue + (other.blue - blue) * clamped
        )
    }
}

let quotaPrimaryStartColor = WidgetPalette.brandPrimaryLightRGB
let quotaPrimaryEndColor = WidgetPalette.brandPrimaryRGB
let quotaPrimaryColor = quotaPrimaryEndColor.color
let quotaPrimaryTrackColor = WidgetPalette.surfaceTrack
let quotaSecondaryStartColor = WidgetPalette.brandHighlightRGB
let quotaSecondaryEndColor = WidgetPalette.brandSecondaryRGB
let quotaSecondaryColor = quotaSecondaryEndColor.color
let quotaSecondaryTrackColor = WidgetPalette.surfaceTrack
let uncachedInputColor = WidgetPalette.statusInfo
let cachedInputColor = WidgetPalette.brandSecondary
let outputTokenColor = WidgetPalette.statusWarning
