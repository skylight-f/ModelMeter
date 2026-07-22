import AppKit
import SwiftUI

struct LeadershipPreviewFixture: Equatable {
    let level: Int

    private static let scores = [10, 27, 42, 57, 72, 86, 96, 100]
    private static let peaks = [1, 2, 4, 6, 9, 14, 21, 32]
    private static let agents = [1, 2, 4, 6, 10, 16, 24, 36]
    private static let hours = [0.8, 2.1, 4.6, 8.2, 14.8, 28.6, 46.0, 72.0]

    private var index: Int { min(max(level, 1), 8) - 1 }
    var score: Int { Self.scores[index] }
    var title: LeadershipTitle { LeadershipScoreModel.title(for: score) }
    var peakConcurrency: Int { Self.peaks[index] }
    var agentCount: Int { Self.agents[index] }
    var aiHours: Double { Self.hours[index] }
}

struct LeadershipCommandRadiusButton: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.visualTokens) private var visualTokens
    let snapshot: LeadershipDashboardSnapshot
    let previewLevel: Int?
    let language: WidgetLanguage
    let action: () -> Void
    @State private var isHovering = false

    private var report: LeadershipReport? { snapshot.defaultReport }
    private var today: LeadershipReport? { snapshot.todayReport }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                ZStack {
                    LeadershipCommandRadiusGraphic(
                        level: displayTitle?.level ?? 0,
                        peakConcurrency: displayPeakConcurrency,
                        highlighted: isHovering
                    )

                    LeadershipBadgeLockup(
                        title: displayTitle,
                        emptyTitle: language.text("记录建立中", "Building history"),
                        imageSize: 58,
                        plaqueWidth: 95
                    )

                    VStack {
                        HStack(alignment: .center, spacing: 4) {
                            Label(language.text("AI 领导力", "AI Leadership"), systemImage: "scope")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.secondary)
                            Spacer(minLength: 2)
                            Text("28D")
                                .font(.system(size: 8, weight: .bold, design: .rounded))
                                .foregroundStyle(visualTokens.accent.primary.color)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(
                                    Capsule(style: .continuous)
                                        .fill(visualTokens.accent.primary.color.opacity(0.12))
                                )
                        }
                        Spacer()
                    }
                }
                .frame(width: 145, height: 145)

                VStack(spacing: 4) {
                    HStack(spacing: 4) {
                        OverviewFactTile(
                            systemName: "sparkles",
                            value: displayScore.map(String.init) ?? "--",
                            label: language.text("领导力分值", "Score")
                        )
                        OverviewFactTile(
                            systemName: "person.3.fill",
                            value: todayAgentValue,
                            label: language.text("Agent", "Agents")
                        )
                    }
                    HStack(spacing: 4) {
                        OverviewFactTile(
                            systemName: "clock.fill",
                            value: todayHoursValue,
                            label: language.text("AI 工时", "AI hours")
                        )
                        OverviewFactTile(
                            systemName: "arrow.up.right.and.arrow.down.left",
                            value: displayPeakConcurrencyValue.map { "\($0)×" } ?? "--",
                            label: language.text("峰值并发", "Peak")
                        )
                    }
                }
                .frame(width: 154)
            }
            .frame(width: 154, alignment: .top)
            .contentShape(Rectangle())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilitySummary)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if reduceMotion {
                isHovering = hovering
            } else {
                withAnimation(.easeOut(duration: 0.2)) {
                    isHovering = hovering
                }
            }
        }
        .help(language.text("查看 AI 领导力详情；轨道节点表示滚动 28 天峰值并发", "View AI leadership details; orbit nodes represent 28-day peak concurrency"))
    }

    private var preview: LeadershipPreviewFixture? {
        previewLevel.map(LeadershipPreviewFixture.init(level:))
    }

    private var displayScore: Int? { preview?.score ?? report?.score }
    private var displayTitle: LeadershipTitle? { preview?.title ?? report?.title }
    private var displayPeakConcurrencyValue: Int? { preview?.peakConcurrency ?? report?.peakConcurrency }
    private var displayPeakConcurrency: Int { displayPeakConcurrencyValue ?? 0 }

    private var todayAgentValue: String {
        preview.map { String($0.agentCount) } ?? today?.agentCount.map(String.init) ?? "--"
    }

    private var todayHoursValue: String {
        leadershipHours(preview?.aiHours ?? today?.aiHours)
    }

    private var accessibilitySummary: String {
        let score = displayScore.map(String.init) ?? language.text("暂无得分", "No score")
        let title = displayTitle?.name ?? language.text("记录建立中", "Building history")
        let peak = displayPeakConcurrencyValue.map(String.init) ?? language.text("暂无", "unavailable")
        return language.text(
            "AI 领导力，\(score) 分，\(title)，今日领导 \(todayAgentValue) 个 Agent，AI 工时 \(todayHoursValue)，峰值并发 \(peak)",
            "AI leadership, score \(score), \(title), \(todayAgentValue) agents today, \(todayHoursValue) AI hours, peak concurrency \(peak)"
        )
    }
}

struct OverviewFactTile: View {
    @Environment(\.visualTokens) private var visualTokens
    let systemName: String
    let value: String
    let label: String

    var body: some View {
        VStack(spacing: 1) {
            HStack(spacing: 4) {
                Image(systemName: systemName)
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(visualTokens.accent.primary.color)
                Text(value)
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.68)
            }
            Text(label)
                .font(.system(size: 8, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(FixedVisualPalette.controlFill(colorScheme))
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(FixedVisualPalette.controlStroke(colorScheme), lineWidth: 0.7)
                )
        )
    }

    @Environment(\.colorScheme) private var colorScheme
}

private struct LeadershipCommandRadiusGraphic: View {
    @Environment(\.visualTokens) private var visualTokens
    static let maximumVisibleNodes = 8

    let level: Int
    let peakConcurrency: Int
    let highlighted: Bool

    var body: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let allRadii: [CGFloat] = [30, 46, 62]
            let radii = Array(allRadii[0..<ringCount])

            for (index, radius) in radii.enumerated() {
                let rect = CGRect(
                    x: center.x - radius,
                    y: center.y - radius,
                    width: radius * 2,
                    height: radius * 2
                )
                let strength = Double(index + 1) / Double(max(radii.count, 1))
                let glowOpacity = 0.055 + strength * 0.045 + (highlighted ? 0.025 : 0)
                context.stroke(
                    Path(ellipseIn: rect),
                    with: .color(visualTokens.accent.primary.color.opacity(glowOpacity)),
                    lineWidth: 7 + CGFloat(index) * 1.5
                )
                context.stroke(
                    Path(ellipseIn: rect),
                    with: .color(visualTokens.accent.primaryLight.color.opacity(0.13 + strength * 0.08)),
                    lineWidth: 3.6 + CGFloat(index) * 0.7
                )
                let dash: [CGFloat]
                switch index {
                case 0: dash = []
                case 1: dash = [5, 3]
                default: dash = [8, 3, 2, 3]
                }
                context.stroke(
                    Path(ellipseIn: rect),
                    with: .color(visualTokens.accent.primaryStrong.color.opacity(0.50 + strength * 0.22 + (highlighted ? 0.10 : 0))),
                    style: StrokeStyle(
                        lineWidth: 1.4 + CGFloat(index) * 0.45,
                        lineCap: .round,
                        lineJoin: .round,
                        dash: dash
                    )
                )
            }

            let visibleNodeCount = min(max(peakConcurrency, 0), Self.maximumVisibleNodes)
            for index in 0..<visibleNodeCount {
                let ringIndex = index % max(ringCount, 1)
                let nodesOnRing = (visibleNodeCount + ringCount - 1 - ringIndex) / ringCount
                let positionOnRing = index / max(ringCount, 1)
                let phase = -Double.pi / 2 + Double(ringIndex) * 0.54
                let angle = phase + Double(positionOnRing) / Double(max(nodesOnRing, 1)) * Double.pi * 2
                let radius = radii[ringIndex]
                let point = CGPoint(
                    x: center.x + radius * CGFloat(cos(angle)),
                    y: center.y + radius * CGFloat(sin(angle))
                )
                let nodeSize: CGFloat = ringIndex == radii.count - 1 ? 8 : 7
                let nodeRect = CGRect(
                    x: point.x - nodeSize / 2,
                    y: point.y - nodeSize / 2,
                    width: nodeSize,
                    height: nodeSize
                )
                context.fill(
                    Path(ellipseIn: nodeRect.insetBy(dx: -5, dy: -5)),
                    with: .color(visualTokens.accent.primary.color.opacity(highlighted ? 0.18 : 0.12))
                )
                context.fill(Path(ellipseIn: nodeRect), with: .color(visualTokens.accent.primaryStrong.color))
                context.stroke(
                    Path(ellipseIn: nodeRect.insetBy(dx: -1.8, dy: -1.8)),
                    with: .color(visualTokens.accent.primaryLight.color.opacity(0.72)),
                    lineWidth: 1.2
                )
            }
        }
        .opacity(highlighted ? 1 : 0.96)
        .accessibilityHidden(true)
    }

    private var ringCount: Int {
        switch level {
        case ...1: 1
        case 2...4: 2
        default: 3
        }
    }
}

private struct LeadershipBadgeLockup: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.visualTokens) private var visualTokens
    let title: LeadershipTitle?
    let emptyTitle: String
    let imageSize: CGFloat
    let plaqueWidth: CGFloat

    var body: some View {
        ZStack {
            LeadershipBadgeImage(level: title?.level ?? 0)
                .frame(width: imageSize, height: imageSize)
                .shadow(color: visualTokens.accent.primary.color.opacity(0.18), radius: 5, y: 2)

            HStack(spacing: 3) {
                if let title {
                    Text("L\(min(title.level, 7))")
                        .foregroundStyle(visualTokens.accent.primaryStrong.color)
                }
                Text(title?.name ?? emptyTitle)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
            .font(.system(size: 8, weight: .bold, design: .rounded))
            .padding(.horizontal, 6)
            .frame(width: plaqueWidth, height: 18)
            .background(
                Capsule(style: .continuous)
                    .fill(FixedVisualPalette.controlFill(colorScheme))
                    .overlay(
                        Capsule(style: .continuous)
                            .strokeBorder(visualTokens.accent.primary.color.opacity(0.38), lineWidth: 0.8)
                    )
            )
            .offset(y: imageSize / 2 + 6)
        }
        .frame(width: plaqueWidth, height: imageSize)
        .accessibilityElement(children: .combine)
    }
}

private struct LeadershipBadgeImage: View {
    let level: Int

    var body: some View {
        Group {
            if let image = LeadershipBadgeAssets.image(for: level) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .antialiased(true)
                    .scaledToFit()
            } else {
                Image(systemName: "circle.hexagongrid.fill")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.tertiary)
                    .padding(7)
            }
        }
        .accessibilityHidden(true)
    }
}

private enum LeadershipBadgeAssets {
    private static let cache = NSCache<NSNumber, NSImage>()

    static func image(for level: Int) -> NSImage? {
        guard level > 0 else { return nil }
        let assetLevel = min(max(level, 1), 7)
        let key = NSNumber(value: assetLevel)
        if let cached = cache.object(forKey: key) { return cached }
        guard let url = Bundle.main.url(
            forResource: "leadership-badge-l\(assetLevel)",
            withExtension: "png",
            subdirectory: "LeadershipBadges"
        ), let image = NSImage(contentsOf: url) else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }
}

struct LeadershipDashboardPanel: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.visualTokens) private var visualTokens
    let snapshot: LeadershipDashboardSnapshot
    let language: WidgetLanguage
    @Binding var previewLevel: Int?
    @State private var period: LeadershipPeriod = .twentyEightDays

    private var report: LeadershipReport? {
        snapshot.report(period: period)
    }

    private var preview: LeadershipPreviewFixture? {
        previewLevel.map(LeadershipPreviewFixture.init(level:))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                LeadershipPeriodControl(selection: $period, language: language)
                Spacer(minLength: 10)
                LeadershipPreviewMenu(selection: $previewLevel, language: language)
            }

            LeadershipRankProgressHeader(
                score: preview?.score ?? report?.score,
                title: preview?.title ?? report?.title,
                isPreviewing: preview != nil,
                language: language
            )

            if let report {
                LeadershipFactStrip(report: report, preview: preview, language: language)

                HStack(alignment: .top, spacing: 10) {
                    LeadershipDimensionCard(report: report, language: language)
                        .frame(maxWidth: .infinity)
                    LeadershipWorkforceChartCard(report: report, language: language)
                        .frame(maxWidth: .infinity)
                }
                .frame(height: 210)

                LeadershipProjectCard(report: report, language: language)
                    .frame(height: 170)
            } else {
                LeadershipEmptyState(language: language)
                    .frame(height: 286)
            }
        }
        .accessibilityElement(children: .contain)
    }
}

private struct LeadershipRankProgressHeader: View {
    @Environment(\.visualTokens) private var visualTokens
    let score: Int?
    let title: LeadershipTitle?
    let isPreviewing: Bool
    let language: WidgetLanguage

    private var normalizedScore: Double {
        Double(min(max(score ?? 0, 0), 100)) / 100
    }

    var body: some View {
        VStack(spacing: 5) {
            GeometryReader { geometry in
                let trackInset: CGFloat = 38
                let trackWidth = max(geometry.size.width - trackInset * 2, 1)

                ZStack(alignment: .topLeading) {
                    ForEach(1...8, id: \.self) { level in
                        let fixture = LeadershipPreviewFixture(level: level)
                        let isCurrent = title?.level == level
                        VStack(spacing: 1) {
                            LeadershipBadgeImage(level: level)
                                .frame(width: isCurrent ? 29 : 25, height: isCurrent ? 29 : 25)
                                .shadow(
                                    color: visualTokens.accent.primary.color.opacity(isCurrent ? 0.42 : 0.10),
                                    radius: isCurrent ? 6 : 2,
                                    y: 1
                                )
                            Text(fixture.title.name)
                                .font(.system(size: 7.2, weight: isCurrent ? .bold : .semibold, design: .rounded))
                                .foregroundStyle(isCurrent ? visualTokens.accent.primaryStrong.color : Color.secondary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.72)
                        }
                        .frame(width: 62)
                        .opacity(title == nil || isCurrent ? 1 : 0.72)
                        .position(
                            x: trackInset + trackWidth * CGFloat(threshold(for: level)),
                            y: 23
                        )
                    }
                }
            }
            .frame(height: 47)

            GeometryReader { geometry in
                let trackInset: CGFloat = 38
                let trackWidth = max(geometry.size.width - trackInset * 2, 1)
                let scorePosition = trackInset + trackWidth * CGFloat(score == nil ? 0.5 : normalizedScore)

                ZStack(alignment: .topLeading) {
                    Capsule()
                        .fill(FixedVisualPalette.surfaceTrack)
                        .frame(width: trackWidth, height: 16)
                        .offset(x: trackInset)
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [visualTokens.accent.primary.color, visualTokens.accent.primaryStrong.color],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: trackWidth * CGFloat(normalizedScore), height: 16)
                        .offset(x: trackInset)
                    ForEach(1...8, id: \.self) { level in
                        Circle()
                            .fill(level <= (title?.level ?? 0) ? Color.white : visualTokens.accent.primary.color.opacity(0.34))
                            .overlay(Circle().strokeBorder(visualTokens.accent.primaryStrong.color.opacity(0.72), lineWidth: 0.8))
                            .frame(width: 6, height: 6)
                            .position(
                                x: trackInset + trackWidth * CGFloat(threshold(for: level)),
                                y: 8
                            )
                    }
                    Text(score.map { "\($0) / 100" } ?? "-- / 100")
                        .font(.system(size: 8.5, weight: .heavy, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .frame(height: 14)
                        .background(Capsule().fill(visualTokens.accent.primaryStrong.color))
                        .position(x: scorePosition, y: 8)
                }
            }
            .frame(height: 16)

            HStack(spacing: 6) {
                Text(language.text("当前", "Current"))
                    .foregroundStyle(.secondary)
                Text(currentTitle)
                    .fontWeight(.bold)
                if isPreviewing {
                    Text(language.text("样式预览", "Style preview"))
                        .foregroundStyle(visualTokens.accent.primaryStrong.color)
                }
                Spacer(minLength: 0)
            }
            .font(.system(size: 8, weight: .semibold, design: .rounded))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, minHeight: 88)
        .cardBackground(cornerRadius: 10, elevated: true)
        .accessibilityElement(children: .combine)
    }

    private var currentTitle: String {
        guard let title else { return language.text("记录建立中", "Building history") }
        return "L\(min(title.level, 8)) · \(title.name)"
    }

    private func threshold(for level: Int) -> Double {
        switch level {
        case 1: 0
        case 2: 0.20
        case 3: 0.35
        case 4: 0.50
        case 5: 0.65
        case 6: 0.80
        case 7: 0.93
        default: 1
        }
    }
}

private struct LeadershipPreviewMenu: View {
    @Binding var selection: Int?
    let language: WidgetLanguage

    var body: some View {
        Menu {
            Button {
                selection = nil
            } label: {
                Label(language.text("真实数据", "Live data"), systemImage: selection == nil ? "checkmark" : "chart.line.uptrend.xyaxis")
            }
            Divider()
            ForEach(1...8, id: \.self) { level in
                let fixture = LeadershipPreviewFixture(level: level)
                Button {
                    selection = level
                } label: {
                    Label("L\(level) · \(fixture.title.name)", systemImage: selection == level ? "checkmark" : "circle.hexagongrid")
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "testtube.2")
                Text(selection.map { "L\($0)" } ?? language.text("样式预览", "Style preview"))
            }
            .font(.system(size: 9, weight: .semibold))
            .padding(.horizontal, 9)
            .frame(height: 26)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(language.text("仅预览等级样式，不修改真实数据", "Preview rank styles without changing live data"))
    }
}

private struct LeadershipPeriodControl: View {
    @Binding var selection: LeadershipPeriod
    let language: WidgetLanguage

    var body: some View {
        LeadershipMiniSegments(
            selection: $selection,
            options: LeadershipPeriod.allCases,
            label: { period in
                switch period {
                case .today: language.text("今日", "Today")
                case .sevenDays: language.text("7 天", "7 days")
                case .twentyEightDays: language.text("28 天", "28 days")
                }
            }
        )
    }
}

private struct LeadershipMiniSegments<Option: Identifiable & Equatable>: View where Option.ID: Hashable {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.visualTokens) private var visualTokens
    @Binding var selection: Option
    let options: [Option]
    let label: (Option) -> String

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options) { option in
                Button {
                    selection = option
                } label: {
                    Text(label(option))
                        .font(.system(size: 10, weight: selection == option ? .semibold : .medium))
                        .foregroundStyle(selection == option ? Color.white : Color.secondary)
                        .lineLimit(1)
                        .padding(.horizontal, 10)
                        .frame(height: 24)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(selection == option ? visualTokens.accent.primary.color : Color.clear)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == option ? .isSelected : [])
            }
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(FixedVisualPalette.controlFill(colorScheme))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(FixedVisualPalette.controlStroke(colorScheme), lineWidth: 0.8)
                )
        )
    }
}

private struct LeadershipDimensionCard: View {
    let report: LeadershipReport
    let language: WidgetLanguage

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(language.text("等级分值明细", "Rank score detail"), systemImage: "slider.horizontal.3")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)

            ForEach(LeadershipDimensionKind.allCases) { kind in
                LeadershipDimensionRow(
                    dimension: report.dimensions.first { $0.kind == kind },
                    kind: kind,
                    language: language
                )
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .cardBackground(cornerRadius: 10)
    }
}

private struct LeadershipDimensionRow: View {
    @Environment(\.visualTokens) private var visualTokens
    let dimension: LeadershipDimension?
    let kind: LeadershipDimensionKind
    let language: WidgetLanguage

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(visualTokens.data.series[colorIndex].color)
                .frame(width: 17)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.system(size: 10, weight: .semibold))
                    Text(summary)
                        .font(.system(size: 8, weight: .medium))
                        .foregroundStyle(.tertiary)
                    Spacer(minLength: 4)
                    Text(dimension.map { String(format: "%.0f", $0.score) } ?? "--")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .monospacedDigit()
                }
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(FixedVisualPalette.surfaceTrack)
                        Capsule()
                            .fill(visualTokens.data.series[colorIndex].color)
                            .frame(width: geometry.size.width * CGFloat((dimension?.score ?? 0) / 100))
                    }
                }
                .frame(height: 6)
            }
        }
        .frame(maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }

    private var title: String {
        switch kind {
        case .span: language.text("管理半径", "Span")
        case .leverage: language.text("劳动力杠杆", "Leverage")
        case .orchestration: language.text("编排能力", "Orchestration")
        case .autonomy: language.text("自主运行", "Autonomy")
        }
    }

    private var icon: String {
        switch kind {
        case .span: "person.3.fill"
        case .leverage: "clock.fill"
        case .orchestration: "square.stack.3d.up.fill"
        case .autonomy: "bolt.fill"
        }
    }

    private var colorIndex: Int {
        switch kind {
        case .span: 0
        case .leverage: 1
        case .orchestration, .autonomy: 2
        }
    }

    private var summary: String {
        guard let dimension else { return language.text("暂无", "No data") }
        switch kind {
        case .span:
            return language.text(String(format: "%.1f 等效 Agent", dimension.summaryValue), String(format: "%.1f effective agents", dimension.summaryValue))
        case .leverage:
            return language.text(String(format: "日均 %.1fh", dimension.summaryValue), String(format: "%.1fh per day", dimension.summaryValue))
        case .orchestration:
            return language.text(String(format: "委派 %.0f%%", dimension.summaryValue * 100), String(format: "%.0f%% delegated", dimension.summaryValue * 100))
        case .autonomy:
            return language.text(String(format: "自主 %.0f%%", dimension.summaryValue * 100), String(format: "%.0f%% autonomous", dimension.summaryValue * 100))
        }
    }
}

private struct LeadershipFactStrip: View {
    let report: LeadershipReport
    let preview: LeadershipPreviewFixture?
    let language: WidgetLanguage

    var body: some View {
        HStack(spacing: 8) {
            LeadershipFactTile(
                systemName: "sparkles",
                label: language.text("领导力分值", "Leadership score"),
                value: preview.map { String($0.score) } ?? report.score.map(String.init) ?? "--"
            )
            LeadershipFactTile(
                systemName: "person.3.fill",
                label: language.text("领导 Agent", "Agents"),
                value: preview.map { String($0.agentCount) } ?? report.agentCount.map(String.init) ?? "--"
            )
            LeadershipFactTile(
                systemName: "clock.fill",
                label: language.text("AI 工时", "AI hours"),
                value: leadershipHours(preview?.aiHours ?? report.aiHours)
            )
            LeadershipFactTile(
                systemName: "arrow.up.right.and.arrow.down.left",
                label: language.text("峰值并发", "Peak concurrency"),
                value: preview.map { "\($0.peakConcurrency)×" } ?? report.peakConcurrency.map { "\($0)×" } ?? "--"
            )
        }
    }
}

private struct LeadershipFactTile: View {
    @Environment(\.visualTokens) private var visualTokens
    let systemName: String
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: systemName)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(visualTokens.accent.primary.color)
                .frame(width: 22, height: 22)
                .background(Circle().fill(visualTokens.accent.primary.color.opacity(0.11)))
            VStack(alignment: .leading, spacing: 1) {
                Text(value)
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text(label)
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 9)
        .frame(maxWidth: .infinity, minHeight: 45)
        .cardBackground(cornerRadius: 9)
        .accessibilityElement(children: .combine)
    }
}

private struct LeadershipWorkforceChartCard: View {
    @Environment(\.visualTokens) private var visualTokens
    let report: LeadershipReport
    let language: WidgetLanguage
    @State private var hoveredIndex: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(language.text("AI 工时", "AI hours"), systemImage: "chart.xyaxis.line")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                LeadershipChartLegend(language: language)
            }

            GeometryReader { geometry in
                ZStack {
                    Canvas { context, size in
                        drawChart(context: &context, size: size)
                    }

                    if let hoveredIndex,
                       report.dailyPoints.indices.contains(hoveredIndex) {
                        LeadershipWorkforceTooltip(
                            point: report.dailyPoints[hoveredIndex],
                            language: language
                        )
                        .frame(width: 152)
                        .position(
                            x: tooltipX(index: hoveredIndex, width: geometry.size.width),
                            y: 42
                        )
                        .allowsHitTesting(false)
                    }
                }
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let location):
                        hoveredIndex = index(at: location.x, width: geometry.size.width)
                    case .ended:
                        hoveredIndex = nil
                    }
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .cardBackground(cornerRadius: 10)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(language.text("AI 工时、每日 Agent 与峰值并发组合趋势", "Combined AI hours, daily agents, and peak concurrency trend"))
        .accessibilityValue(accessibilityValues)
    }

    private func drawChart(context: inout GraphicsContext, size: CGSize) {
        let points = report.dailyPoints
        guard !points.isEmpty, size.width > 0, size.height > 0 else { return }

        let plotTop: CGFloat = 8
        let plotBottom = max(plotTop + 1, size.height - 20)
        let plotHeight = plotBottom - plotTop
        let step = size.width / CGFloat(points.count)
        let barWidth = max(2, min(14, step * 0.46))
        let maximumHours = max(points.map(\.aiHours).max() ?? 0, 0.1)
        let maximumAgents = max(Double(points.map(\.agentCount).max() ?? 0), 1)
        let maximumPeak = max(Double(points.map(\.peakConcurrency).max() ?? 0), 1)

        for fraction in [0.25, 0.5, 0.75] as [CGFloat] {
            var grid = Path()
            let y = plotTop + plotHeight * fraction
            grid.move(to: CGPoint(x: 0, y: y))
            grid.addLine(to: CGPoint(x: size.width, y: y))
            context.stroke(grid, with: .color(FixedVisualPalette.surfaceTrack.opacity(0.7)), lineWidth: 0.7)
        }

        for (index, point) in points.enumerated() {
            let x = step * (CGFloat(index) + 0.5)
            let barHeight = max(2, plotHeight * CGFloat(point.aiHours / maximumHours))
            let barRect = CGRect(
                x: x - barWidth / 2,
                y: plotBottom - barHeight,
                width: barWidth,
                height: barHeight
            )
            context.fill(
                Path(roundedRect: barRect, cornerRadius: 2),
                with: .color(visualTokens.accent.primary.color.opacity(hoveredIndex == index ? 0.55 : 0.28))
            )

            if shouldShowDateLabel(at: index, count: points.count) {
                context.draw(
                    Text(dayLabel(point.day))
                        .font(.system(size: 7, weight: .medium, design: .rounded))
                        .foregroundColor(.secondary),
                    at: CGPoint(x: x, y: size.height - 6),
                    anchor: .center
                )
            }
        }

        var agentPath = Path()
        var peakPath = Path()
        for (index, point) in points.enumerated() {
            let x = step * (CGFloat(index) + 0.5)
            let agentY = plotBottom - plotHeight * CGFloat(Double(point.agentCount) / maximumAgents)
            let peakY = plotBottom - plotHeight * CGFloat(Double(point.peakConcurrency) / maximumPeak)
            if index == 0 {
                agentPath.move(to: CGPoint(x: x, y: agentY))
                peakPath.move(to: CGPoint(x: x, y: peakY))
            } else {
                agentPath.addLine(to: CGPoint(x: x, y: agentY))
                peakPath.addLine(to: CGPoint(x: x, y: peakY))
            }
        }
        context.stroke(
            agentPath,
            with: .color(visualTokens.accent.primaryStrong.color),
            style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round)
        )
        context.stroke(
            peakPath,
            with: .color(visualTokens.data.series[1].color),
            style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round, dash: [4, 3])
        )

        if let hoveredIndex, points.indices.contains(hoveredIndex) {
            let point = points[hoveredIndex]
            let x = step * (CGFloat(hoveredIndex) + 0.5)
            var guide = Path()
            guide.move(to: CGPoint(x: x, y: plotTop))
            guide.addLine(to: CGPoint(x: x, y: plotBottom))
            context.stroke(guide, with: .color(visualTokens.accent.primary.color.opacity(0.34)), lineWidth: 0.8)

            drawPoint(
                context: &context,
                center: CGPoint(
                    x: x,
                    y: plotBottom - plotHeight * CGFloat(Double(point.agentCount) / maximumAgents)
                ),
                color: visualTokens.accent.primaryStrong.color
            )
            drawPoint(
                context: &context,
                center: CGPoint(
                    x: x,
                    y: plotBottom - plotHeight * CGFloat(Double(point.peakConcurrency) / maximumPeak)
                ),
                color: visualTokens.data.series[1].color
            )
        }
    }

    private func drawPoint(context: inout GraphicsContext, center: CGPoint, color: Color) {
        let halo = CGRect(x: center.x - 5, y: center.y - 5, width: 10, height: 10)
        let point = CGRect(x: center.x - 2.5, y: center.y - 2.5, width: 5, height: 5)
        context.fill(Path(ellipseIn: halo), with: .color(color.opacity(0.16)))
        context.fill(Path(ellipseIn: point), with: .color(color))
    }

    private func index(at x: CGFloat, width: CGFloat) -> Int? {
        guard !report.dailyPoints.isEmpty, width > 0 else { return nil }
        let step = width / CGFloat(report.dailyPoints.count)
        return min(max(Int(x / max(step, 1)), 0), report.dailyPoints.count - 1)
    }

    private func tooltipX(index: Int, width: CGFloat) -> CGFloat {
        guard !report.dailyPoints.isEmpty else { return width / 2 }
        let step = width / CGFloat(report.dailyPoints.count)
        let raw = step * (CGFloat(index) + 0.5)
        return min(max(raw, 76), max(76, width - 76))
    }

    private func shouldShowDateLabel(at index: Int, count: Int) -> Bool {
        count <= 7 || index == 0 || index == count / 2 || index == count - 1
    }

    private var accessibilityValues: String {
        report.dailyPoints.map { point in
            language.text(
                "\(dayLabel(point.day))，AI 工时 \(leadershipHours(point.aiHours))，\(point.agentCount) 个 Agent，峰值 \(point.peakConcurrency)",
                "\(dayLabel(point.day)), \(leadershipHours(point.aiHours)) AI hours, \(point.agentCount) agents, peak \(point.peakConcurrency)"
            )
        }.joined(separator: language.text("；", "; "))
    }

    private func dayLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "M/d"
        return formatter.string(from: date)
    }
}

private struct LeadershipChartLegend: View {
    @Environment(\.visualTokens) private var visualTokens
    let language: WidgetLanguage

    var body: some View {
        HStack(spacing: 8) {
            legendItem(language.text("工时", "Hours"), color: visualTokens.accent.primary.color, style: .bar)
            legendItem("Agent", color: visualTokens.accent.primaryStrong.color, style: .line)
            legendItem(language.text("峰值", "Peak"), color: visualTokens.data.series[1].color, style: .dashed)
        }
        .help(language.text("三条序列使用独立量程；悬停查看原始值", "Each series uses its own scale; hover for exact values"))
    }

    private func legendItem(_ title: String, color: Color, style: LeadershipLegendStyle) -> some View {
        HStack(spacing: 3) {
            LeadershipLegendMark(color: color, style: style)
                .frame(width: 13, height: 7)
            Text(title)
                .font(.system(size: 7.5, weight: .medium))
                .foregroundStyle(.tertiary)
        }
    }
}

private enum LeadershipLegendStyle: Equatable {
    case bar
    case line
    case dashed
}

private struct LeadershipLegendMark: View {
    let color: Color
    let style: LeadershipLegendStyle

    var body: some View {
        Canvas { context, size in
            switch style {
            case .bar:
                let rect = CGRect(x: 3, y: 0, width: 7, height: size.height)
                context.fill(Path(roundedRect: rect, cornerRadius: 1.5), with: .color(color.opacity(0.42)))
            case .line, .dashed:
                var path = Path()
                path.move(to: CGPoint(x: 0, y: size.height / 2))
                path.addLine(to: CGPoint(x: size.width, y: size.height / 2))
                context.stroke(
                    path,
                    with: .color(color),
                    style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: style == .dashed ? [3, 2] : [])
                )
            }
        }
        .accessibilityHidden(true)
    }
}

private struct LeadershipWorkforceTooltip: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.visualTokens) private var visualTokens
    let point: LeadershipDayPoint
    let language: WidgetLanguage

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(dayLabel)
                .font(.system(size: 9, weight: .bold, design: .rounded))
            tooltipRow(color: visualTokens.accent.primary.color, label: language.text("AI 工时", "AI hours"), value: leadershipHours(point.aiHours))
            tooltipRow(color: visualTokens.accent.primaryStrong.color, label: "Agent", value: "\(point.agentCount)")
            tooltipRow(color: visualTokens.data.series[1].color, label: language.text("峰值并发", "Peak"), value: "\(point.peakConcurrency)×")
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(FixedVisualPalette.controlFill(colorScheme))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(FixedVisualPalette.controlStroke(colorScheme), lineWidth: 0.8)
                )
                .shadow(color: Color.black.opacity(0.12), radius: 6, y: 3)
        )
    }

    private func tooltipRow(color: Color, label: String, value: String) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 5, height: 5)
            Text(label)
                .font(.system(size: 8, weight: .medium))
                .foregroundStyle(.secondary)
            Spacer(minLength: 6)
            Text(value)
                .font(.system(size: 8.5, weight: .bold, design: .rounded))
                .monospacedDigit()
        }
    }

    private var dayLabel: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "M/d"
        return formatter.string(from: point.day)
    }
}

private struct LeadershipProjectCard: View {
    @Environment(\.visualTokens) private var visualTokens
    let report: LeadershipReport
    let language: WidgetLanguage

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Label(language.text("项目贡献", "Project contribution"), systemImage: "folder.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(report.projectCount)")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(.tertiary)
            }

            if !report.projects.isEmpty {
                HStack(spacing: 8) {
                    Text(language.text("项目", "Project"))
                    Spacer(minLength: 4)
                    Text("Agent").frame(width: 48, alignment: .trailing)
                    Text(language.text("AI 工时", "AI hours")).frame(width: 58, alignment: .trailing)
                    Text(language.text("自主工时", "Autonomous")).frame(width: 58, alignment: .trailing)
                }
                .font(.system(size: 7.5, weight: .medium))
                .foregroundStyle(.tertiary)
            }

            if report.projects.isEmpty {
                Spacer()
                Text(language.text("暂无可信项目记录", "No trusted project history"))
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                ForEach(Array(report.projects.prefix(5).enumerated()), id: \.element.id) { index, project in
                    HStack(spacing: 7) {
                        Text("\(index + 1)")
                            .font(.system(size: 8, weight: .bold, design: .rounded))
                            .foregroundStyle(index == 0 ? visualTokens.accent.primary.color : Color.secondary)
                            .frame(width: 14)
                        Text(project.projectName)
                            .font(.system(size: 9, weight: .semibold))
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Text("\(project.agentCount)")
                            .font(.system(size: 8, weight: .medium, design: .rounded))
                            .foregroundStyle(.tertiary)
                            .frame(width: 48, alignment: .trailing)
                        Text(leadershipHours(project.aiHours))
                            .font(.system(size: 9, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .frame(width: 58, alignment: .trailing)
                        Text(leadershipHours(project.autonomousHours))
                            .font(.system(size: 8, weight: .medium, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 58, alignment: .trailing)
                    }
                    .frame(maxHeight: .infinity)
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .cardBackground(cornerRadius: 10)
    }
}

private struct LeadershipEmptyState: View {
    let language: WidgetLanguage

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(.tertiary)
            Text(language.text("正在建立 AI 领导力记录", "Building AI leadership history"))
                .font(.system(size: 12, weight: .semibold))
            Text(language.text("仅使用本机可验证的结构化事件，缺失数据不会记为 0。", "Only verifiable local events are used; missing data is never treated as zero."))
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

private func leadershipHours(_ value: Double?) -> String {
    guard let value else { return "--" }
    if value >= 100 { return String(format: "%.0fh", value) }
    if value >= 10 { return String(format: "%.1fh", value) }
    return String(format: "%.1fh", value)
}
