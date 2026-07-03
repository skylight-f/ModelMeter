import Foundation
import SwiftUI
import AppKit

extension Notification.Name {
    static let modelMeterPreferencesDidChange = Notification.Name("AgentDesk.preferencesDidChange")
}

private func postPreferencesDidChange() {
    NotificationCenter.default.post(name: .modelMeterPreferencesDidChange, object: nil)
}

private struct PricingTableMetrics {
    static let modelWidth: CGFloat = 192
    static let amountWidth: CGFloat = 148
    static let currencyWidth: CGFloat = 40
    static let actionWidth: CGFloat = 28
    static let rowHeight: CGFloat = 34
    static let totalWidth: CGFloat = modelWidth + amountWidth * 3 + currencyWidth + actionWidth
}

enum WidgetLanguage: String, CaseIterable, Equatable {
    case zh
    case en

    static let storageKey = "AgentDesk.interfaceLanguage"

    static var automatic: WidgetLanguage {
        let identifier = TimeZone.current.identifier
        let chineseTimeZones: Set<String> = [
            "Asia/Shanghai",
            "Asia/Chongqing",
            "Asia/Harbin",
            "Asia/Urumqi",
            "Asia/Hong_Kong",
            "Asia/Macau",
            "Asia/Taipei"
        ]
        return chineseTimeZones.contains(identifier) ? .zh : .en
    }

    var isChinese: Bool { self == .zh }

    static func storedOrAutomatic() -> WidgetLanguage {
        guard let rawValue = AgentDeskDatabase.shared.string(forKey: storageKey),
              let language = WidgetLanguage(rawValue: rawValue)
        else { return .automatic }
        return language
    }

    func persist() {
        AgentDeskDatabase.shared.set(rawValue, forKey: Self.storageKey)
    }

    func text(_ zh: String, _ en: String) -> String {
        isChinese ? zh : en
    }
}

enum WidgetThemeMode: String, CaseIterable, Equatable {
    case system
    case light
    case dark

    static let storageKey = "AgentDesk.interfaceThemeMode"

    static func storedOrAutomatic() -> WidgetThemeMode {
        guard let rawValue = AgentDeskDatabase.shared.string(forKey: storageKey),
              let mode = WidgetThemeMode(rawValue: rawValue)
        else { return .system }
        return mode
    }

    var preferredColorScheme: ColorScheme? {
        switch self {
        case .system:
            return nil
        case .light:
            return .light
        case .dark:
            return .dark
        }
    }

    func persist() {
        AgentDeskDatabase.shared.set(rawValue, forKey: Self.storageKey)
    }

    func applyAppearance() {
        switch self {
        case .system:
            NSApp.appearance = nil
        case .light:
            NSApp.appearance = NSAppearance(named: .aqua)
        case .dark:
            NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

struct UsageWidgetView: View {
    @ObservedObject var store: UsageStore
    @Environment(\.colorScheme) private var colorScheme
    @State private var language = WidgetLanguage.storedOrAutomatic()
    @State private var themeMode = WidgetThemeMode.storedOrAutomatic()
    @State private var displayCurrency = loadDisplayCurrency()
    @State private var selectedModelUsagePeriod: ModelUsagePeriod = .today
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
            iconButton(systemName: store.isRefreshing ? "hourglass" : "arrow.clockwise") {
                store.refresh()
            }
            iconButton(systemName: "text.document") {
                AppDelegate.shared?.openPromptStudio()
            }
            .help(language.text("打开 Prompt Studio", "Open Prompt Studio"))
            iconButton(systemName: "rectangle.on.rectangle") {
                AppDelegate.shared?.toggleWindowLayer()
            }
            .help(language.text("切换前台/桌面层 (⌘U)", "Toggle front/desktop layer (⌘U)"))
            iconButton(systemName: "xmark") {
                NSApp.terminate(nil)
            }
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
        guard !(snapshot.local?.todayModelUsage.isEmpty ?? true) else { return AnyView(EmptyView()) }
        return AnyView(
            modelUsageSection
                .padding(12)
                .sectionBackground()
        )
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
        snapshot.account?.planType?.uppercased() ?? snapshot.provider.displayName.uppercased()
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
                    Text(language.text(modelSearchText.isEmpty ? "暂无数据" : "无匹配结果", modelSearchText.isEmpty ? "No data" : "No matches"))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 40)
                } else {
                    ForEach(filteredModelUsage) { item in
                        ModelUsageRow(item: item, language: language) { selectedItem in
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
            return snapshot.local == nil && snapshot.taskBoard == nil
        }
        return snapshot.primary == nil
            && snapshot.account == nil
            && snapshot.local == nil
            && snapshot.taskBoard == nil
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
                    detail: language.text("本机 token 和任务看板依赖 ~/.codex 的本地状态文件。", "Local tokens and the task board depend on Codex state files under ~/.codex."),
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

struct PromptStudioView: View {
    enum StudioSection: String, CaseIterable {
        case overview
        case promptLibrary
        case syncProfiles
        case publish
        case settings
    }

    enum PromptAssetSortMode: String, CaseIterable {
        case recent
        case name
        case path
    }

    @ObservedObject var store: UsageStore
    @Environment(\.colorScheme) private var colorScheme
    @State private var language = WidgetLanguage.storedOrAutomatic()
    @State private var themeMode = WidgetThemeMode.storedOrAutomatic()
    @State private var promptSearchText = ""
    @State private var selectedPromptSource: PromptAssetSource?
    @State private var selectedPromptKind: PromptAssetKind?
    @State private var selectedPromptAssetID: String?
    @State private var selectedProfileID: String?
    @State private var sortMode: PromptAssetSortMode = .recent
    @State private var selectedSection: StudioSection = .overview
    @State private var cachedSourceCounts: [(PromptAssetSource, Int)] = []
    @State private var cachedKindCounts: [(PromptAssetKind, Int)] = []
    @State private var cachedFilteredPromptAssets: [PromptAsset] = []
    @State private var cachedProfilePreviewContent: [AgentTargetTool: String] = [:]

    private var effectiveColorScheme: ColorScheme {
        themeMode.preferredColorScheme ?? colorScheme
    }

    private var sourceCounts: [(PromptAssetSource, Int)] {
        cachedSourceCounts
    }

    private var kindCounts: [(PromptAssetKind, Int)] {
        cachedKindCounts
    }

    private var filteredPromptAssets: [PromptAsset] {
        cachedFilteredPromptAssets
    }

    private var filteredPromptAssetIDs: [String] {
        cachedFilteredPromptAssets.map(\.id)
    }

    private var agentProfileIDs: [String] {
        store.agentProfiles.map(\.id)
    }

    private var effectiveSelectedPromptAsset: PromptAsset? {
        if let selectedPromptAssetID {
            return filteredPromptAssets.first(where: { $0.id == selectedPromptAssetID })
        }
        return filteredPromptAssets.first
    }

    private var effectiveSelectedProfile: AgentProfile? {
        if let selectedProfileID {
            return store.agentProfiles.first(where: { $0.id == selectedProfileID })
        }
        return store.agentProfiles.first
    }

    var body: some View {
        Group {
            if #available(macOS 26.0, *) {
                GlassEffectContainer(spacing: 10) {
                    studioContent
                        .glassEffect(
                            .regular.tint(WidgetPalette.windowTint(effectiveColorScheme)),
                            in: .rect(cornerRadius: 20, style: .continuous)
                        )
                }
            } else {
                studioContent
            }
        }
        .environment(\.colorScheme, effectiveColorScheme)
        .preferredColorScheme(themeMode.preferredColorScheme)
        .onAppear {
            themeMode.applyAppearance()
            rebuildLibraryCaches()
            rebuildProfilePreviewCache()
            ensurePromptSelection()
            ensureProfileSelection()
            reloadStudioPreferences()
        }
        .onReceive(NotificationCenter.default.publisher(for: .modelMeterPreferencesDidChange)) { _ in
            reloadStudioPreferences()
        }
        .onChange(of: store.promptRegistry.refreshedAt) { _, _ in
            rebuildLibraryCaches()
            ensurePromptSelection()
        }
        .onChange(of: promptSearchText) { _, _ in
            rebuildLibraryCaches()
            ensurePromptSelection()
        }
        .onChange(of: selectedPromptSource) { _, _ in
            rebuildLibraryCaches()
            ensurePromptSelection()
        }
        .onChange(of: selectedPromptKind) { _, _ in
            rebuildLibraryCaches()
            ensurePromptSelection()
        }
        .onChange(of: sortMode) { _, _ in
            rebuildLibraryCaches()
            ensurePromptSelection()
        }
        .onChange(of: filteredPromptAssetIDs) { _, _ in
            ensurePromptSelection()
        }
        .onChange(of: agentProfileIDs) { _, _ in
            rebuildProfilePreviewCache()
            ensureProfileSelection()
        }
        .onChange(of: selectedProfileID) { _, _ in
            rebuildProfilePreviewCache()
        }
        .onChange(of: store.promptRegistry.refreshedAt) { _, _ in
            rebuildProfilePreviewCache()
        }
        .onChange(of: selectedSection) { _, newSection in
            switch newSection {
            case .promptLibrary:
                rebuildLibraryCaches()
            case .syncProfiles, .publish:
                rebuildProfilePreviewCache()
            default:
                break
            }
        }
    }

    private func reloadStudioPreferences() {
        language = WidgetLanguage.storedOrAutomatic()
        themeMode = WidgetThemeMode.storedOrAutomatic()
    }

    private var studioContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Model Studio")
                        .font(.system(size: 22, weight: .semibold, design: .rounded))
                    Text(language.text("统一管理多工具 Agent 的提示词资产、同步配置与发布出口。", "Manage shared prompt assets, sync profiles, and publish flows for multi-tool agents."))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                Spacer()
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
                Button {
                    store.refreshPromptRegistry()
                } label: {
                    Image(systemName: store.isRefreshingPromptRegistry ? "hourglass" : "arrow.clockwise")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 28, height: 28)
                }
                .iconButtonStyle()
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(language.text("刷新 Prompt 资产", "Refresh prompt assets"))
            }

            HStack(alignment: .top, spacing: 12) {
                studioSidebar
                Group {
                    switch selectedSection {
                    case .overview:
                        overviewContent
                    case .promptLibrary:
                        libraryContent
                    case .syncProfiles:
                        profileContent
                    case .publish:
                        publishContent
                    case .settings:
                        settingsContent
                    }
                }
            }
        }
        .padding(16)
        .frame(minWidth: 980, minHeight: 640, alignment: .topLeading)
    }

    private var studioSidebar: some View {
        VStack(alignment: .leading, spacing: 8) {
            StudioPanelHeader(
                title: language.text("导航", "Navigation"),
                detail: language.text("Model Studio", "Model Studio")
            )

            StudioSidebarButton(
                title: language.text("总览", "Overview"),
                detail: language.text("Studio 结构与状态", "Studio structure and status"),
                systemName: "square.grid.2x2",
                isSelected: selectedSection == .overview
            ) {
                selectedSection = .overview
            }

            StudioSidebarButton(
                title: language.text("Prompt 资产", "Prompt Assets"),
                detail: language.text("浏览 Prompt / Skill / Config", "Browse prompt, skill, and config assets"),
                systemName: "text.document",
                isSelected: selectedSection == .promptLibrary
            ) {
                selectedSection = .promptLibrary
            }

            StudioSidebarButton(
                title: language.text("同步配置", "Sync Profiles"),
                detail: language.text("为不同工具编排共享 Agent", "Compose shared agents for different tools"),
                systemName: "person.crop.rectangle.stack",
                isSelected: selectedSection == .syncProfiles
            ) {
                selectedSection = .syncProfiles
            }

            StudioSidebarButton(
                title: language.text("发布与同步", "Publish & Sync"),
                detail: language.text("导出到目标工具", "Export to target tools"),
                systemName: "arrow.triangle.branch",
                isSelected: selectedSection == .publish
            ) {
                selectedSection = .publish
            }

            StudioSidebarButton(
                title: language.text("Studio 设置", "Studio Settings"),
                detail: language.text("目录、模板与策略", "Destinations, templates, and policies"),
                systemName: "slider.horizontal.3",
                isSelected: selectedSection == .settings
            ) {
                selectedSection = .settings
            }

            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(width: 220)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .sectionBackground()
    }

    private var overviewContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                PromptSummaryStatRow(
                    title: language.text("Prompt 资产", "Prompt assets"),
                    value: "\(store.promptRegistry.assets.count)",
                    detail: language.text("包含 Skill / Prompt / Config", "Including skills, prompts, and config")
                )
                PromptSummaryStatRow(
                    title: language.text("同步 Profile", "Sync profiles"),
                    value: "\(store.agentProfiles.count)",
                    detail: language.text("可为 Codex / MimoCode 输出", "Ready for Codex and MimoCode")
                )
                PromptSummaryStatRow(
                    title: language.text("来源数", "Sources"),
                    value: "\(Set(store.promptRegistry.assets.map(\.source)).count)",
                    detail: language.text("聚合本地与工作区内容", "Aggregated from local and workspace sources")
                )
            }

            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(language.text("当前能力", "Current capabilities"))
                        .font(.system(size: 12, weight: .semibold))
                    OverviewChecklistRow(text: language.text("浏览和编辑本地 Prompt / Skill", "Browse and edit local prompts and skills"))
                    OverviewChecklistRow(text: language.text("将多个资产编组成共享 Agent Profile", "Compose multiple assets into shared agent profiles"))
                    OverviewChecklistRow(text: language.text("生成 Codex / MimoCode 版本预览", "Generate Codex and MimoCode prompt previews"))
                    OverviewChecklistRow(text: language.text("为后续发布同步预留统一出口", "Reserve a unified entry for future publish and sync flows"))
                    Spacer(minLength: 0)
                }
                .padding(12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .sectionBackground()

                VStack(alignment: .leading, spacing: 10) {
                    Text(language.text("建议工作流", "Suggested workflow"))
                        .font(.system(size: 12, weight: .semibold))
                    OverviewStepRow(index: "1", text: language.text("先在 Prompt 资产里整理可复用的 Skill 与规则块", "Start by organizing reusable skills and rule blocks in Prompt Assets"))
                    OverviewStepRow(index: "2", text: language.text("在同步配置里建立不同角色的 Agent Profile", "Create role-specific agent profiles in Sync Profiles"))
                    OverviewStepRow(index: "3", text: language.text("检查 Codex / MimoCode 的导出预览差异", "Review the export differences between Codex and MimoCode"))
                    OverviewStepRow(index: "4", text: language.text("后续在发布与同步里写入真实目标目录", "Later publish them into real tool destinations from Publish & Sync"))
                    Spacer(minLength: 0)
                }
                .padding(12)
                .frame(width: 320)
                .frame(maxHeight: .infinity, alignment: .topLeading)
                .sectionBackground()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var libraryContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                promptStatPill(title: language.text("总数", "Total"), value: store.promptRegistry.assets.count)
                promptStatPill(title: language.text("Skill", "Skill"), value: store.promptRegistry.assets.filter { $0.kind == .skill }.count)
                promptStatPill(title: language.text("Prompt", "Prompt"), value: store.promptRegistry.assets.filter { $0.kind == .prompt }.count)
                promptStatPill(title: language.text("来源", "Sources"), value: Set(store.promptRegistry.assets.map(\.source)).count)
                Spacer()
                compactSearchField(
                    placeholderZh: "搜索名称、摘要、路径",
                    placeholderEn: "Search name, summary, path",
                    text: $promptSearchText,
                    width: 220
                )
                CompactFilterPicker(
                    title: language.text("来源", "Source"),
                    selection: $selectedPromptSource,
                    options: PromptAssetSource.allCases,
                    label: { source in localizedPromptSource(source, language: language) }
                )
                CompactFilterPicker(
                    title: language.text("类型", "Type"),
                    selection: $selectedPromptKind,
                    options: PromptAssetKind.allCases,
                    label: { kind in localizedPromptKind(kind, language: language) }
                )
                CompactFilterPicker(
                    title: language.text("排序", "Sort"),
                    selection: Binding(
                        get: { sortMode },
                        set: { sortMode = $0 ?? .recent }
                    ),
                    options: PromptAssetSortMode.allCases,
                    label: { mode in localizedSortMode(mode) }
                )
            }

            HStack(alignment: .top, spacing: 12) {
                librarySidebar
                libraryAssetList
                PromptAssetDetailView(
                    asset: effectiveSelectedPromptAsset,
                    language: language
                ) {
                    store.refreshPromptRegistry()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
    }

    private var librarySidebar: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 8) {
                Text(language.text("总览", "Overview"))
                    .font(.system(size: 11, weight: .semibold))
                PromptSummaryStatRow(
                    title: language.text("总条目", "Assets"),
                    value: "\(store.promptRegistry.assets.count)",
                    detail: language.text("最近刷新 \(relativeTimeText(store.promptRegistry.refreshedAt, language: language))", "Refreshed \(relativeTimeText(store.promptRegistry.refreshedAt, language: language))")
                )
                PromptSummaryStatRow(
                    title: language.text("当前结果", "Results"),
                    value: "\(filteredPromptAssets.count)",
                    detail: language.text("当前筛选后可见", "Visible after filters")
                )
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text(language.text("来源", "Sources"))
                    .font(.system(size: 11, weight: .semibold))
                PromptFilterButton(
                    title: language.text("全部来源", "All sources"),
                    count: store.promptRegistry.assets.count,
                    isSelected: selectedPromptSource == nil
                ) {
                    selectedPromptSource = nil
                }
                ForEach(sourceCounts, id: \.0) { source, count in
                    PromptFilterButton(
                        title: localizedPromptSource(source, language: language),
                        count: count,
                        isSelected: selectedPromptSource == source
                    ) {
                        selectedPromptSource = source
                    }
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text(language.text("类型", "Types"))
                    .font(.system(size: 11, weight: .semibold))
                PromptFilterButton(
                    title: language.text("全部类型", "All types"),
                    count: store.promptRegistry.assets.count,
                    isSelected: selectedPromptKind == nil
                ) {
                    selectedPromptKind = nil
                }
                ForEach(kindCounts, id: \.0) { kind, count in
                    PromptFilterButton(
                        title: localizedPromptKind(kind, language: language),
                        count: count,
                        isSelected: selectedPromptKind == kind
                    ) {
                        selectedPromptKind = kind
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(width: 190)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .sectionBackground()
    }

    private var libraryAssetList: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(language.text("条目列表", "Asset list"))
                    .font(.system(size: 11, weight: .semibold))
                Spacer()
                Text(language.text("按 \(localizedSortMode(sortMode))", "Sorted by \(localizedSortMode(sortMode))"))
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(filteredPromptAssets) { asset in
                        PromptAssetRow(
                            asset: asset,
                            language: language,
                            isSelected: asset.id == effectiveSelectedPromptAsset?.id
                        ) {
                            selectedPromptAssetID = asset.id
                        }
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .padding(12)
        .frame(width: 320)
        .frame(maxHeight: .infinity)
        .sectionBackground()
    }

    private var profileContent: some View {
        HStack(alignment: .top, spacing: 12) {
            AgentProfileListPanel(
                profiles: store.agentProfiles,
                selectedProfileID: $selectedProfileID,
                language: language
            ) {
                let created = store.createAgentProfile()
                selectedProfileID = created.id
            } onDuplicate: { id in
                if let duplicated = store.duplicateAgentProfile(id: id) {
                    selectedProfileID = duplicated.id
                }
            } onDelete: { id in
                store.deleteAgentProfile(id: id)
            }
            .frame(width: 220)

            AgentProfileEditorPanel(
                profile: effectiveSelectedProfile,
                assets: store.promptRegistry.assets,
                language: language
            ) { profile in
                store.saveAgentProfile(profile)
                selectedProfileID = profile.id
            }
            .frame(width: 420)

            AgentProfilePreviewPanel(
                profile: effectiveSelectedProfile,
                language: language,
                previewContent: cachedProfilePreviewContent
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var publishContent: some View {
        PublishSyncPanel(
            profiles: store.agentProfiles,
            assets: store.promptRegistry.assets,
            selectedProfileID: $selectedProfileID,
            store: store,
            language: language
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var settingsContent: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 12) {
                StudioPanelHeader(
                    title: language.text("Studio 设置", "Studio Settings"),
                    detail: language.text("全局偏好", "Global preferences")
                )

                HStack(spacing: 10) {
                    PromptSummaryStatRow(
                        title: language.text("界面语言", "Interface"),
                        value: language.text("中文", "English"),
                        detail: language.text("全局中英文展示", "Global language display")
                    )
                    PromptSummaryStatRow(
                        title: language.text("外观模式", "Appearance"),
                        value: themeMode == .system ? language.text("自动", "System") : themeMode == .light ? language.text("浅色", "Light") : language.text("深色", "Dark"),
                        detail: language.text("看板与 Studio 共用", "Shared by dashboard and studio")
                    )
                    PromptSummaryStatRow(
                        title: language.text("数据源数量", "Sources"),
                        value: "\(store.discoveredProviders.count)",
                        detail: language.text("当前已发现", "Currently discovered")
                    )
                }

                VStack(alignment: .leading, spacing: 10) {
                    StudioPanelHeader(
                        title: language.text("界面偏好", "Interface Preferences"),
                        detail: language.text("全局生效", "Applies globally")
                    )

                    HStack(alignment: .center, spacing: 10) {
                        settingsOptionCard(
                            title: language.text("语言", "Language"),
                            detail: language.text("影响看板、Studio 和状态栏", "Affects dashboard, studio, and status item")
                        ) {
                            LanguageSwitch(language: language) { selectedLanguage in
                                language = selectedLanguage
                                selectedLanguage.persist()
                                AppDelegate.shared?.refreshStatusItemLocalization()
                            }
                        }

                        settingsOptionCard(
                            title: language.text("外观", "Appearance"),
                            detail: language.text("自动 / 浅色 / 深色", "System / light / dark")
                        ) {
                            ThemeSwitch(themeMode: themeMode, language: language) { selectedMode in
                                themeMode = selectedMode
                                selectedMode.persist()
                                selectedMode.applyAppearance()
                            }
                        }
                    }
                }
                .padding(12)
                .sectionBackground()

                VStack(alignment: .leading, spacing: 10) {
                    StudioPanelHeader(
                        title: language.text("同步与导出", "Sync & Export"),
                        detail: language.text("当前状态", "Current state")
                    )

                    settingsInfoRow(
                        title: language.text("已配置 Profile", "Profiles configured"),
                        value: "\(store.agentProfiles.count)",
                        detail: language.text("可用于跨工具共享提示词", "Available for cross-tool prompt sharing")
                    )
                    settingsInfoRow(
                        title: language.text("已发现数据源", "Discovered sources"),
                        value: store.discoveredProviders.map(\.shortName).joined(separator: " / ").isEmpty ? language.text("无", "None") : store.discoveredProviders.map(\.shortName).joined(separator: " / "),
                        detail: language.text("用于看板统计与切换", "Used by dashboard statistics and switching")
                    )
                }
                .padding(12)
                .sectionBackground()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            VStack(alignment: .leading, spacing: 10) {
                StudioPanelHeader(
                    title: language.text("说明", "Notes"),
                    detail: language.text("风格与范围", "Style and scope")
                )

                OverviewChecklistRow(text: language.text("设置页与看板共用同一套语言和外观配置", "Settings share the same language and appearance settings as the dashboard"))
                OverviewChecklistRow(text: language.text("状态栏菜单文案也会跟随这里的中英文切换", "Status item menus also follow the language toggles here"))
                OverviewChecklistRow(text: language.text("后续可继续加入默认导出目录、模板策略等高级设置", "Advanced settings like export destinations and template policies can be added here later"))
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(width: 300)
            .frame(maxHeight: .infinity, alignment: .topLeading)
            .sectionBackground()
        }
    }

    private func placeholderContent(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(size: 16, weight: .semibold))
            Text(detail)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .sectionBackground()
    }

    private func ensurePromptSelection() {
        guard !filteredPromptAssets.isEmpty else {
            selectedPromptAssetID = nil
            return
        }
        if let selectedPromptAssetID,
           filteredPromptAssets.contains(where: { $0.id == selectedPromptAssetID }) {
            return
        }
        selectedPromptAssetID = filteredPromptAssets.first?.id
    }

    private func rebuildLibraryCaches() {
        let assets = store.promptRegistry.assets

        cachedSourceCounts = PromptAssetSource.allCases.map { source in
            (source, assets.filter { $0.source == source }.count)
        }.filter { $0.1 > 0 }

        cachedKindCounts = PromptAssetKind.allCases.map { kind in
            (kind, assets.filter { $0.kind == kind }.count)
        }.filter { $0.1 > 0 }

        let filtered = assets.filter { asset in
            let matchesSource = selectedPromptSource == nil || asset.source == selectedPromptSource
            let matchesKind = selectedPromptKind == nil || asset.kind == selectedPromptKind
            let matchesSearch: Bool
            if promptSearchText.isEmpty {
                matchesSearch = true
            } else {
                let query = promptSearchText.lowercased()
                matchesSearch =
                    asset.name.lowercased().contains(query)
                    || asset.summary.lowercased().contains(query)
                    || asset.tags.joined(separator: " ").lowercased().contains(query)
                    || asset.path.lowercased().contains(query)
            }
            return matchesSource && matchesKind && matchesSearch
        }

        switch sortMode {
        case .recent:
            cachedFilteredPromptAssets = filtered.sorted { lhs, rhs in
                switch (lhs.modifiedAt, rhs.modifiedAt) {
                case let (left?, right?):
                    if left != right { return left > right }
                case (.some, nil):
                    return true
                case (nil, .some):
                    return false
                default:
                    break
                }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
        case .name:
            cachedFilteredPromptAssets = filtered.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .path:
            cachedFilteredPromptAssets = filtered.sorted { $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending }
        }
    }

    private func settingsOptionCard<Content: View>(
        title: String,
        detail: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
            Text(detail)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
            content()
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground(cornerRadius: 10)
    }

    private func settingsInfoRow(title: String, value: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Text(value)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
            Text(detail)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(WidgetPalette.surfaceTrack)
        )
    }

    private func rebuildProfilePreviewCache() {
        guard let profile = effectiveSelectedProfile else {
            cachedProfilePreviewContent = [:]
            return
        }

        var contentByTool: [AgentTargetTool: String] = [:]
        for tool in AgentTargetTool.allCases {
            contentByTool[tool] = renderAgentProfilePrompt(
                profile: profile,
                assets: store.promptRegistry.assets,
                tool: tool
            )
        }
        cachedProfilePreviewContent = contentByTool
    }

    private func ensureProfileSelection() {
        guard !store.agentProfiles.isEmpty else {
            selectedProfileID = nil
            return
        }
        if let selectedProfileID,
           store.agentProfiles.contains(where: { $0.id == selectedProfileID }) {
            return
        }
        selectedProfileID = store.agentProfiles.first?.id
    }

    private func promptStatPill(title: String, value: Int) -> some View {
        Text("\(title) \(value)")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                Capsule(style: .continuous)
                .fill(WidgetPalette.surfaceTrack)
        )
    }

    private func localizedSortMode(_ mode: PromptAssetSortMode) -> String {
        switch mode {
        case .recent:
            return language.text("最近更新", "Recently updated")
        case .name:
            return language.text("名称", "Name")
        case .path:
            return language.text("路径", "Path")
        }
    }

    private func compactSearchField(
        placeholderZh: String,
        placeholderEn: String,
        text: Binding<String>,
        width: CGFloat
    ) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
            TextField(language.text(placeholderZh, placeholderEn), text: text)
                .font(.system(size: 10))
                .textFieldStyle(.plain)
            if !text.wrappedValue.isEmpty {
                Button {
                    text.wrappedValue = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(width: width)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(WidgetPalette.surfaceTrack)
        )
    }
}

struct PromptSummaryStatRow: View {
    let title: String
    let value: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Text(value)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)
            }
            Text(detail)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(WidgetPalette.surfaceTrack)
        )
    }
}

struct PromptFilterButton: View {
    let title: String
    let count: Int
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 10, weight: isSelected ? .semibold : .medium))
                    .lineLimit(1)
                Spacer(minLength: 6)
                Text("\(count)")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(isSelected ? .primary : .secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? WidgetPalette.sectionTint(.light).opacity(0.35) : WidgetPalette.surfaceTrack)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(isSelected ? WidgetPalette.brandPrimary.opacity(0.8) : Color.clear, lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
    }
}

struct StudioSidebarButton: View {
    let title: String
    let detail: String
    let systemName: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: systemName)
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 16, height: 16)
                    .foregroundStyle(isSelected ? WidgetPalette.brandPrimary : Color.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text(detail)
                        .font(.system(size: 8, weight: .medium))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? WidgetPalette.surfaceTrack : Color.clear)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(isSelected ? WidgetPalette.brandPrimary.opacity(0.8) : Color.clear, lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
    }
}

struct StudioPanelHeader: View {
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
            Spacer()
            Text(detail)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }
}

struct OverviewChecklistRow: View {
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(WidgetPalette.brandPrimary)
            Text(text)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }
}

struct OverviewStepRow: View {
    let index: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(index)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.primary)
                .frame(width: 18, height: 18)
                .background(
                    Circle()
                        .fill(WidgetPalette.surfaceTrack)
                )
            Text(text)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct AgentProfileListPanel: View {
    let profiles: [AgentProfile]
    @Binding var selectedProfileID: String?
    let language: WidgetLanguage
    let onCreate: () -> Void
    let onDuplicate: (String) -> Void
    let onDelete: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                StudioPanelHeader(
                    title: language.text("Profiles", "Profiles"),
                    detail: "\(profiles.count)"
                )
                Button(action: onCreate) {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .semibold))
                }
                .iconButtonStyle()
                .buttonStyle(.plain)
            }

            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(profiles) { profile in
                        Button {
                            selectedProfileID = profile.id
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(profile.name)
                                        .font(.system(size: 11, weight: .semibold))
                                        .lineLimit(1)
                                    Spacer(minLength: 4)
                                    Button {
                                        onDuplicate(profile.id)
                                    } label: {
                                        Image(systemName: "plus.square.on.square")
                                            .font(.system(size: 9, weight: .semibold))
                                    }
                                    .buttonStyle(.plain)
                                    .foregroundStyle(.tertiary)
                                    Button {
                                        onDelete(profile.id)
                                    } label: {
                                        Image(systemName: "trash")
                                            .font(.system(size: 9, weight: .semibold))
                                    }
                                    .buttonStyle(.plain)
                                    .foregroundStyle(.tertiary)
                                }
                                Text(profile.summary.isEmpty ? language.text("未填写简介", "No summary") : profile.summary)
                                    .font(.system(size: 9, weight: .medium))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                                Text(relativeTimeText(profile.updatedAt, language: language))
                                    .font(.system(size: 8, weight: .medium))
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(selectedProfileID == profile.id ? WidgetPalette.sectionTint(.light).opacity(0.35) : WidgetPalette.surfaceTrack)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            .strokeBorder(selectedProfileID == profile.id ? WidgetPalette.brandPrimary : Color.clear, lineWidth: 1)
                                    )
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(12)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .sectionBackground()
    }
}

struct AgentProfileEditorPanel: View {
    let profile: AgentProfile?
    let assets: [PromptAsset]
    let language: WidgetLanguage
    let onSave: (AgentProfile) -> Void

    @State private var draftName = ""
    @State private var draftSummary = ""
    @State private var draftPersona = ""
    @State private var draftWorkingStyle = ""
    @State private var draftConstraints = ""
    @State private var selectedAssetIDs: Set<String> = []
    @State private var assetSearch = ""
    @State private var saveBanner: String?

    private var filteredAssets: [PromptAsset] {
        guard !assetSearch.isEmpty else { return assets }
        let query = assetSearch.lowercased()
        return assets.filter {
            $0.name.lowercased().contains(query)
            || $0.summary.lowercased().contains(query)
            || $0.path.lowercased().contains(query)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                StudioPanelHeader(
                    title: language.text("Profile 编辑", "Profile editor"),
                    detail: language.text("共享配置", "Shared config")
                )
                Spacer()
                Button {
                    saveProfile()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "checkmark")
                        Text(language.text("保存", "Save"))
                    }
                    .font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(WidgetPalette.brandPrimary.opacity(0.14))
                )
            }

            if let saveBanner {
                Text(saveBanner)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            Group {
                compactLabeledField(title: language.text("名称", "Name"), text: $draftName)
                compactLabeledField(title: language.text("使命", "Mission"), text: $draftSummary)
                compactLabeledEditor(title: language.text("人格", "Persona"), text: $draftPersona, minHeight: 70)
                compactLabeledEditor(title: language.text("工作方式", "Working style"), text: $draftWorkingStyle, minHeight: 88)
                compactLabeledEditor(title: language.text("约束", "Constraints"), text: $draftConstraints, minHeight: 88)
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(language.text("共享资产", "Shared assets"))
                        .font(.system(size: 10, weight: .semibold))
                    Spacer()
                    Text("\(selectedAssetIDs.count)")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                    TextField(language.text("搜索可编入的 Prompt/Skill", "Search prompt or skill"), text: $assetSearch)
                        .textFieldStyle(.plain)
                        .font(.system(size: 10))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(WidgetPalette.surfaceTrack)
                )

                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(filteredAssets) { asset in
                            Button {
                                toggleSelection(asset.id)
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: selectedAssetIDs.contains(asset.id) ? "checkmark.circle.fill" : "circle")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(selectedAssetIDs.contains(asset.id) ? WidgetPalette.brandPrimary : Color.secondary)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(asset.name)
                                            .font(.system(size: 10, weight: .semibold))
                                            .lineLimit(1)
                                        Text(asset.summary.isEmpty ? asset.path : asset.summary)
                                            .font(.system(size: 9, weight: .medium))
                                            .foregroundStyle(.secondary)
                                            .lineLimit(2)
                                    }
                                    Spacer(minLength: 6)
                                }
                                .padding(8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(WidgetPalette.surfaceTrack)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(minHeight: 180)
            }
        }
        .padding(12)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .sectionBackground()
        .onAppear {
            loadProfile()
        }
        .onChange(of: profile?.id) {
            loadProfile()
        }
    }

    private func loadProfile() {
        guard let profile else { return }
        draftName = profile.name
        draftSummary = profile.summary
        draftPersona = profile.persona
        draftWorkingStyle = profile.workingStyle
        draftConstraints = profile.constraints
        selectedAssetIDs = Set(profile.selectedAssetIDs)
        saveBanner = nil
    }

    private func toggleSelection(_ id: String) {
        if selectedAssetIDs.contains(id) {
            selectedAssetIDs.remove(id)
        } else {
            selectedAssetIDs.insert(id)
        }
    }

    private func saveProfile() {
        guard var profile else { return }
        profile.name = draftName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? language.text("未命名 Profile", "Untitled profile") : draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.summary = draftSummary.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.persona = draftPersona.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.workingStyle = draftWorkingStyle.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.constraints = draftConstraints.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.selectedAssetIDs = Array(selectedAssetIDs)
        profile.updatedAt = Date()
        onSave(profile)
        saveBanner = language.text("Profile 已保存", "Profile saved")
    }

    private func compactLabeledField(title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            TextField(title, text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 10))
                .padding(.horizontal, 8)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(WidgetPalette.surfaceTrack)
                )
        }
    }

    private func compactLabeledEditor(title: String, text: Binding<String>, minHeight: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            TextEditor(text: text)
                .font(.system(size: 10))
                .frame(minHeight: minHeight)
                .padding(6)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(WidgetPalette.surfaceTrack)
                )
        }
    }
}

struct AgentProfilePreviewPanel: View {
    let profile: AgentProfile?
    let language: WidgetLanguage
    let previewContent: [AgentTargetTool: String]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                StudioPanelHeader(
                    title: language.text("同步预览", "Sync preview"),
                    detail: profile.map { "\($0.selectedAssetIDs.count) \(language.text("条共享资产", "shared assets"))" } ?? ""
                )
                Spacer()
            }

            if profile != nil {
                HStack(alignment: .top, spacing: 10) {
                    ForEach(AgentTargetTool.allCases, id: \.self) { tool in
                        let content = previewContent[tool] ?? ""
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(localizedTargetTool(tool, language: language))
                                    .font(.system(size: 11, weight: .semibold))
                                Spacer()
                                Button {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(content, forType: .string)
                                } label: {
                                    HStack(spacing: 4) {
                                        Image(systemName: "doc.on.doc")
                                        Text(language.text("复制", "Copy"))
                                    }
                                    .font(.system(size: 9, weight: .semibold))
                                }
                                .buttonStyle(.plain)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 5)
                                .background(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(WidgetPalette.surfaceTrack)
                                )
                            }

                            ScrollView {
                                Text(content)
                                    .font(.system(size: 10, weight: .regular, design: .monospaced))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(maxHeight: .infinity)
                            .padding(8)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(WidgetPalette.surfaceTrack)
                            )
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    }
                }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "person.crop.rectangle.stack")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(.tertiary)
                    Text(language.text("先创建一个 Profile，再组合你的共享提示词。", "Create a profile first, then compose shared prompt assets."))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(12)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .sectionBackground()
    }
}

struct PublishSyncPanel: View {
    let profiles: [AgentProfile]
    let assets: [PromptAsset]
    @Binding var selectedProfileID: String?
    @ObservedObject var store: UsageStore
    let language: WidgetLanguage

    @State private var saveStatus: [AgentTargetTool: String] = [:]

    private var selectedProfile: AgentProfile? {
        if let selectedProfileID {
            return profiles.first(where: { $0.id == selectedProfileID })
        }
        return profiles.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(language.text("发布与同步", "Publish & Sync"))
                        .font(.system(size: 14, weight: .semibold))
                    Text(language.text("把共享 Agent Profile 输出为不同工具可消费的文件。", "Export shared agent profiles into files consumable by different tools."))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Menu {
                    ForEach(profiles) { profile in
                        Button(profile.name) {
                            selectedProfileID = profile.id
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text(selectedProfile?.name ?? language.text("选择 Profile", "Select profile"))
                            .font(.system(size: 10, weight: .medium))
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8, weight: .semibold))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(WidgetPalette.surfaceTrack)
                    )
                }
                .menuStyle(.borderlessButton)
            }

            if let profile = selectedProfile {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 10) {
                        PromptSummaryStatRow(
                            title: language.text("已选资产", "Selected assets"),
                            value: "\(profile.selectedAssetIDs.count)",
                            detail: language.text("将被编入导出结果", "Will be embedded into exported output")
                        )
                        PromptSummaryStatRow(
                            title: language.text("可导出工具", "Target tools"),
                            value: "\(AgentTargetTool.allCases.count)",
                            detail: language.text("当前支持 Codex / MimoCode", "Currently supports Codex and MimoCode")
                        )
                        PromptSummaryStatRow(
                            title: language.text("最近更新", "Updated"),
                            value: relativeTimeText(profile.updatedAt, language: language),
                            detail: language.text("修改 Profile 后可重新导出", "Re-export after editing the profile")
                        )
                        Spacer(minLength: 0)
                    }
                    .frame(width: 220)
                    .padding(10)
                    .cardBackground(cornerRadius: 10, elevated: true)

                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(AgentTargetTool.allCases, id: \.self) { tool in
                            PublishTargetCard(
                                profile: profile,
                                tool: tool,
                                assets: assets,
                                store: store,
                                language: language,
                                status: saveStatus[tool]
                            ) { status in
                                saveStatus[tool] = status
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(.tertiary)
                    Text(language.text("先创建一个 Profile，才能配置发布路径。", "Create a profile first before configuring publish destinations."))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(12)
        .sectionBackground()
    }
}

struct PublishTargetCard: View {
    let profile: AgentProfile
    let tool: AgentTargetTool
    let assets: [PromptAsset]
    @ObservedObject var store: UsageStore
    let language: WidgetLanguage
    let status: String?
    let onStatusChange: (String) -> Void

    @State private var pathText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(localizedTargetTool(tool, language: language))
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Button {
                    if pathText.isEmpty {
                        pathText = suggestedExportPath(profile: profile, tool: tool)
                        persistPath()
                    } else {
                        openSavePanel()
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "folder")
                        Text(language.text("浏览", "Browse"))
                    }
                    .font(.system(size: 9, weight: .semibold))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 7)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(WidgetPalette.surfaceTrack)
                )
            }

            TextField(language.text("输出路径", "Output path"), text: $pathText)
                .textFieldStyle(.plain)
                .font(.system(size: 10))
                .padding(.horizontal, 8)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(WidgetPalette.surfaceTrack)
                )
                .onChange(of: pathText) {
                    persistPath()
                }

            HStack(spacing: 8) {
                Button {
                    if pathText.isEmpty {
                        pathText = suggestedExportPath(profile: profile, tool: tool)
                        persistPath()
                    }
                } label: {
                    Text(language.text("使用建议路径", "Use suggested path"))
                        .font(.system(size: 9, weight: .semibold))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(WidgetPalette.surfaceTrack)
                )

                Button {
                    exportToFile()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "square.and.arrow.down")
                        Text(language.text("导出文件", "Export file"))
                    }
                    .font(.system(size: 9, weight: .semibold))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(WidgetPalette.brandPrimary.opacity(0.14))
                )

                Button {
                    let content = renderAgentProfilePrompt(profile: profile, assets: assets, tool: tool)
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(content, forType: .string)
                    onStatusChange(language.text("已复制当前导出内容", "Copied current export content"))
                } label: {
                    Text(language.text("复制导出", "Copy export"))
                        .font(.system(size: 9, weight: .semibold))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(WidgetPalette.surfaceTrack)
                )

                Button {
                    let finalPath = NSString(string: pathText.isEmpty ? suggestedExportPath(profile: profile, tool: tool) : pathText).expandingTildeInPath
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(finalPath, forType: .string)
                    onStatusChange(language.text("已复制导出路径", "Copied export path"))
                } label: {
                    Text(language.text("复制路径", "Copy path"))
                        .font(.system(size: 9, weight: .semibold))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(WidgetPalette.surfaceTrack)
                )
            }

            HStack(spacing: 8) {
                Button {
                    revealExportFile()
                } label: {
                    Text(language.text("显示文件", "Reveal file"))
                        .font(.system(size: 9, weight: .semibold))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(WidgetPalette.surfaceTrack)
                )

                Button {
                    openExportFile()
                } label: {
                    Text(language.text("打开文件", "Open file"))
                        .font(.system(size: 9, weight: .semibold))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(WidgetPalette.surfaceTrack)
                )
            }

            if let status {
                Text(status)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .cardBackground(cornerRadius: 10)
        .onAppear {
            let stored = store.exportPath(profileID: profile.id, tool: tool)
            pathText = stored.isEmpty ? suggestedExportPath(profile: profile, tool: tool) : stored
        }
        .onChange(of: profile.id) {
            let stored = store.exportPath(profileID: profile.id, tool: tool)
            pathText = stored.isEmpty ? suggestedExportPath(profile: profile, tool: tool) : stored
        }
    }

    private func persistPath() {
        store.setExportPath(pathText, profileID: profile.id, tool: tool)
    }

    private func openSavePanel() {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = URL(fileURLWithPath: pathText.isEmpty ? suggestedExportPath(profile: profile, tool: tool) : pathText).lastPathComponent
        panel.directoryURL = URL(fileURLWithPath: NSString(string: pathText.isEmpty ? suggestedExportPath(profile: profile, tool: tool) : pathText).expandingTildeInPath).deletingLastPathComponent()
        if panel.runModal() == .OK, let url = panel.url {
            pathText = url.path
            persistPath()
        }
    }

    private func exportToFile() {
        let finalPath = NSString(string: pathText.isEmpty ? suggestedExportPath(profile: profile, tool: tool) : pathText).expandingTildeInPath
        let content = renderAgentProfilePrompt(profile: profile, assets: assets, tool: tool)
        let url = URL(fileURLWithPath: finalPath)

        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: url, atomically: true, encoding: .utf8)
            pathText = finalPath
            persistPath()
            onStatusChange(language.text("已导出到 \(finalPath)", "Exported to \(finalPath)"))
        } catch {
            onStatusChange(language.text("导出失败：\(error.localizedDescription)", "Export failed: \(error.localizedDescription)"))
        }
    }

    private func revealExportFile() {
        let finalPath = NSString(string: pathText.isEmpty ? suggestedExportPath(profile: profile, tool: tool) : pathText).expandingTildeInPath
        if FileManager.default.fileExists(atPath: finalPath) {
            NSWorkspace.shared.selectFile(finalPath, inFileViewerRootedAtPath: "")
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: finalPath).deletingLastPathComponent())
        }
    }

    private func openExportFile() {
        let finalPath = NSString(string: pathText.isEmpty ? suggestedExportPath(profile: profile, tool: tool) : pathText).expandingTildeInPath
        let fileURL = URL(fileURLWithPath: finalPath)
        if FileManager.default.fileExists(atPath: finalPath) {
            NSWorkspace.shared.open(fileURL)
        } else {
            NSWorkspace.shared.open(fileURL.deletingLastPathComponent())
        }
    }
}

struct SectionTitle: View {
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
            Spacer()
            Text(detail)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }
}

struct CompactFilterPicker<Option: Hashable>: View {
    let title: String
    @Binding var selection: Option?
    let options: [Option]
    let label: (Option) -> String

    var body: some View {
        Menu {
            Button(title) {
                selection = nil
            }
            ForEach(options, id: \.self) { option in
                Button(label(option)) {
                    selection = option
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(selection.map(label) ?? title)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(WidgetPalette.surfaceTrack)
            )
        }
        .menuStyle(.borderlessButton)
    }
}

struct PromptAssetRow: View {
    let asset: PromptAsset
    let language: WidgetLanguage
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(asset.name)
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(localizedPromptKind(asset.kind, language: language))
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                Text(asset.summary.isEmpty ? asset.path : asset.summary)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    Text(localizedPromptSource(asset.source, language: language))
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.tertiary)
                    if let firstTag = asset.tags.first {
                        Text(firstTag)
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? WidgetPalette.sectionTint(.light).opacity(0.35) : WidgetPalette.cardFill(.light, elevated: true))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(isSelected ? WidgetPalette.brandPrimary : WidgetPalette.cardStroke(.light, elevated: true), lineWidth: isSelected ? 1.2 : 0.8)
                    )
            )
        }
        .buttonStyle(.plain)
    }
}

struct PromptAssetDetailView: View {
    let asset: PromptAsset?
    let language: WidgetLanguage
    let onSaved: () -> Void

    @State private var isEditing = false
    @State private var draftContent = ""
    @State private var saveMessage: String?
    @State private var saveMessageIsError = false

    private var isWritable: Bool {
        guard let asset else { return false }
        return FileManager.default.isWritableFile(atPath: asset.path)
    }

    var body: some View {
        Group {
            if let asset {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(asset.name)
                                    .font(.system(size: 13, weight: .semibold))
                                Text(asset.path)
                                    .font(.system(size: 9, weight: .medium))
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                            Spacer(minLength: 8)
                            VStack(alignment: .trailing, spacing: 4) {
                                Text(localizedPromptSource(asset.source, language: language))
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                Text(localizedPromptKind(asset.kind, language: language))
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundStyle(.tertiary)
                            }
                        }

                        HStack(spacing: 8) {
                            PromptActionButton(
                                title: isEditing ? language.text("取消编辑", "Cancel edit") : language.text("编辑内容", "Edit content"),
                                systemName: isEditing ? "xmark" : "square.and.pencil"
                            ) {
                                if isEditing {
                                    resetDraft(for: asset)
                                } else {
                                    draftContent = asset.content
                                    saveMessage = nil
                                    isEditing = true
                                }
                            }

                            if isEditing {
                                PromptActionButton(
                                    title: language.text("保存", "Save"),
                                    systemName: "checkmark"
                                ) {
                                    saveAsset(asset)
                                }
                            }

                            if !isWritable {
                                PromptMetadataPill(
                                    title: language.text("权限", "Access"),
                                    value: language.text("只读", "Read only")
                                )
                            }
                        }

                        HStack(spacing: 8) {
                            PromptActionButton(
                                title: language.text("复制内容", "Copy content"),
                                systemName: "doc.on.doc"
                            ) {
                                let content = isEditing ? draftContent : asset.content
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(content, forType: .string)
                            }
                            PromptActionButton(
                                title: language.text("复制路径", "Copy path"),
                                systemName: "link"
                            ) {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(asset.path, forType: .string)
                            }
                            PromptActionButton(
                                title: language.text("显示文件", "Reveal"),
                                systemName: "folder"
                            ) {
                                NSWorkspace.shared.selectFile(asset.path, inFileViewerRootedAtPath: "")
                            }
                            PromptActionButton(
                                title: language.text("打开文件", "Open"),
                                systemName: "arrow.up.forward.square"
                            ) {
                                NSWorkspace.shared.open(URL(fileURLWithPath: asset.path))
                            }
                        }

                        HStack(spacing: 8) {
                            PromptMetadataPill(
                                title: language.text("更新", "Updated"),
                                value: asset.modifiedAt.map { relativeTimeText($0, language: language) } ?? language.text("未知", "Unknown")
                            )
                            PromptMetadataPill(
                                title: language.text("行数", "Lines"),
                                value: "\(max(asset.content.components(separatedBy: .newlines).count, 1))"
                            )
                            PromptMetadataPill(
                                title: language.text("字符", "Chars"),
                                value: "\(isEditing ? draftContent.count : asset.content.count)"
                            )
                        }

                        if let saveMessage {
                            Text(saveMessage)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(saveMessageIsError ? Color.red : Color.secondary)
                        }

                        if !asset.tags.isEmpty {
                            FlowLayout(spacing: 6) {
                                ForEach(asset.tags, id: \.self) { tag in
                                    Text(tag)
                                        .font(.system(size: 8, weight: .semibold))
                                        .foregroundStyle(.secondary)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 3)
                                        .background(
                                            Capsule(style: .continuous)
                                                .fill(WidgetPalette.surfaceTrack)
                                        )
                                }
                            }
                        }

                        if !asset.summary.isEmpty {
                            Text(asset.summary)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.secondary)
                        }

                        Divider()

                        Text(isEditing ? language.text("内容编辑", "Content editor") : language.text("内容预览", "Content preview"))
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)

                        if isEditing {
                            TextEditor(text: $draftContent)
                                .font(.system(size: 10, weight: .regular, design: .monospaced))
                                .frame(minHeight: 420, alignment: .topLeading)
                                .padding(8)
                                .background(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(WidgetPalette.surfaceTrack)
                                )
                        } else {
                            Text(asset.content)
                                .font(.system(size: 10, weight: .regular, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(10)
                }
                .cardBackground(cornerRadius: 10, elevated: true)
                .onAppear {
                    resetDraft(for: asset)
                }
                .onChange(of: asset.id) {
                    resetDraft(for: asset)
                }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "text.document")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(.tertiary)
                    Text(language.text("暂无提示词条目", "No prompt assets"))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .cardBackground(cornerRadius: 10, elevated: true)
            }
        }
    }

    private func resetDraft(for asset: PromptAsset) {
        draftContent = asset.content
        isEditing = false
        saveMessage = nil
        saveMessageIsError = false
    }

    private func saveAsset(_ asset: PromptAsset) {
        guard isWritable else {
            saveMessage = language.text("当前文件只读，无法保存。", "This file is read-only and cannot be saved.")
            saveMessageIsError = true
            return
        }

        do {
            try draftContent.write(to: URL(fileURLWithPath: asset.path), atomically: true, encoding: .utf8)
            saveMessage = language.text("已保存", "Saved")
            saveMessageIsError = false
            isEditing = false
            onSaved()
        } catch {
            saveMessage = language.text("保存失败：\(error.localizedDescription)", "Save failed: \(error.localizedDescription)")
            saveMessageIsError = true
        }
    }
}

struct PromptActionButton: View {
    let title: String
    let systemName: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: systemName)
                    .font(.system(size: 10, weight: .semibold))
                Text(title)
                    .font(.system(size: 10, weight: .semibold))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(WidgetPalette.surfaceTrack)
            )
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
    }
}

struct PromptMetadataPill: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(WidgetPalette.surfaceTrack)
        )
    }
}

struct LanguageSwitch: View {
    let language: WidgetLanguage
    let onSelect: (WidgetLanguage) -> Void

    var body: some View {
        Picker("", selection: Binding(
            get: { language },
            set: { onSelect($0) }
        )) {
            Text("中").tag(WidgetLanguage.zh)
            Text("EN").tag(WidgetLanguage.en)
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .controlSize(.mini)
        .frame(width: 70)
    }
}

struct ProviderSwitch: View {
    let provider: UsageProvider
    let language: WidgetLanguage
    let onSelect: (UsageProvider) -> Void

    var body: some View {
        Picker("", selection: Binding(
            get: { provider },
            set: { onSelect($0) }
        )) {
            ForEach(UsageProvider.allCases, id: \.self) { item in
                Text(item.shortLabel).tag(item)
            }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .controlSize(.mini)
        .frame(width: 122)
        .help(language.text("数据源：Codex / MimoCode", "Source: Codex / MimoCode"))
        .accessibilityLabel(language.text("数据源", "Source"))
    }
}

struct DiscoveredProviderPicker: View {
    let providers: [DiscoveredProvider]
    let selected: DiscoveredProvider?
    let language: WidgetLanguage
    let onSelect: (DiscoveredProvider) -> Void
    let onRediscover: () -> Void

    var body: some View {
        Menu {
            ForEach(providers) { provider in
                Button {
                    onSelect(provider)
                } label: {
                    HStack {
                        Image(systemName: provider.icon)
                        Text(provider.name)
                        if provider.id == selected?.id {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
            Divider()
            Button {
                onRediscover()
            } label: {
                HStack {
                    Image(systemName: "arrow.clockwise")
                    Text(language.text("重新发现数据源", "Rediscover sources"))
                }
            }
        } label: {
            HStack(spacing: 4) {
                if let selected {
                    Image(systemName: selected.icon)
                        .font(.system(size: 10))
                    Text(selected.shortName)
                        .font(.system(size: 10, weight: .medium))
                } else {
                    Image(systemName: "questionmark.circle")
                        .font(.system(size: 10))
                    Text(language.text("无数据源", "No source"))
                        .font(.system(size: 10, weight: .medium))
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(WidgetPalette.surfaceTrack)
            )
        }
        .menuStyle(.borderlessButton)
        .frame(minWidth: 80)
        .help(language.text("选择数据源", "Select data source"))
    }
}

struct ThemeSwitch: View {
    let themeMode: WidgetThemeMode
    let language: WidgetLanguage
    let onSelect: (WidgetThemeMode) -> Void

    var body: some View {
        Picker("", selection: Binding(
            get: { themeMode },
            set: { onSelect($0) }
        )) {
            Image(systemName: "circle.lefthalf.filled")
                .tag(WidgetThemeMode.system)
            Image(systemName: "sun.max.fill")
                .tag(WidgetThemeMode.light)
            Image(systemName: "moon.fill")
                .tag(WidgetThemeMode.dark)
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .controlSize(.mini)
        .frame(width: 86)
        .help(language.text("外观：自动、浅色、深色", "Appearance: system, light, dark"))
        .accessibilityLabel(language.text("外观模式", "Appearance mode"))
    }
}

struct SectionBackgroundModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
                .glassEffect(
                    .regular.tint(WidgetPalette.sectionTint(colorScheme)),
                    in: .rect(cornerRadius: 18, style: .continuous)
                )
        } else {
            content
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(WidgetPalette.sectionFill(colorScheme))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(WidgetPalette.sectionStroke(colorScheme), lineWidth: 0.8)
                        )
                )
        }
    }
}

struct CardBackgroundModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    let cornerRadius: CGFloat
    let elevated: Bool

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(WidgetPalette.cardFill(colorScheme, elevated: elevated))
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .strokeBorder(WidgetPalette.cardStroke(colorScheme, elevated: elevated), lineWidth: 0.8)
                    )
            )
    }
}

extension View {
    func sectionBackground() -> some View {
        modifier(SectionBackgroundModifier())
    }

    func cardBackground(cornerRadius: CGFloat = 10, elevated: Bool = false) -> some View {
        modifier(CardBackgroundModifier(cornerRadius: cornerRadius, elevated: elevated))
    }

    func iconButtonStyle() -> some View {
        modifier(IconButtonStyleModifier())
    }
}

struct IconButtonStyleModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
                .buttonStyle(.glass)
        } else {
            content
                .buttonStyle(.plain)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(WidgetPalette.controlFill(colorScheme))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(WidgetPalette.controlStroke(colorScheme), lineWidth: 0.8)
                        )
                )
        }
    }
}

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
            // Hover 信息（右上角，固定高度）
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

            // 间距
            Spacer(minLength: 10)

            // 柱状图区域（包含 token 数量、柱子、日期）
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

struct DetailedTokenMetricCard: View {
    let title: String
    let systemName: String
    let usage: PricedTokenUsage?
    let fallbackTokens: Int64?
    let language: WidgetLanguage
    let currency: ModelTokenPrice.Currency

    private var displayTokens: Int64? {
        usage?.tokens.visibleTotalTokens ?? fallbackTokens
    }

    private var cacheHitRate: Double? {
        guard let tokens = usage?.tokens, tokens.inputTokens > 0 else { return nil }
        return Double(tokens.billableCachedInputTokens) / Double(tokens.inputTokens)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: systemName)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(WidgetPalette.surfaceTrack)
                    )
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(formatUSD(usage?.estimatedCostUSD, currency: currency))
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }

            HStack(alignment: .center, spacing: 8) {
                Text(formatTokens(displayTokens))
                    .font(.system(size: 21, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)

                Spacer(minLength: 4)

                CacheHitBadge(rate: cacheHitRate, language: language)
            }

            TokenSplitBar(tokens: usage?.tokens)
                .frame(height: 8)

            VStack(spacing: 3) {
                TokenSplitLegendRow(
                    title: language.text("未缓存", "Input"),
                    value: usage?.tokens.uncachedInputTokens,
                    color: uncachedInputColor
                )
                TokenSplitLegendRow(
                    title: language.text("缓存", "Cached"),
                    value: usage?.tokens.billableCachedInputTokens,
                    color: cachedInputColor
                )
                TokenSplitLegendRow(
                    title: language.text("输出", "Output"),
                    value: usage?.tokens.outputTokens,
                    color: outputTokenColor
                )
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 128, alignment: .leading)
        .cardBackground(cornerRadius: 10)
    }
}

struct CacheHitBadge: View {
    let rate: Double?
    let language: WidgetLanguage

    var body: some View {
        ZStack {
            Color.clear
            Text(rateText)
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(hitColor)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .frame(width: 34, height: 34)
        .contentShape(Rectangle())
        .help(language.text("缓存命中率 = 缓存输入 / 输入总量", "Cache hit rate = cached input / total input"))
        .accessibilityLabel(language.text("缓存命中率 \(rateText)", "Cache hit rate \(rateText)"))
    }

    private var rateText: String {
        guard let rate else { return "--" }
        return "\(Int((rate * 100).rounded()))%"
    }

    private var hitColor: Color {
        guard let rate else { return WidgetPalette.statusInfo }
        if rate >= 0.85 { return WidgetPalette.statusSuccess }
        if rate >= 0.60 { return WidgetPalette.statusWarning }
        return WidgetPalette.statusDanger
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

struct ModelUsageRow: View {
    let item: ModelUsageItem
    let language: WidgetLanguage
    var onSelect: ((ModelUsageItem) -> Void)? = nil

    private var cacheHitRate: Double {
        let totalInput = item.uncachedInputTokens + item.cachedInputTokens
        guard totalInput > 0 else { return 0 }
        return Double(item.cachedInputTokens) / Double(totalInput) * 100
    }

    private var providerColor: Color {
        switch item.provider {
        case "OpenAI": return .blue
        case "Anthropic": return .orange
        case "Google": return .green
        case "DeepSeek": return .purple
        case "Alibaba": return .red
        case "Meta": return .cyan
        default: return .gray
        }
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
            .frame(minWidth: hasPriceData ? 90 : 70, alignment: .leading)

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

    private var providerColor: Color {
        switch item.provider {
        case "OpenAI": return .blue
        case "Anthropic": return .orange
        case "Google": return .green
        case "DeepSeek": return .purple
        case "Alibaba": return .red
        case "Meta": return .cyan
        default: return .gray
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.model)
                        .font(.title2.bold())
                    HStack(spacing: 8) {
                        Text(item.provider)
                            .font(.subheadline)
                            .foregroundStyle(providerColor)
                        if item.inputPricePerMillion > 0 {
                            let symbol = item.currency.rawValue
                            Text("\(symbol)\(String(format: "%.2f", item.inputPricePerMillion))/\(symbol)\(String(format: "%.2f", item.cachedInputPricePerMillion))/\(symbol)\(String(format: "%.2f", item.outputPricePerMillion))")
                                .font(.caption)
                                .foregroundStyle(currencyColor(item.currency))
                        }
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
                GridItem(.flexible())
            ], spacing: 12) {
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
                    title: language.text("未缓存", "Uncached"),
                    value: formatTokens(item.uncachedInputTokens),
                    color: uncachedInputColor
                )
                DetailMetricCard(
                    title: language.text("缓存", "Cached"),
                    value: formatTokens(item.cachedInputTokens),
                    color: cachedInputColor
                )
                DetailMetricCard(
                    title: language.text("输出", "Output"),
                    value: formatTokens(item.outputTokens),
                    color: WidgetPalette.statusSuccess
                )
                DetailMetricCard(
                    title: language.text("缓存率", "Cache Hit"),
                    value: "\(Int(cacheHitRate))%",
                    color: cacheHitRate >= 50 ? WidgetPalette.brandSecondary : .secondary
                )
            }

            if item.tokens > 0 {
                VStack(alignment: .leading, spacing: 6) {
                    Text(language.text("Token 分布", "Token Distribution"))
                        .font(.subheadline.bold())
                    TokenSplitBar(tokens: TokenBreakdown(
                        inputTokens: item.uncachedInputTokens + item.cachedInputTokens,
                        cachedInputTokens: item.cachedInputTokens,
                        outputTokens: item.outputTokens,
                        reasoningOutputTokens: 0,
                        totalTokens: item.tokens
                    ))
                    .frame(height: 12)

                    HStack(spacing: 16) {
                        LegendItem(color: uncachedInputColor, text: language.text("未缓存", "Uncached"))
                        LegendItem(color: cachedInputColor, text: language.text("缓存", "Cached"))
                        LegendItem(color: WidgetPalette.statusSuccess, text: language.text("输出", "Output"))
                    }
                    .font(.caption)
                }
            }
        }
        .padding(20)
        .frame(width: 320)
    }
}

struct DetailMetricCard: View {
    let title: String
    let value: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.headline.monospacedDigit())
                .foregroundStyle(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .cardBackground(cornerRadius: 8)
    }
}

struct LegendItem: View {
    let color: Color
    let text: String

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(text)
        }
    }
}

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

struct QuotaValueProgressBar: View {
    let currentValue: Double
    let maxValue: Double
    let accent: Color
    let currency: ModelTokenPrice.Currency

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let progressWidth = valueOffset(currentValue, width: width)

            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(WidgetPalette.surfaceTrack)
                    .frame(height: 10)
                    .frame(maxHeight: .infinity, alignment: .center)

                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(accent)
                    .frame(width: currentValue > 0 ? max(5, progressWidth) : 0, height: 10)
                    .frame(maxHeight: .infinity, alignment: .center)

                ForEach(subscriptionMilestones) { milestone in
                    let x = valueOffset(milestone.amountUSD, width: width)
                    Circle()
                        .fill(milestone.color)
                        .frame(width: 7, height: 7)
                        .overlay(
                            Circle()
                                .strokeBorder(Color.white.opacity(0.72), lineWidth: 1)
                        )
                        .offset(x: x - 3.5)
                        .frame(maxHeight: .infinity, alignment: .center)
                        .help("\(milestone.title) \(formatUSD(milestone.amountUSD, currency: currency))")
                }
            }
        }
    }

    private func valueOffset(_ amount: Double, width: CGFloat) -> CGFloat {
        guard maxValue > 0 else { return 0 }
        let subscriptionCeiling = subscriptionMilestones.map(\.amountUSD).max() ?? 200
        let subscriptionBand = 0.28
        let clamped = max(0, min(amount, maxValue))

        let fraction: Double
        if clamped <= subscriptionCeiling {
            fraction = subscriptionBand * (clamped / subscriptionCeiling)
        } else {
            let remainingValue = max(maxValue - subscriptionCeiling, 1)
            fraction = subscriptionBand + (1 - subscriptionBand) * ((clamped - subscriptionCeiling) / remainingValue)
        }

        let raw = width * CGFloat(max(0, min(1, fraction)))
        return min(max(raw, 0), width)
    }
}

struct TokenMetricCard: View {
    let title: String
    let value: String
    let tint: Color
    let language: WidgetLanguage

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle()
                    .fill(tint)
                    .frame(width: 7, height: 7)
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Text(value)
                .font(.system(size: 21, weight: .bold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.72)
            Text(language.text("Tokens", "Tokens"))
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 78, alignment: .leading)
        .cardBackground(cornerRadius: 10)
    }
}

struct MiniTrendCard: View {
    let buckets: [DailyTokenBucket]
    let language: WidgetLanguage

    private var maxTokens: Int64 {
        max(buckets.map(\.tokens).max() ?? 0, 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(language.text("近 7 天使用趋势", "7-day trend"))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            HStack(alignment: .bottom, spacing: 6) {
                ForEach(buckets) { bucket in
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(bucket.tokens == 0 ? WidgetPalette.dataZero : WidgetPalette.brandPrimary.opacity(bucket.label == "今天" ? 1 : 0.55))
                        .frame(width: 12, height: miniBarHeight(bucket.tokens))
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)

            HStack {
                Text(language.text("一", "M"))
                Spacer()
                Text(language.text("三", "W"))
                Spacer()
                Text(language.text("五", "F"))
                Spacer()
                Text(language.text("今", "Now"))
            }
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(.secondary)
        }
        .padding(10)
        .frame(width: 132, alignment: .leading)
        .frame(minHeight: 78, alignment: .leading)
        .cardBackground(cornerRadius: 10)
    }

    private func miniBarHeight(_ tokens: Int64) -> CGFloat {
        let ratio = Double(tokens) / Double(maxTokens)
        return max(6, CGFloat(ratio) * 34)
    }
}

struct TaskBoardColumnView: View {
    let column: TaskColumn
    let language: WidgetLanguage

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: taskColumnIcon(column.id))
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(taskAccentColor(column.id))
                Text(localizedTaskColumnTitle(column.id, language: language))
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                Text("\(column.count)")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Image(systemName: "ellipsis")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }

            if column.items.isEmpty {
                VStack(spacing: 5) {
                    Image(systemName: "circle.dashed")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.tertiary)
                    Text(language.text("暂无", "No items"))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 66)
            } else {
                ForEach(column.items) { item in
                    TaskIssueCard(item: item, language: language)
                }
                if column.count > column.items.count {
                    Text(language.text("+ \(column.count - column.items.count) 项", "+ \(column.count - column.items.count) more"))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                        .padding(.leading, 6)
                }
            }
        }
        .padding(8)
        .frame(minHeight: 274, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(taskColumnFill(column.id))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(taskAccentColor(column.id).opacity(0.12), lineWidth: 0.8)
                )
        )
    }
}

struct TaskIssueCard: View {
    let item: TaskItem
    let language: WidgetLanguage

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(item.code)
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                if let updatedAt = item.updatedAt {
                    Text(relativeTimeText(updatedAt, language: language))
                        .font(.system(size: 8, weight: .medium))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }

            Text(item.title)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .minimumScaleFactor(0.9)

            if !item.detail.isEmpty {
                Text(localizedTaskDetail(item.detail, language: language))
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            HStack(spacing: 5) {
                TaskChip(text: item.chip, kind: item.kind)
                Spacer(minLength: 4)
                TaskAvatar(text: taskAvatarText(item), kind: item.kind)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground(cornerRadius: 8, elevated: true)
    }
}

struct TaskAvatar: View {
    let text: String
    let kind: TaskColumnKind

    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .bold, design: .rounded))
            .foregroundStyle(taskAccentColor(kind).opacity(0.85))
            .frame(width: 18, height: 18)
            .background(
                Circle()
                    .fill(taskAccentColor(kind).opacity(0.13))
            )
    }
}

struct TaskChip: View {
    let text: String
    let kind: TaskColumnKind

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: chipIcon)
                .font(.system(size: 8, weight: .bold))
            Text(text)
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .lineLimit(1)
        }
        .foregroundStyle(chipColor)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(
            Capsule(style: .continuous)
                .fill(chipColor.opacity(0.13))
        )
    }

    private var chipColor: Color {
        switch text.lowercased() {
        case "high", "urgent":
            return WidgetPalette.statusDanger
        case "medium":
            return WidgetPalette.statusWarning
        case "active":
            return WidgetPalette.statusWarning
        case "cron", "wake":
            return WidgetPalette.brandSecondary
        case "done":
            return WidgetPalette.statusSuccess
        default:
            return taskAccentColor(kind)
        }
    }

    private var chipIcon: String {
        switch text.lowercased() {
        case "cron", "wake":
            return "clock.fill"
        case "done":
            return "checkmark.circle.fill"
        default:
            return "chart.bar.fill"
        }
    }
}

struct InfoChip: View {
    let title: String
    let value: String

    var body: some View {
        HStack(spacing: 5) {
            Text(title)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .monospacedDigit()
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(WidgetPalette.surfaceTrack)
        )
    }
}

struct MetricTile: View {
    let title: String
    let value: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Circle()
                    .fill(tint)
                    .frame(width: 6, height: 6)
                Text(title)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            Text(value)
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(WidgetPalette.surfaceTrack)
        )
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

enum WidgetPalette {
    static let brandPrimaryRGB = RingRGBColor(red: 0.157, green: 0.400, blue: 0.969) // #2866F7
    static let brandPrimaryStrongRGB = RingRGBColor(red: 0.122, green: 0.349, blue: 0.929) // #1F59ED
    static let brandPrimaryLightRGB = RingRGBColor(red: 0.482, green: 0.627, blue: 1.000) // #7BA0FF
    static let brandSecondaryRGB = RingRGBColor(red: 0.545, green: 0.427, blue: 1.000) // #8B6DFF
    static let brandHighlightRGB = RingRGBColor(red: 0.855, green: 0.639, blue: 0.980) // #DAA3FA

    static let brandPrimary = brandPrimaryRGB.color
    static let brandPrimaryStrong = brandPrimaryStrongRGB.color
    static let brandPrimaryLight = brandPrimaryLightRGB.color
    static let brandSecondary = brandSecondaryRGB.color
    static let brandHighlight = brandHighlightRGB.color

    static let statusSuccess = Color(red: 0.188, green: 0.820, blue: 0.345) // #30D158
    static let statusInfo = Color(red: 0.039, green: 0.518, blue: 1.000) // #0A84FF
    static let statusWarning = Color(red: 1.000, green: 0.624, blue: 0.039) // #FF9F0A
    static let statusDanger = Color(red: 1.000, green: 0.271, blue: 0.227) // #FF453A
    static let statusNeutral = Color(red: 0.596, green: 0.596, blue: 0.616) // #98989D
    static let dataReasoning = Color(red: 0.749, green: 0.353, blue: 0.949) // #BF5AF2

    static let surfaceTrack = Color.primary.opacity(0.10)
    static let dataZero = statusNeutral.opacity(0.35)

    static func windowTint(_ colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? Color.white.opacity(0.028) : Color.white.opacity(0.050)
    }

    static func sectionTint(_ colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? Color.white.opacity(0.040) : Color.white.opacity(0.070)
    }

    static func sectionFill(_ colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? Color.white.opacity(0.070) : Color.white.opacity(0.460)
    }

    static func sectionStroke(_ colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? Color.white.opacity(0.080) : Color.black.opacity(0.060)
    }

    static func cardFill(_ colorScheme: ColorScheme, elevated: Bool = false) -> Color {
        if colorScheme == .dark {
            return Color.white.opacity(elevated ? 0.140 : 0.100)
        }
        return Color.white.opacity(elevated ? 0.760 : 0.560)
    }

    static func cardStroke(_ colorScheme: ColorScheme, elevated: Bool = false) -> Color {
        if colorScheme == .dark {
            return Color.white.opacity(elevated ? 0.110 : 0.080)
        }
        return Color.black.opacity(elevated ? 0.075 : 0.055)
    }

    static func controlFill(_ colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? Color.white.opacity(0.085) : Color.white.opacity(0.520)
    }

    static func controlStroke(_ colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? Color.white.opacity(0.070) : Color.black.opacity(0.050)
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

// MARK: - Settings View

enum SettingsTab: String, CaseIterable, Identifiable {
    case general
    case data
    case currency
    case pricing

    var id: String { rawValue }

    func label(_ lang: WidgetLanguage) -> String {
        switch self {
        case .general: return lang == .zh ? "通用" : "General"
        case .data: return lang == .zh ? "数据" : "Data"
        case .currency: return lang == .zh ? "货币" : "Currency"
        case .pricing: return lang == .zh ? "模型定价" : "Model Pricing"
        }
    }

    func icon(_ lang: WidgetLanguage) -> String {
        switch self {
        case .general: return "gearshape"
        case .data: return "internaldrive"
        case .currency: return "yensign.circle"
        case .pricing: return "dollarsign.circle"
        }
    }
}

struct EditablePriceRow: Identifiable {
    let id: String
    var model: String
    var input: String
    var cached: String
    var output: String
    var currency: ModelTokenPrice.Currency
    var isNew: Bool

    init(model: String, input: Double, cached: Double, output: Double, currency: ModelTokenPrice.Currency, isNew: Bool = false) {
        self.id = model
        self.model = model
        self.input = Self.fmt(input)
        self.cached = Self.fmt(cached)
        self.output = Self.fmt(output)
        self.currency = currency
        self.isNew = isNew
    }

    func toPrice() -> ModelTokenPrice? {
        guard !model.isEmpty,
              let i = Double(input), let c = Double(cached), let o = Double(output) else { return nil }
        return ModelTokenPrice(model: model, inputPerMillion: i, cachedInputPerMillion: c, outputPerMillion: o, currency: currency)
    }

    private static func fmt(_ v: Double) -> String {
        v == Double(Int(v)) ? "\(Int(v))" : String(format: "%.3g", v)
    }
}

struct SettingsView: View {
    @ObservedObject var store: UsageStore
    @State private var language: WidgetLanguage
    @State private var themeMode: WidgetThemeMode
    @State private var provider: UsageProvider
    @State private var refreshInterval: Double
    @State private var rows: [EditablePriceRow]
    @State private var selectedTab: SettingsTab = .general
    @State private var scanning = false
    @State private var exchangeRate: Double
    @State private var displayCurrency: ModelTokenPrice.Currency
    @Environment(\.colorScheme) private var colorScheme
    let languageChanged: () -> Void
    let themeChanged: () -> Void

    init(store: UsageStore, languageChanged: @escaping () -> Void, themeChanged: @escaping () -> Void) {
        self.store = store
        self.languageChanged = languageChanged
        self.themeChanged = themeChanged
        _language = State(initialValue: WidgetLanguage.storedOrAutomatic())
        _themeMode = State(initialValue: WidgetThemeMode.storedOrAutomatic())
        _provider = State(initialValue: UsageProvider.stored())
        let storedInterval = AgentDeskDatabase.shared.double(forKey: "AgentDesk.refreshInterval")
        _refreshInterval = State(initialValue: storedInterval > 0 ? storedInterval : 30)
        _rows = State(initialValue: Self.loadRows())
        _exchangeRate = State(initialValue: loadExchangeRate())
        _displayCurrency = State(initialValue: loadDisplayCurrency())
    }

    var body: some View {
        Group {
            if #available(macOS 26.0, *) {
                GlassEffectContainer(spacing: 10) {
                    settingsShell
                        .glassEffect(
                            .regular.tint(WidgetPalette.windowTint(effectiveColorScheme)),
                            in: .rect(cornerRadius: 20, style: .continuous)
                        )
                }
            } else {
                settingsShell
            }
        }
        .environment(\.colorScheme, effectiveColorScheme)
        .preferredColorScheme(themeMode.preferredColorScheme)
        .onAppear {
            themeMode.applyAppearance()
            reloadSettingsPreferences()
        }
        .frame(minWidth: 600, idealWidth: 720, minHeight: 440)
    }

    private var effectiveColorScheme: ColorScheme {
        themeMode.preferredColorScheme ?? colorScheme
    }

    private var settingsShell: some View {
        VStack(alignment: .leading, spacing: 12) {
            settingsHeader

            HStack(alignment: .top, spacing: 12) {
                sidebar
                    .frame(width: 176)
                content
                    .frame(maxWidth: .infinity, minHeight: 460, alignment: .topLeading)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 14)
    }

    private var settingsHeader: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(localizedText("软件设置", "Settings"))
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                Text(localizedText("调整看板、状态栏与数据展示的全局偏好。", "Adjust global preferences for the dashboard, status item, and data display."))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            HStack(spacing: 8) {
                statusPill(localizedText("数据源 \(provider.shortLabel)", "Source \(provider.shortLabel)"))
                statusPill(themeMode == .system ? localizedText("外观 自动", "Appearance System") : themeMode == .light ? localizedText("外观 浅色", "Appearance Light") : localizedText("外观 深色", "Appearance Dark"))
                statusPill(language == .zh ? "中文" : "English")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
        .sectionBackground()
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            StudioPanelHeader(
                title: localizedText("设置导航", "Settings"),
                detail: localizedText("全局应用偏好", "Global app preferences")
            )
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 8)

            ForEach(SettingsTab.allCases) { tab in
                Button { selectedTab = tab } label: {
                    HStack(spacing: 8) {
                        Image(systemName: tab.icon(language))
                            .frame(width: 16)
                            .foregroundStyle(selectedTab == tab ? WidgetPalette.brandPrimary : .secondary)
                        Text(tab.label(language))
                            .font(.system(size: 12, weight: selectedTab == tab ? .semibold : .medium))
                            .foregroundStyle(.primary)
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .cardBackground(cornerRadius: 10, elevated: selectedTab == tab)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(selectedTab == tab ? WidgetPalette.brandPrimary.opacity(0.75) : Color.clear, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
            }
            Spacer()
        }
        .padding(.vertical, 8)
        .sectionBackground()
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch selectedTab {
        case .general: generalTab
        case .data: dataTab
        case .currency: currencyTab
        case .pricing: pricingTab
        }
    }

    private var generalTab: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 12) {
                settingsSection(
                    title: localizedText("界面偏好", "Interface Preferences"),
                    detail: localizedText("语言与主题会立即作用于整个应用。", "Language and appearance changes apply across the app immediately.")
                ) {
                    HStack(alignment: .top, spacing: 10) {
                        settingsOptionCard(
                            title: localizedText("界面语言", "Interface Language"),
                            detail: localizedText("看板、状态栏、窗口标题同步切换", "Dashboard, menu bar, and window titles switch together")
                        ) {
                            LanguageSwitch(language: language) { selectedLanguage in
                                language = selectedLanguage
                                selectedLanguage.persist()
                                languageChanged()
                                postPreferencesDidChange()
                            }
                        }

                        settingsOptionCard(
                            title: localizedText("外观模式", "Appearance"),
                            detail: localizedText("跟随系统或固定浅色 / 深色", "Follow system or pin light / dark mode")
                        ) {
                            ThemeSwitch(themeMode: themeMode, language: language) { selectedMode in
                                themeMode = selectedMode
                                selectedMode.persist()
                                selectedMode.applyAppearance()
                                themeChanged()
                                postPreferencesDidChange()
                            }
                        }
                    }
                }

                settingsSection(
                    title: localizedText("当前状态", "Current State"),
                    detail: localizedText("快速确认全局设置是否生效。", "Quickly confirm the current app-wide state.")
                ) {
                    HStack(spacing: 10) {
                        PromptSummaryStatRow(
                            title: localizedText("语言", "Language"),
                            value: language == .zh ? "中文" : "English",
                            detail: localizedText("全局显示语言", "App-wide display language")
                        )
                        PromptSummaryStatRow(
                            title: localizedText("外观", "Appearance"),
                            value: modeLabel(themeMode),
                            detail: localizedText("当前界面模式", "Current interface mode")
                        )
                        PromptSummaryStatRow(
                            title: localizedText("设置分类", "Sections"),
                            value: "\(SettingsTab.allCases.count)",
                            detail: localizedText("可调整的全局能力", "Global capabilities you can tune")
                        )
                    }
                }
            }
            .padding(.bottom, 2)
        }
    }

    private var dataTab: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 12) {
                settingsSection(
                    title: localizedText("数据与刷新", "Data & Refresh"),
                    detail: localizedText("设置默认数据源以及自动刷新节奏。", "Configure the default provider and refresh cadence.")
                ) {
                    VStack(alignment: .leading, spacing: 10) {
                        settingsFieldRow(
                            title: localizedText("默认数据源", "Default Source"),
                            detail: localizedText("启动时优先展示的数据来源", "Preferred source shown when the app starts")
                        ) {
                            Picker("", selection: $provider) {
                                ForEach(UsageProvider.allCases, id: \.self) { p in
                                    Text(p.displayName).tag(p)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.segmented)
                            .onChange(of: provider) { _, v in
                                v.persist()
                                postPreferencesDidChange()
                            }
                        }

                        settingsFieldRow(
                            title: localizedText("刷新间隔", "Refresh Interval"),
                            detail: localizedText("控制后台自动拉取统计的频率", "Controls how often background stats refresh")
                        ) {
                            HStack(spacing: 8) {
                                TextField("", value: $refreshInterval, format: .number)
                                    .frame(width: 72)
                                    .textFieldStyle(.roundedBorder)
                                    .onChange(of: refreshInterval) { _, val in
                                        let clamped = max(5, min(300, val))
                                        refreshInterval = clamped
                                        AgentDeskDatabase.shared.set(clamped, forKey: "AgentDesk.refreshInterval")
                                        postPreferencesDidChange()
                                    }
                                Text(localizedText("秒", "sec"))
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                settingsSection(
                    title: localizedText("数据概况", "Data Snapshot"),
                    detail: localizedText("这里展示当前设置会影响到的统计上下文。", "These values reflect the current data context affected by the settings.")
                ) {
                    HStack(spacing: 10) {
                        PromptSummaryStatRow(
                            title: localizedText("默认源", "Default"),
                            value: provider.shortLabel,
                            detail: localizedText("已写入本地偏好", "Stored in local preferences")
                        )
                        PromptSummaryStatRow(
                            title: localizedText("刷新间隔", "Interval"),
                            value: "\(Int(refreshInterval))s",
                            detail: localizedText("自动更新频率", "Auto refresh cadence")
                        )
                        PromptSummaryStatRow(
                            title: localizedText("发现能力", "Discovery"),
                            value: localizedText("自动", "Auto"),
                            detail: localizedText("看板内可手动重发现", "Manual rediscovery is available in the dashboard")
                        )
                    }
                }
            }
            .padding(.bottom, 2)
        }
    }

    // MARK: - Currency Tab

    private var currencyTab: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 12) {
                settingsSection(
                    title: localizedText("货币与汇率", "Currency & FX"),
                    detail: localizedText("统一控制总览费用的显示方式。", "Control how cost values are displayed across the app.")
                ) {
                    VStack(alignment: .leading, spacing: 10) {
                        settingsFieldRow(
                            title: localizedText("总览货币", "Display Currency"),
                            detail: localizedText("看板和详情里的成本展示币种", "Currency used for dashboard and detail costs")
                        ) {
                            Picker("", selection: $displayCurrency) {
                                Text("¥ CNY").tag(ModelTokenPrice.Currency.cny)
                                Text("$ USD").tag(ModelTokenPrice.Currency.usd)
                            }
                            .labelsHidden()
                            .pickerStyle(.segmented)
                            .frame(width: 160)
                            .onChange(of: displayCurrency) { _, v in
                                saveDisplayCurrency(v)
                                postPreferencesDidChange()
                            }
                        }

                        settingsFieldRow(
                            title: localizedText("汇率", "Exchange Rate"),
                            detail: localizedText("用于 USD / CNY 的展示换算", "Used for USD/CNY display conversion")
                        ) {
                            HStack(spacing: 8) {
                                Text("1 USD =")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(.secondary)
                                TextField("", value: $exchangeRate, format: .number)
                                    .frame(width: 80)
                                    .textFieldStyle(.roundedBorder)
                                    .onChange(of: exchangeRate) { _, val in
                                        let clamped = max(0.01, min(100, val))
                                        exchangeRate = clamped
                                        saveExchangeRate(clamped)
                                        postPreferencesDidChange()
                                    }
                                Text("CNY")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                settingsSection(
                    title: localizedText("换算预览", "Conversion Preview"),
                    detail: localizedText("确认汇率调整后的展示结果。", "Preview how values will be presented after the FX adjustment.")
                ) {
                    HStack(spacing: 10) {
                        conversionPreviewRow("¥100", converted: "≈ $\(String(format: "%.2f", 100 / exchangeRate))")
                        conversionPreviewRow("$100", converted: "≈ ¥\(String(format: "%.2f", 100 * exchangeRate))")
                    }
                }
            }
            .padding(.bottom, 2)
        }
    }

    private func conversionPreviewRow(_ input: String, converted: String) -> some View {
        VStack(spacing: 2) {
            Text(input)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
            Text(converted)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(WidgetPalette.controlFill(colorScheme))
        )
    }

    // MARK: - Pricing Tab (Editable Table)

    private var pricingTab: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 12) {
                settingsSection(
                    title: localizedText("模型定价", "Model Pricing"),
                    detail: localizedText("维护不同模型的输入、缓存和输出价格。", "Maintain input, cached, and output rates for each model.")
                ) {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 12) {
                            Button {
                                scanning = true
                                let scanned = Self.scanUsedModels()
                                var existing = Set(rows.map { $0.model.lowercased() })
                                for model in scanned where !existing.contains(model.lowercased()) {
                                    rows.append(EditablePriceRow(model: model, input: 0, cached: 0, output: 0, currency: language == .zh ? .cny : .usd, isNew: true))
                                    existing.insert(model.lowercased())
                                }
                                saveAll()
                                scanning = false
                            } label: {
                                if scanning {
                                    ProgressView().controlSize(.mini)
                                } else {
                                    Label(localizedText("扫描已用模型", "Scan Used"), systemImage: "arrow.clockwise")
                                        .font(.system(size: 11, weight: .medium))
                                }
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(WidgetPalette.brandPrimary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .cardBackground(cornerRadius: 8)
                            .disabled(scanning)

                            Button {
                                rows = Self.loadDefaultRows()
                                saveAll()
                            } label: {
                                Label(localizedText("恢复默认", "Reset"), systemImage: "arrow.counterclockwise")
                                    .font(.system(size: 11, weight: .medium))
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .cardBackground(cornerRadius: 8)

                            Spacer()

                            Button {
                                rows.append(EditablePriceRow(model: "", input: 0, cached: 0, output: 0, currency: language == .zh ? .cny : .usd, isNew: true))
                            } label: {
                                Label(localizedText("添加行", "Add Row"), systemImage: "plus")
                                    .font(.system(size: 11, weight: .medium))
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(WidgetPalette.brandPrimary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .cardBackground(cornerRadius: 8)
                        }
                        .padding(.horizontal, 14)
                        .padding(.top, 14)
                        .padding(.bottom, 10)

                        ScrollView(.horizontal, showsIndicators: false) {
                            VStack(alignment: .leading, spacing: 0) {
                                HStack(spacing: 0) {
                                    tableHeaderCell(localizedText("模型", "Model"), width: PricingTableMetrics.modelWidth)
                                    tableHeaderCell(localizedText("输入/M", "Input/M"), width: PricingTableMetrics.amountWidth)
                                    tableHeaderCell(localizedText("缓存/M", "Cached/M"), width: PricingTableMetrics.amountWidth)
                                    tableHeaderCell(localizedText("输出/M", "Output/M"), width: PricingTableMetrics.amountWidth)
                                    tableHeaderCell(localizedText("币种", "FX"), width: PricingTableMetrics.currencyWidth, alignment: .center)
                                    tableHeaderCell("", width: PricingTableMetrics.actionWidth, alignment: .center)
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                                .background(WidgetPalette.surfaceTrack)

                                LazyVStack(spacing: 0) {
                                    ForEach(Array(rows.enumerated()), id: \.offset) { index, _ in
                                        editableRow(index: index)
                                        if index < rows.count - 1 {
                                            Divider().padding(.leading, 16)
                                        }
                                    }
                                }
                            }
                            .frame(width: PricingTableMetrics.totalWidth + 32, alignment: .leading)
                        }
                    }
                    .cardBackground(cornerRadius: 12, elevated: true)
                }
            }
            .padding(.bottom, 2)
        }
    }

    private func settingsSection<Content: View>(
        title: String,
        detail: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            StudioPanelHeader(title: title, detail: detail)
            content()
        }
        .padding(12)
        .sectionBackground()
    }

    private func settingsFieldRow<Content: View>(
        title: String,
        detail: String,
        @ViewBuilder control: () -> Content
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                Text(detail)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 10)
            control()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .cardBackground(cornerRadius: 10)
    }

    private func settingsOptionCard<Content: View>(
        title: String,
        detail: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
            Text(detail)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
            content()
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground(cornerRadius: 10)
    }

    private func reloadSettingsPreferences() {
        language = WidgetLanguage.storedOrAutomatic()
        themeMode = WidgetThemeMode.storedOrAutomatic()
        provider = UsageProvider.stored()
        let storedInterval = AgentDeskDatabase.shared.double(forKey: "AgentDesk.refreshInterval")
        refreshInterval = storedInterval > 0 ? storedInterval : 30
        exchangeRate = loadExchangeRate()
        displayCurrency = loadDisplayCurrency()
    }

    private func statusPill(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background {
                Capsule(style: .continuous)
                    .fill(WidgetPalette.controlFill(effectiveColorScheme))
                    .overlay {
                        Capsule(style: .continuous)
                            .strokeBorder(WidgetPalette.controlStroke(effectiveColorScheme), lineWidth: 0.8)
                    }
            }
    }

    private func tableHeaderCell(_ title: String, width: CGFloat, alignment: Alignment = .leading) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: width, alignment: alignment)
    }

    private func editableRow(index: Int) -> some View {
        let cur = rows[index].currency
        let modelName = rows[index].model.trimmingCharacters(in: .whitespacesAndNewlines)
        let providerName = providerLabel(for: modelName)
        return HStack(spacing: 0) {
            pricingModelCell(
                binding: Binding(get: { rows[index].model }, set: { rows[index].model = $0 }),
                width: PricingTableMetrics.modelWidth,
                provider: providerName,
                isEditable: rows[index].isNew
            )

            editablePriceField(binding: Binding(get: { rows[index].input }, set: { rows[index].input = $0 }), currency: cur, width: PricingTableMetrics.amountWidth)
            editablePriceField(binding: Binding(get: { rows[index].cached }, set: { rows[index].cached = $0 }), currency: cur, width: PricingTableMetrics.amountWidth)
            editablePriceField(binding: Binding(get: { rows[index].output }, set: { rows[index].output = $0 }), currency: cur, width: PricingTableMetrics.amountWidth)

            currencyToggle(binding: Binding(get: { rows[index].currency }, set: { rows[index].currency = $0 }))
                .frame(width: PricingTableMetrics.currencyWidth, alignment: .center)

            Button {
                rows.remove(at: index)
                saveAll()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.red.opacity(0.5))
            }
            .buttonStyle(.plain)
            .frame(width: PricingTableMetrics.actionWidth, alignment: .center)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 3)
        .onChange(of: rows[index].input) { _, _ in saveAll() }
        .onChange(of: rows[index].cached) { _, _ in saveAll() }
        .onChange(of: rows[index].output) { _, _ in saveAll() }
        .onChange(of: rows[index].currency) { _, _ in saveAll() }
        .onChange(of: rows[index].model) { _, _ in saveAll() }
    }

    private func providerLabel(for modelName: String) -> String {
        guard !modelName.isEmpty else { return "" }
        let matchedProviders = providersFromCurrentSnapshot(for: modelName)
        if !matchedProviders.isEmpty {
            return matchedProviders.joined(separator: " / ")
        }
        return modelProvider(from: modelName)
    }

    private func providersFromCurrentSnapshot(for modelName: String) -> [String] {
        guard let local = store.snapshot.local else { return [] }
        let normalizedTarget = modelName.lowercased()
        let allItems = local.todayModelUsage
            + local.twentyFourHourModelUsage
            + local.sevenDayModelUsage
            + local.thirtyDayModelUsage
            + local.lifetimeModelUsage

        let providers = Set(
            allItems.compactMap { item -> String? in
                guard item.model.lowercased() == normalizedTarget else { return nil }
                let provider = item.provider.trimmingCharacters(in: .whitespacesAndNewlines)
                return provider.isEmpty ? nil : provider
            }
        )

        return providers.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private func pricingModelCell(
        binding: Binding<String>,
        width: CGFloat,
        provider: String,
        isEditable: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if isEditable {
                TextField("", text: binding, prompt: Text("model").foregroundStyle(.tertiary))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .textFieldStyle(.plain)
                    .foregroundStyle(.primary)
            } else {
                Text(binding.wrappedValue)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }

            if !provider.isEmpty {
                Text(provider)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 8)
        .frame(width: width, alignment: .leading)
        .frame(minHeight: PricingTableMetrics.rowHeight, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(WidgetPalette.controlFill(colorScheme))
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(WidgetPalette.controlStroke(colorScheme), lineWidth: 0.6)
                )
        )
    }

    private func editablePriceField(binding: Binding<String>, currency: ModelTokenPrice.Currency, width: CGFloat) -> some View {
        HStack(spacing: 0) {
            Text(currency.rawValue)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(currencyColor(currency))
                .frame(width: 12)
            TextField("0", text: binding)
                .font(.system(size: 11, design: .monospaced))
                .textFieldStyle(.plain)
        }
        .padding(.horizontal, 6)
        .frame(width: width, height: PricingTableMetrics.rowHeight, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(WidgetPalette.controlFill(colorScheme))
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(WidgetPalette.controlStroke(colorScheme), lineWidth: 0.6)
                )
        )
    }

    private func currencyToggle(binding: Binding<ModelTokenPrice.Currency>) -> some View {
        Button {
            binding.wrappedValue = binding.wrappedValue == .cny ? .usd : .cny
        } label: {
            Text(binding.wrappedValue == .cny ? "¥" : "$")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(currencyColor(binding.wrappedValue))
                .frame(width: 24, height: 20)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(WidgetPalette.controlFill(colorScheme))
                )
        }
        .buttonStyle(.plain)
        .help(localizedText("点击切换货币", "Click to toggle currency"))
    }

    // MARK: - Persistence & Scan

    private func saveAll() {
        var dict: [String: ModelTokenPrice] = [:]
        for row in rows {
            if let price = row.toPrice(), !row.model.isEmpty {
                dict[row.model.lowercased()] = price
            }
        }
        saveCustomModelPrices(dict)
    }

    static func loadRows() -> [EditablePriceRow] {
        let prices = loadCustomModelPrices()
        if prices.isEmpty { return loadDefaultRows() }
        return prices.values.map { p in
            EditablePriceRow(model: p.model, input: p.inputPerMillion, cached: p.cachedInputPerMillion, output: p.outputPerMillion, currency: p.currency)
        }.sorted { $0.model < $1.model }
    }

    static func loadDefaultRows() -> [EditablePriceRow] {
        let defaults: [(String, Double, Double, Double, ModelTokenPrice.Currency)] = [
            ("mimo", 2, 0.5, 8, .cny),
            ("mimo-v2.5", 2, 0.5, 8, .cny),
            ("mimo-auto", 2, 0.5, 8, .cny),
            ("mimo-v2.5-pro", 2, 0.5, 8, .cny),
            ("gpt-5.4", 2.5, 0.25, 15, .usd),
            ("gpt-5.4-mini", 0.75, 0.075, 4.5, .usd),
            ("gpt-5.3-codex", 1.75, 0.175, 14, .usd),
            ("qwen3.7-plus", 0.8, 0.2, 4, .cny),
            ("qwen3.7-max", 4, 1, 16, .cny),
            ("glm-5.2", 2, 0.5, 8, .cny),
            ("glm-5.1", 2, 0.5, 8, .cny),
            ("deepseek-v4-pro", 4, 1, 16, .cny),
        ]
        return defaults.map { EditablePriceRow(model: $0.0, input: $0.1, cached: $0.2, output: $0.3, currency: $0.4) }
    }

    static func scanUsedModels() -> [String] {
        let home = NSHomeDirectory()
        let dbPath = home + "/.local/share/mimocode/mimocode.db"
        guard FileManager.default.fileExists(atPath: dbPath) else { return [] }

        let sqlitePaths = ["/usr/bin/sqlite3", "/opt/homebrew/bin/sqlite3"]
        guard let sqlitePath = sqlitePaths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return [] }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: sqlitePath)
        process.arguments = ["-readonly", "-json", dbPath,
            "SELECT DISTINCT json_extract(data, '$.modelID') AS model FROM message WHERE json_extract(data, '$.tokens.total') IS NOT NULL AND json_extract(data, '$.modelID') IS NOT NULL;"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do { try process.run() } catch { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return arr.compactMap { $0["model"] as? String }.sorted()
    }

    // MARK: - Helpers

    private func localizedText(_ zh: String, _ en: String) -> String { language == .zh ? zh : en }

    private func modeLabel(_ mode: WidgetThemeMode) -> String {
        switch mode {
        case .system: return localizedText("跟随系统", "System")
        case .light: return localizedText("浅色", "Light")
        case .dark: return localizedText("深色", "Dark")
        }
    }
}

// FlowLayout - 自然换行布局
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = computeLayout(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = computeLayout(proposal: proposal, subviews: subviews)
        for (index, position) in result.positions.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y), proposal: .unspecified)
        }
    }

    private func computeLayout(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, positions: [CGPoint]) {
        let maxWidth = proposal.width ?? .infinity
        var positions: [CGPoint] = []
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var lineHeight: CGFloat = 0
        var totalHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX + size.width > maxWidth && currentX > 0 {
                currentX = 0
                currentY += lineHeight + spacing
                lineHeight = 0
            }
            positions.append(CGPoint(x: currentX, y: currentY))
            lineHeight = max(lineHeight, size.height)
            currentX += size.width + spacing
            totalHeight = currentY + lineHeight
        }

        return (CGSize(width: maxWidth, height: totalHeight), positions)
    }
}
