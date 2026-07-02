import Foundation
import SwiftUI
import AppKit

enum WidgetLanguage: String, CaseIterable, Equatable {
    case zh
    case en

    static let storageKey = "ModelMeter.interfaceLanguage"

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

    static func storedOrAutomatic(defaults: UserDefaults = .standard) -> WidgetLanguage {
        guard let rawValue = defaults.string(forKey: storageKey),
              let language = WidgetLanguage(rawValue: rawValue)
        else { return .automatic }
        return language
    }

    func persist(defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: Self.storageKey)
    }

    func text(_ zh: String, _ en: String) -> String {
        isChinese ? zh : en
    }
}

enum WidgetThemeMode: String, CaseIterable, Equatable {
    case system
    case light
    case dark

    static let storageKey = "ModelMeter.interfaceThemeMode"

    static func storedOrAutomatic(defaults: UserDefaults = .standard) -> WidgetThemeMode {
        guard let rawValue = defaults.string(forKey: storageKey),
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

    func persist(defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: Self.storageKey)
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
    @State private var selectedModelUsagePeriod: ModelUsagePeriod = .today

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
        }
    }

    private var widgetContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 12) {
                    if shouldShowEnvironmentChecklist {
                        environmentChecklistSection
                    }
                    usageOverviewSection
                    modelUsageCardSection
                    taskBoardSection
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

    private var header: some View {
        HStack(spacing: 10) {
            HStack(spacing: 9) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 34, height: 34)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .accessibilityHidden(true)
                Text("ModelMeter")
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
            }
            ThemeSwitch(themeMode: themeMode, language: language) { selectedMode in
                themeMode = selectedMode
                selectedMode.persist()
                selectedMode.applyAppearance()
            }
            LanguageSwitch(language: language) { selectedLanguage in
                language = selectedLanguage
                selectedLanguage.persist()
            }
            planPill
            iconButton(systemName: store.isRefreshing ? "hourglass" : "arrow.clockwise") {
                store.refresh()
            }
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
                HStack(spacing: 12) {
                    DetailedTokenMetricCard(
                        title: language.text("今日", "Today"),
                        systemName: "sun.max.fill",
                        usage: snapshot.local?.detailedUsage?.today,
                        fallbackTokens: snapshot.local?.todayTokens,
                        language: language
                    )
                    DetailedTokenMetricCard(
                        title: language.text("近 7 天", "Last 7 days"),
                        systemName: "calendar",
                        usage: snapshot.local?.detailedUsage?.sevenDay,
                        fallbackTokens: snapshot.local?.sevenDayTokens,
                        language: language
                    )
                    DetailedTokenMetricCard(
                        title: language.text("累计", "Lifetime"),
                        systemName: "sum",
                        usage: snapshot.local?.detailedUsage?.lifetime,
                        fallbackTokens: snapshot.local?.lifetimeTokens,
                        language: language
                    )
                }

                WoolProgressCard(usage: snapshot.local?.detailedUsage?.month, language: language)
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 16)
        .sectionBackground()
    }

    private var taskBoardSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(title: language.text("今日任务看板", "Today's task board"), detail: taskBoardSummary)
            HStack(alignment: .top, spacing: 8) {
                ForEach(taskBoardColumns) { column in
                    TaskBoardColumnView(column: column, language: language)
                        .frame(maxWidth: .infinity, alignment: .top)
                }
            }
        }
        .padding(12)
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
        guard let todayUsage = snapshot.local?.todayModelUsage, !todayUsage.isEmpty,
              let buckets = snapshot.local?.dailyBuckets, !buckets.isEmpty else {
            return AnyView(EmptyView())
        }

        // 使用七天的数据构建图例
        let sevenDayUsage = snapshot.local?.sevenDayModelUsage ?? []
        let allModels = Set(todayUsage.map(\.model)).union(sevenDayUsage.map(\.model))
        let modelBuckets = buildModelBuckets(from: todayUsage)
        let modelColors = buildModelColorsForModels(Array(allModels))

        return AnyView(
            VStack(alignment: .leading, spacing: 20) {
                Text(language.text("近 7 天用量趋势", "7-day usage trend"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)

                ModelDailyTokenChart(
                    modelBuckets: modelBuckets,
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

    private func buildModelBuckets(from models: [ModelUsageItem]) -> [String: [DailyTokenBucket]] {
        // 简化实现：使用今日总量按比例分配到各模型
        guard let dailyBuckets = snapshot.local?.dailyBuckets, !dailyBuckets.isEmpty else { return [:] }
        let totalToday = models.reduce(Int64(0)) { $0 + $1.tokens }
        guard totalToday > 0 else { return [:] }

        var result: [String: [DailyTokenBucket]] = [:]
        for model in models.prefix(5) {
            let ratio = Double(model.tokens) / Double(totalToday)
            result[model.model] = dailyBuckets.map { bucket in
                DailyTokenBucket(
                    id: bucket.id,
                    label: bucket.label,
                    tokens: Int64(Double(bucket.tokens) * ratio)
                )
            }
        }
        return result
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

    private var taskBoardSummary: String {
        guard let board = snapshot.taskBoard else { return language.text("读取中", "Loading") }
        return language.text(
            "\(board.totalCount) 事项 · \(timeOnly(board.refreshedAt, language: language))",
            "\(board.totalCount) items · \(timeOnly(board.refreshedAt, language: language))"
        )
    }

    private var taskBoardColumns: [TaskColumn] {
        snapshot.taskBoard?.columns ?? [
            TaskColumn(id: .active, title: localizedTaskColumnTitle(.active, language: language), count: 0, items: []),
            TaskColumn(id: .pending, title: localizedTaskColumnTitle(.pending, language: language), count: 0, items: []),
            TaskColumn(id: .scheduled, title: localizedTaskColumnTitle(.scheduled, language: language), count: 0, items: []),
            TaskColumn(id: .done, title: localizedTaskColumnTitle(.done, language: language), count: 0, items: [])
        ]
    }

    private var currentModelUsage: [ModelUsageItem] {
        switch selectedModelUsagePeriod {
        case .today:
            return snapshot.local?.todayModelUsage ?? []
        case .sevenDay:
            return snapshot.local?.sevenDayModelUsage ?? []
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
        if snapshot.provider == .mimocode {
            return (!snapshot.messages.isEmpty && snapshot.local == nil)
                || snapshot.local == nil
        }
        return (!snapshot.messages.isEmpty && (snapshot.primary == nil || snapshot.local == nil))
            || snapshot.account == nil
            || snapshot.local == nil
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
                Text(formatUSD(usage?.estimatedCostUSD))
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
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .frame(minWidth: hasPriceData ? 90 : 70, alignment: .leading)

            Spacer(minLength: 4)

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

            Text(formatUSD(item.estimatedCostUSD))
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.secondary)
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
                                .foregroundStyle(.secondary)
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
                    value: formatUSD(item.estimatedCostUSD),
                    color: .secondary
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
                Text(formatUSD(usage?.estimatedCostUSD))
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text("/ \(formatCompactUSD(maxValue))")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }

            QuotaValueProgressBar(
                currentValue: cost,
                maxValue: maxValue,
                accent: accent
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
                Text("\(language.text("满额", "Cap")) \(formatCompactUSD(maxValue))")
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
                        .help("\(milestone.title) \(formatUSD(milestone.amountUSD))")
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

