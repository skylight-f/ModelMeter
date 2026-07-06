import Foundation
import SwiftUI
import AppKit

// MARK: - Settings View

private struct PricingTableMetrics {
    static let modelWidth: CGFloat = 192
    static let amountWidth: CGFloat = 148
    static let currencyWidth: CGFloat = 40
    static let actionWidth: CGFloat = 28
    static let rowHeight: CGFloat = 34
    static let totalWidth: CGFloat = modelWidth + amountWidth * 3 + currencyWidth + actionWidth
}

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

        let query = "SELECT DISTINCT json_extract(data, '$.modelID') AS model FROM message WHERE json_extract(data, '$.tokens.total') IS NOT NULL AND json_extract(data, '$.modelID') IS NOT NULL;"
        let rows = NativeSQLite.queryRowsAny(dbPath: dbPath, sql: query)
        return rows.compactMap { $0["model"] as? String }.sorted()
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
