import Foundation
import SwiftUI
import AppKit

struct UsageWidgetView: View {
    @ObservedObject var store: UsageStore
    @Environment(\.colorScheme) private var colorScheme
    @State private var language = WidgetLanguage.storedOrAutomatic()
    @State private var themeMode = WidgetThemeMode.storedOrAutomatic()
    @State private var displayCurrency = loadDisplayCurrency()
    @State private var selectedModelUsagePeriod: ModelUsagePeriod = .today
    @State private var selectedSourceUsagePeriod: ModelUsagePeriod = .today
    @State private var trendSelectedModels: Set<String>? = nil
    @State private var trendFilterOpen = false

    static let widgetWidth: CGFloat = 820
    static let widgetDefaultHeight: CGFloat = 720
    static let widgetMinHeight: CGFloat = 620
    static let widgetMaxHeight: CGFloat = 920

    private var snapshot: UsageSnapshot { store.snapshot }
    private var primary: RateWindow? { snapshot.primary }
    private var effectiveColorScheme: ColorScheme {
        themeMode.preferredColorScheme ?? colorScheme
    }

    var body: some View {
        Group {
            if #available(macOS 26.0, *) {
                GlassEffectContainer(spacing: 10) {
                    widgetContent
                        .glassEffect(
                            .regular.tint(WidgetPalette.windowTint(effectiveColorScheme)),
                            in: .rect(cornerRadius: 24, style: .continuous)
                        )
                }
            } else {
                widgetContent
            }
        }
        .environment(\.colorScheme, effectiveColorScheme)
        .preferredColorScheme(themeMode.preferredColorScheme)
        .onAppear {
            themeMode.applyAppearance()
            reloadPresentationPreferences()
        }
        .onReceive(NotificationCenter.default.publisher(for: .modelMeterPreferencesDidChange)) { _ in
            reloadPresentationPreferences()
        }
    }

    private var widgetContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if let discoveryNotice = store.discoveryNotice {
                discoveryNoticeBar(discoveryNotice)
            }
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 12) {
                    if shouldShowEnvironmentChecklist {
                        environmentChecklistSection
                    }
                    usageOverviewSection
                    sourceComparisonSection
                    modelUsageCardSection
                    usageTrendSection
                }
                .padding(.bottom, 2)
            }
            footer
        }
        .padding(.horizontal, 16)
        .padding(.top, 18)
        .padding(.bottom, 14)
        .frame(width: Self.widgetWidth, alignment: .topLeading)
        .frame(minHeight: Self.widgetMinHeight, maxHeight: .infinity, alignment: .topLeading)
    }

    private func reloadPresentationPreferences() {
        language = WidgetLanguage.storedOrAutomatic()
        themeMode = WidgetThemeMode.storedOrAutomatic()
        displayCurrency = loadDisplayCurrency()
    }

    private var header: some View {
        HStack(spacing: 10) {
            HStack(spacing: 9) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 34, height: 34)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .accessibilityHidden(true)
                Text("AgentDesk")
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
                    .fixedSize()
            }
            Spacer()
            DiscoveredProviderPicker(
                providers: store.discoveredProviders,
                selected: store.selectedDiscoveredProvider,
                language: language
            ) { selectedProvider in
                store.selectDiscoveredProvider(selectedProvider)
            } onRediscover: {
                store.rediscoverProvidersManually()
            }
            ThemeSwitch(themeMode: themeMode, language: language) { selectedMode in
                themeMode = selectedMode
                selectedMode.persist()
                selectedMode.applyAppearance()
                postPreferencesDidChange()
            }
            LanguageSwitch(language: language) { selectedLanguage in
                language = selectedLanguage
                selectedLanguage.persist()
                AppDelegate.shared?.refreshStatusItemLocalization()
                postPreferencesDidChange()
            }
            planPill
            iconButton(systemName: "xmark") {
                NSApp.terminate(nil)
            }
            .help(language.text("退出 AgentDesk", "Quit AgentDesk"))
            iconButton(systemName: store.isRefreshing ? "hourglass" : "arrow.clockwise") {
                store.refresh()
            }
            .help(language.text("刷新数据", "Refresh data"))
            iconButton(systemName: "rectangle.on.rectangle") {
                AppDelegate.shared?.toggleWindowLayer()
            }
            .help(language.text("切换前台/桌面层 (⌘U)", "Toggle front/desktop layer (⌘U)"))
        }
    }

    private var environmentChecklistSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(
                title: language.text("环境检查", "Environment"),
                detail: language.text("首次使用", "First run")
            )
            ForEach(environmentDiagnostics) { item in
                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: item.systemName)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(item.tint)
                        .frame(width: 18, height: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title)
                            .font(.system(size: 11, weight: .semibold))
                        Text(item.detail)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                }
            }
        }
        .padding(12)
        .sectionBackground()
    }

    private func discoveryNoticeBar(_ text: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: "info.circle.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(WidgetPalette.brandPrimary)
            Text(text)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(WidgetPalette.surfaceTrack)
        )
    }

    private var planPill: some View {
        statusPill(planLabel)
    }

    private func statusPill(_ label: String) -> some View {
        Text(label)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                Capsule(style: .continuous)
                    .fill(WidgetPalette.controlFill(effectiveColorScheme))
                    .overlay(
                        Capsule(style: .continuous)
                            .strokeBorder(WidgetPalette.controlStroke(effectiveColorScheme), lineWidth: 0.8)
                    )
            )
    }

    private func iconButton(systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .iconButtonStyle()
        .foregroundStyle(.secondary)
    }

    private var usageOverviewSection: some View {
        let hasQuotaData = snapshot.primary != nil || snapshot.secondary != nil

        return HStack(alignment: .center, spacing: 26) {
            if hasQuotaData {
                VStack(spacing: 8) {
                    DualQuotaRing(
                        primary: snapshot.primary,
                        secondary: snapshot.secondary,
                        language: language
                    )
                    .frame(width: 145, height: 145)

                    QuotaResetSummary(
                        primary: snapshot.primary,
                        secondary: snapshot.secondary,
                        language: language
                    )
                    .frame(width: 154)
                }
            }

            VStack(alignment: .leading, spacing: 13) {
                HStack(spacing: 10) {
                    DetailedTokenMetricCard(
                        title: language.text("今日", "Today"),
                        systemName: "sun.max.fill",
                        usage: snapshot.local?.detailedUsage?.today,
                        fallbackTokens: snapshot.local?.todayTokens,
                        language: language,
                        currency: displayCurrency
                    )
                    DetailedTokenMetricCard(
                        title: language.text("近 7 天", "Last 7 days"),
                        systemName: "calendar",
                        usage: snapshot.local?.detailedUsage?.sevenDay,
                        fallbackTokens: snapshot.local?.sevenDayTokens,
                        language: language,
                        currency: displayCurrency
                    )
                    DetailedTokenMetricCard(
                        title: language.text("30天", "30 days"),
                        systemName: "calendar.badge.clock",
                        usage: snapshot.local?.detailedUsage?.thirtyDay,
                        fallbackTokens: snapshot.local?.thirtyDayTokens,
                        language: language,
                        currency: displayCurrency
                    )
                    DetailedTokenMetricCard(
                        title: language.text("累计", "Lifetime"),
                        systemName: "sum",
                        usage: snapshot.local?.detailedUsage?.lifetime,
                        fallbackTokens: snapshot.local?.lifetimeTokens,
                        language: language,
                        currency: displayCurrency
                    )
                }

                WoolProgressCard(usage: snapshot.local?.detailedUsage?.month, language: language, currency: displayCurrency)
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 16)
        .sectionBackground()
    }



    private var modelUsageCardSection: some View {
        return AnyView(
            modelUsageSection
                .padding(12)
                .sectionBackground()
        )
    }

    private var sourceComparisonSection: some View {
        guard snapshot.provider == .all, !store.sourceUsageSummaries.isEmpty else {
            return AnyView(EmptyView())
        }

        let displaySummaries = store.sourceUsageSummaries
            .map { summary in (summary: summary, usage: summary.usage(for: selectedSourceUsagePeriod)) }
            .sorted { $0.usage.tokens > $1.usage.tokens }
        let totalTokens = displaySummaries.reduce(Int64(0)) { $0 + $1.usage.tokens }
        return AnyView(
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(language.text("来源占比", "Source split"))
                        .font(.system(size: 12, weight: .semibold))
                    Spacer()
                    HStack(spacing: 1) {
                        ForEach(sourceUsagePeriods, id: \.self) { period in
                            Button {
                                selectedSourceUsagePeriod = period
                            } label: {
                                Text(language.text(period.labelZh, period.labelEn))
                                    .font(.system(size: 9, weight: selectedSourceUsagePeriod == period ? .semibold : .regular))
                                    .foregroundStyle(selectedSourceUsagePeriod == period ? .primary : .secondary)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 3)
                                    .background(
                                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                                            .fill(selectedSourceUsagePeriod == period ? WidgetPalette.surfaceTrack : Color.clear)
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                HStack(spacing: 10) {
                    ForEach(displaySummaries, id: \.summary.id) { item in
                        let summary = item.summary
                        let usage = item.usage
                        let share = totalTokens > 0 ? Double(usage.tokens) / Double(totalTokens) : 0
                        VStack(alignment: .leading, spacing: 7) {
                            HStack {
                                Text(localizedSourceSummaryName(summary))
                                    .font(.system(size: 11, weight: .semibold))
                                    .lineLimit(1)
                                Spacer(minLength: 6)
                                VStack(alignment: .trailing, spacing: 2) {
                                    Text(formatTokens(usage.tokens))
                                        .font(.system(size: 11, weight: .bold, design: .rounded))
                                        .monospacedDigit()
                                        .foregroundStyle(sourceColor(summary.id))
                                    Text(totalTokens > 0 ? formatUsagePercent(share * 100) : "--")
                                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                                        .monospacedDigit()
                                        .foregroundStyle(.secondary)
                                }
                            }
                            GeometryReader { geo in
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .fill(WidgetPalette.surfaceTrack)
                                    .overlay(alignment: .leading) {
                                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                                            .fill(sourceColor(summary.id))
                                            .frame(width: usage.tokens > 0 ? max(4, geo.size.width * CGFloat(share)) : 0)
                                    }
                            }
                            .frame(height: 7)
                            HStack(spacing: 8) {
                                Text(formatUSD(usage.estimatedCost, currency: displayCurrency))
                                Text(usage.cacheHitRate.map { "\(Int(($0 * 100).rounded()))%" } ?? "--")
                            }
                            .font(.system(size: 9, weight: .medium, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(WidgetPalette.surfaceTrack.opacity(0.72))
                        )
                    }
                }
            }
            .padding(12)
            .sectionBackground()
        )
    }

    private var sourceUsagePeriods: [ModelUsagePeriod] {
        [.twentyFourHour, .today, .sevenDay, .thirtyDay]
    }

    private func sourceColor(_ id: String) -> Color {
        switch id {
        case UsageProvider.codex.rawValue:
            return WidgetPalette.brandPrimary
        case UsageProvider.mimocode.rawValue:
            return WidgetPalette.brandSecondary
        default:
            return .secondary
        }
    }

    private func localizedSourceSummaryName(_ summary: SourceUsageSummary) -> String {
        if let provider = UsageProvider(rawValue: summary.id) {
            return provider.shortLabel(language: language)
        }
        return summary.shortName
    }

    private var usageTrendSection: some View {
        guard let modelBuckets = snapshot.local?.sevenDayModelBuckets, !modelBuckets.isEmpty else {
            return AnyView(EmptyView())
        }

        let allModelNames = Array(modelBuckets.keys).sorted()
        let filteredModelBuckets: [String: [DailyTokenBucket]]
        if let selected = trendSelectedModels, !selected.isEmpty {
            filteredModelBuckets = modelBuckets.filter { selected.contains($0.key) }
        } else {
            filteredModelBuckets = modelBuckets
        }
        let modelColors = buildModelColorsForModels(Array(filteredModelBuckets.keys))

        return AnyView(
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Text(language.text("近 7 天用量趋势", "7-day usage trend"))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        trendFilterOpen.toggle()
                    } label: {
                        HStack(spacing: 3) {
                            Text(trendSelectedModels == nil ? language.text("全部模型", "All models") : language.text("已筛选", "Filtered"))
                                .font(.system(size: 9, weight: .medium))
                            Image(systemName: "chevron.down")
                                .font(.system(size: 7, weight: .semibold))
                        }
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(WidgetPalette.surfaceTrack)
                        )
                    }
                    .buttonStyle(.plain)
                    .popover(isPresented: $trendFilterOpen) {
                        VStack(alignment: .leading, spacing: 0) {
                            Button {
                                trendSelectedModels = nil
                                trendFilterOpen = false
                            } label: {
                                HStack {
                                    Text(language.text("全部模型", "All models"))
                                    Spacer()
                                    if trendSelectedModels == nil { Image(systemName: "checkmark").frame(width: 12) }
                                }
                                .font(.system(size: 11))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                            }
                            .buttonStyle(.plain)

                            Divider().padding(.vertical, 2)

                            ForEach(allModelNames, id: \.self) { model in
                                Button {
                                    if trendSelectedModels == nil {
                                        trendSelectedModels = Set(allModelNames.filter { $0 != model })
                                    } else if trendSelectedModels!.contains(model) {
                                        trendSelectedModels!.remove(model)
                                        if trendSelectedModels!.isEmpty { trendSelectedModels = nil }
                                    } else {
                                        trendSelectedModels!.insert(model)
                                        if trendSelectedModels!.count == allModelNames.count { trendSelectedModels = nil }
                                    }
                                } label: {
                                    HStack {
                                        Text(model)
                                        Spacer()
                                        if let selected = trendSelectedModels {
                                            if selected.contains(model) { Image(systemName: "checkmark").frame(width: 12) }
                                        } else {
                                            Image(systemName: "checkmark").frame(width: 12)
                                        }
                                    }
                                    .font(.system(size: 11))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 5)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 4)
                        .frame(minWidth: 140)
                    }
                    .fixedSize()
                }

                ModelDailyTokenChart(
                    modelBuckets: filteredModelBuckets,
                    modelColors: modelColors,
                    language: language
                )

                // 图例（自然换行，展示所有模型）
                FlowLayout(spacing: 10) {
                    ForEach(Array(modelColors.keys.sorted()), id: \.self) { model in
                        if let color = modelColors[model] {
                            HStack(spacing: 4) {
                                Circle()
                                    .fill(color)
                                    .frame(width: 8, height: 8)
                                Text(model)
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                }
            }
            .padding(12)
            .sectionBackground()
        )
    }

    private func buildModelColors(from models: [ModelUsageItem]) -> [String: Color] {
        let colors: [Color] = [.blue, .orange, .green, .purple, .red, .cyan, .yellow, .pink]
        var result: [String: Color] = [:]
        for (index, model) in models.prefix(8).enumerated() {
            result[model.model] = colors[index % colors.count]
        }
        return result
    }

    private func buildModelColorsForModels(_ models: [String]) -> [String: Color] {
        let colors: [Color] = [.blue, .orange, .green, .purple, .red, .cyan, .yellow, .pink]
        var result: [String: Color] = [:]
        for (index, model) in models.enumerated() {
            result[model] = colors[index % colors.count]
        }
        return result
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Spacer()
            Text("\(language.text("刷新", "Refreshed")) \(timeOnly(snapshot.refreshedAt, language: language))")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            Text("⌘U")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
    }

    private var planLabel: String {
        snapshot.account?.planType?.uppercased() ?? snapshot.provider.displayName(language: language).uppercased()
    }



    private var currentModelUsage: [ModelUsageItem] {
        switch selectedModelUsagePeriod {
        case .today:
            return snapshot.local?.todayModelUsage ?? []
        case .twentyFourHour:
            return snapshot.local?.twentyFourHourModelUsage ?? []
        case .sevenDay:
            return snapshot.local?.sevenDayModelUsage ?? []
        case .thirtyDay:
            return snapshot.local?.thirtyDayModelUsage ?? []
        case .lifetime:
            return snapshot.local?.lifetimeModelUsage ?? []
        }
    }

    @State private var selectedModelDetail: ModelUsageItem?
    @State private var modelSearchText = ""

    private var filteredModelUsage: [ModelUsageItem] {
        guard !modelSearchText.isEmpty else { return currentModelUsage }
        let query = modelSearchText.lowercased()
        return currentModelUsage.filter { item in
            item.model.lowercased().contains(query) ||
            item.provider.lowercased().contains(query)
        }
    }

    private var modelUsageEmptyStateText: String {
        if !modelSearchText.isEmpty {
            return language.text("无匹配结果", "No matches")
        }

        switch selectedModelUsagePeriod {
        case .today:
            return language.text("今天暂时还没有模型使用数据", "No model usage yet today")
        case .twentyFourHour:
            return language.text("最近 24 小时暂无模型使用数据", "No model usage in the last 24 hours")
        case .sevenDay:
            return language.text("最近 7 天暂无模型使用数据", "No model usage in the last 7 days")
        case .thirtyDay:
            return language.text("最近 30 天暂无模型使用数据", "No model usage in the last 30 days")
        case .lifetime:
            return language.text("暂无模型使用数据", "No model usage data")
        }
    }

    private var modelUsageSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 8) {
                // 标题
                Text(language.text("模型用量", "Model usage"))
                    .font(.system(size: 12, weight: .semibold))

                // 搜索框（紧凑型）
                HStack(spacing: 3) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 8))
                        .foregroundStyle(.tertiary)
                    TextField(language.text("搜索", "Search"), text: $modelSearchText)
                        .font(.system(size: 9))
                        .textFieldStyle(.plain)
                        .frame(width: 60)
                    if !modelSearchText.isEmpty {
                        Button {
                            modelSearchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 8))
                                .foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 5)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(WidgetPalette.surfaceTrack)
                )

                // 模型数量
                Text(language.text("\(filteredModelUsage.count) 个模型", "\(filteredModelUsage.count) models"))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)

                Spacer()

                // Tab 切换
                HStack(spacing: 1) {
                    ForEach(ModelUsagePeriod.allCases, id: \.self) { period in
                        Button {
                            selectedModelUsagePeriod = period
                        } label: {
                            Text(language.text(period.labelZh, period.labelEn))
                                .font(.system(size: 9, weight: selectedModelUsagePeriod == period ? .semibold : .regular))
                                .foregroundStyle(selectedModelUsagePeriod == period ? .primary : .secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(
                                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                                        .fill(selectedModelUsagePeriod == period ? WidgetPalette.surfaceTrack : Color.clear)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            VStack(spacing: 0) {
                // 表头
                HStack(spacing: 8) {
                    Text(language.text("模型", "Model"))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 65, alignment: .leading)

                    Spacer(minLength: 4)

                    Text(language.text("速度", "TPS"))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .frame(minWidth: 36, alignment: .trailing)

                    Text(language.text("未缓存", "Unc"))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(uncachedInputColor)
                        .frame(minWidth: 42, alignment: .trailing)

                    Text(language.text("缓存", "Cache"))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(cachedInputColor)
                        .frame(minWidth: 42, alignment: .trailing)

                    Text(language.text("输出", "Out"))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(WidgetPalette.statusSuccess)
                        .frame(minWidth: 42, alignment: .trailing)

                    Text(language.text("总消耗", "Total"))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.primary)
                        .frame(minWidth: 46, alignment: .trailing)

                    Text(language.text("缓存率", "Hit"))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 36, alignment: .trailing)

                    Text(language.text("费用", "Cost"))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 46, alignment: .trailing)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)

                Divider()

                // 数据行
                if filteredModelUsage.isEmpty {
                    Text(modelUsageEmptyStateText)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 40)
                } else {
                    let maxTokens = filteredModelUsage.map(\.tokens).max() ?? 1
                    ForEach(filteredModelUsage) { item in
                        ModelUsageRow(item: item, language: language, maxTokens: maxTokens) { selectedItem in
                            selectedModelDetail = selectedItem
                        }
                        if item.id != filteredModelUsage.last?.id {
                            Divider()
                        }
                    }
                }
            }
            .cardBackground(cornerRadius: 10)
        }
        .sheet(item: $selectedModelDetail) { item in
            ModelDetailView(item: item, language: language)
        }
    }

    private var shouldShowEnvironmentChecklist: Bool {
        if snapshot.messages.contains("正在读取 \(snapshot.provider.displayName) 数据") { return false }
        if snapshot.hasPersistableContent { return false }
        if snapshot.provider == .mimocode {
            return snapshot.local == nil
        }
        return snapshot.primary == nil
            && snapshot.account == nil
            && snapshot.local == nil
    }

    private var environmentDiagnostics: [DiagnosticItem] {
        var items: [DiagnosticItem] = []
        let messages = snapshot.messages.joined(separator: "\n")

        if snapshot.provider == .codex && (snapshot.primary == nil || snapshot.account == nil) {
            if messages.contains("未找到 codex") {
                items.append(DiagnosticItem(
                    id: "codex-missing",
                    title: language.text("未找到 Codex", "Codex not found"),
                    detail: language.text("请先安装 Codex App，或确认 codex CLI 位于 /Applications/Codex.app、/opt/homebrew/bin 或 /usr/local/bin。", "Install Codex App first, or make sure the codex CLI is in /Applications/Codex.app, /opt/homebrew/bin, or /usr/local/bin."),
                    systemName: "magnifyingglass",
                    tint: WidgetPalette.statusWarning
                ))
            } else if messages.contains("app-server") {
                items.append(DiagnosticItem(
                    id: "app-server",
                    title: language.text("Codex 账户接口暂不可用", "Codex account API unavailable"),
                    detail: language.text("确认 Codex 已登录后点击刷新；本机 token 统计仍可继续显示。", "Make sure Codex is signed in, then refresh. Local token stats can still be shown."),
                    systemName: "exclamationmark.triangle.fill",
                    tint: WidgetPalette.statusWarning
                ))
            } else {
                items.append(DiagnosticItem(
                    id: "quota-unavailable",
                    title: language.text("账户额度读取中", "Reading account quota"),
                    detail: language.text("如果长时间无数据，请确认 Codex 已安装并完成登录。", "If data does not appear, make sure Codex is installed and signed in."),
                    systemName: "person.crop.circle.badge.questionmark",
                    tint: WidgetPalette.statusInfo
                ))
            }
        }

        if snapshot.local == nil {
            if messages.contains("mimocode.db") {
                items.append(DiagnosticItem(
                    id: "mimo-db",
                    title: language.text("未找到 MimoCode 数据库", "MimoCode database not found"),
                    detail: language.text("打开 MimoCode 并至少完成一次会话后，再回到小组件点击刷新。", "Open MimoCode and complete at least one session, then refresh this widget."),
                    systemName: "externaldrive.badge.questionmark",
                    tint: WidgetPalette.statusWarning
                ))
            } else if messages.contains("MimoCode token") {
                items.append(DiagnosticItem(
                    id: "mimo-tokens",
                    title: language.text("未找到 MimoCode token 事件", "MimoCode token events not found"),
                    detail: language.text("当前 MimoCode 数据库中还没有可统计的 token 记录。", "The current MimoCode database does not contain token records yet."),
                    systemName: "chart.bar.doc.horizontal",
                    tint: WidgetPalette.statusInfo
                ))
            } else if messages.contains("state_5.sqlite") {
                items.append(DiagnosticItem(
                    id: "sqlite-db",
                    title: language.text("未找到本机 Codex 统计库", "Local Codex database not found"),
                    detail: language.text("打开 Codex 并至少完成一次会话后，再回到小组件点击刷新。", "Open Codex and complete at least one session, then refresh this widget."),
                    systemName: "externaldrive.badge.questionmark",
                    tint: WidgetPalette.statusWarning
                ))
            } else if messages.contains("sqlite3") {
                items.append(DiagnosticItem(
                    id: "sqlite-cli",
                    title: language.text("未找到 sqlite3", "sqlite3 not found"),
                    detail: language.text("请安装 macOS Command Line Tools，或通过 Homebrew 安装 sqlite。", "Install macOS Command Line Tools, or install sqlite with Homebrew."),
                    systemName: "terminal",
                    tint: WidgetPalette.statusWarning
                ))
            } else {
                items.append(DiagnosticItem(
                    id: "local-usage",
                    title: language.text("本机统计暂不可用", "Local stats unavailable"),
                    detail: language.text("本机 token 统计依赖 ~/.codex 的本地状态文件。", "Local token stats depend on Codex state files under ~/.codex."),
                    systemName: "chart.bar.doc.horizontal",
                    tint: WidgetPalette.statusInfo
                ))
            }
        }

        if items.isEmpty {
            items = snapshot.messages.prefix(3).enumerated().map { index, message in
                DiagnosticItem(
                    id: "message-\(index)",
                    title: language.text("运行提示", "Runtime note"),
                    detail: localizedReaderMessage(message, language: language),
                    systemName: "info.circle.fill",
                    tint: WidgetPalette.statusInfo
                )
            }
        }

        return items
    }
}




struct ProjectActivityRow: View {
    let stat: ProjectActivityStat
    let maxSessions: Int
    let language: WidgetLanguage

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(stat.name)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text("\(stat.sessionCount)\(language.text(" 会话", " sessions"))")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                    if stat.totalTokens > 0 {
                        Text(formatTokens(stat.totalTokens))
                            .font(.system(size: 9, weight: .medium, design: .rounded))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            Spacer(minLength: 8)
            GeometryReader { geo in
                let barWidth = maxSessions > 0 ? CGFloat(stat.sessionCount) / CGFloat(maxSessions) : 0
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(WidgetPalette.controlFill(.light))
                    .frame(width: geo.size.width)
                    .overlay(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(WidgetPalette.brandPrimary)
                            .frame(width: geo.size.width * barWidth)
                    }
            }
            .frame(width: 80, height: 6)
        }
    }
}
