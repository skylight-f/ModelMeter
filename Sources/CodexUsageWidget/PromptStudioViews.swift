import Foundation
import SwiftUI
import AppKit

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
                    Text(language.text("管理提示词资产、配置 Agent、导出到目标工具。", "Manage prompts, configure agents, export to target tools."))
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
                .help(language.text("刷新", "Refresh"))
            }

            HStack(alignment: .top, spacing: 12) {
                studioLeftPanel
                    .frame(width: 240)
                studioRightPanel
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .padding(16)
        .frame(minWidth: 980, minHeight: 640, alignment: .topLeading)
    }

    @State private var leftPanelTab: LeftPanelTab = .assets

    enum LeftPanelTab: String, CaseIterable {
        case assets
        case profiles
    }

    private var studioLeftPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                ForEach(LeftPanelTab.allCases, id: \.self) { tab in
                    Button {
                        leftPanelTab = tab
                    } label: {
                        Text(tab == .assets ? language.text("资产", "Assets") : language.text("Profile", "Profiles"))
                            .font(.system(size: 11, weight: leftPanelTab == tab ? .semibold : .medium))
                            .foregroundStyle(leftPanelTab == tab ? .primary : .secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(
                                leftPanelTab == tab ? WidgetPalette.brandPrimary.opacity(0.1) : Color.clear
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .background(WidgetPalette.surfaceTrack)

            if leftPanelTab == .assets {
                assetListPanel
            } else {
                profileListPanel
            }
        }
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .sectionBackground()
    }

    private var assetListPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            compactSearchField(
                placeholderZh: "搜索资产",
                placeholderEn: "Search assets",
                text: $promptSearchText,
                width: 216
            )

            HStack(spacing: 4) {
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
                    label: { mode in
                        language.text(mode == .recent ? "最近" : mode == .name ? "名称" : "路径",
                                     mode == .recent ? "Recent" : mode == .name ? "Name" : "Path")
                    }
                )
            }

            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 2) {
                    ForEach(filteredPromptAssets) { asset in
                        Button {
                            selectedPromptAssetID = asset.id
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: asset.kind == .skill ? "wrench" : asset.kind == .prompt ? "text.document" : "gearshape")
                                    .font(.system(size: 9))
                                    .foregroundStyle(.tertiary)
                                    .frame(width: 12)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(asset.name)
                                        .font(.system(size: 10, weight: .medium))
                                        .lineLimit(1)
                                        .foregroundStyle(.primary)
                                    Text(localizedPromptSource(asset.source, language: language))
                                        .font(.system(size: 8, weight: .medium))
                                        .foregroundStyle(.tertiary)
                                }
                                Spacer(minLength: 2)
                                if asset.id == selectedPromptAssetID {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 8, weight: .bold))
                                        .foregroundStyle(WidgetPalette.brandPrimary)
                                }
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(
                                asset.id == selectedPromptAssetID ? WidgetPalette.brandPrimary.opacity(0.08) : Color.clear
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Text("\(filteredPromptAssets.count) \(language.text("个资产", "assets"))")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
        }
        .padding(8)
    }

    private var profileListPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(language.text("Agent Profiles", "Agent Profiles"))
                    .font(.system(size: 11, weight: .semibold))
                Spacer(minLength: 4)
                Button {
                    let profile = AgentProfile.starter(name: "Profile \(store.agentProfiles.count + 1)")
                    store.agentProfiles.insert(profile, at: 0)
                    store.persistAgentProfiles()
                    selectedProfileID = profile.id
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(WidgetPalette.brandPrimary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 8)
            .padding(.top, 8)

            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 2) {
                    ForEach(store.agentProfiles) { profile in
                        Button {
                            selectedProfileID = profile.id
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "person.circle")
                                    .font(.system(size: 12))
                                    .foregroundStyle(WidgetPalette.brandSecondary)
                                    .frame(width: 16)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(profile.name)
                                        .font(.system(size: 10, weight: .medium))
                                        .lineLimit(1)
                                        .foregroundStyle(.primary)
                                    Text("\(profile.selectedAssetIDs.count) \(language.text("个资产", "assets"))")
                                        .font(.system(size: 8, weight: .medium))
                                        .foregroundStyle(.tertiary)
                                }
                                Spacer(minLength: 2)
                                if profile.id == selectedProfileID {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 8, weight: .bold))
                                        .foregroundStyle(WidgetPalette.brandPrimary)
                                }
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(
                                profile.id == selectedProfileID ? WidgetPalette.brandPrimary.opacity(0.08) : Color.clear
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Text("\(store.agentProfiles.count) \(language.text("个 Profile", "profiles"))")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
        }
        .padding(.bottom, 8)
    }

    private var studioRightPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            if leftPanelTab == .assets, let asset = effectiveSelectedPromptAsset {
                assetDetailSection(asset: asset)
            } else if leftPanelTab == .profiles, let profile = effectiveSelectedProfile {
                profileDetailSection(profile: profile)
                publishPreviewSection(profile: profile)
            } else {
                emptyStateView
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .sectionBackground()
    }

    private func assetDetailSection(asset: PromptAsset) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(asset.name)
                        .font(.system(size: 14, weight: .semibold))
                    HStack(spacing: 6) {
                        Text(localizedPromptSource(asset.source, language: language))
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.secondary)
                        Text("·")
                            .foregroundStyle(.tertiary)
                        Text(localizedPromptKind(asset.kind, language: language))
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.secondary)
                        if let modified = asset.modifiedAt {
                            Text("·")
                                .foregroundStyle(.tertiary)
                            Text(relativeTimeText(modified, language: language))
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                Spacer(minLength: 8)
                HStack(spacing: 6) {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(asset.content, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help(language.text("复制内容", "Copy content"))

                    Button {
                        NSWorkspace.shared.selectFile(asset.path, inFileViewerRootedAtPath: "")
                    } label: {
                        Image(systemName: "folder")
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help(language.text("在 Finder 中显示", "Reveal in Finder"))
                }
            }

            if !asset.summary.isEmpty {
                Text(asset.summary)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            ScrollView(.vertical, showsIndicators: false) {
                Text(asset.content)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(WidgetPalette.controlFill(.light))
                    )
            }
        }
    }

    private func profileDetailSection(profile: AgentProfile) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(profile.name)
                    .font(.system(size: 14, weight: .semibold))
                Spacer(minLength: 8)
                HStack(spacing: 6) {
                    Button {
                        let dup = AgentProfile.starter(name: "\(profile.name) Copy")
                        store.agentProfiles.insert(dup, at: 0)
                        store.persistAgentProfiles()
                        selectedProfileID = dup.id
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help(language.text("复制", "Duplicate"))

                    Button {
                        store.agentProfiles.removeAll { $0.id == profile.id }
                        store.persistAgentProfiles()
                        selectedProfileID = store.agentProfiles.first?.id
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.red.opacity(0.6))
                    .help(language.text("删除", "Delete"))
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                CompactTextFieldRow(
                    label: language.text("名称", "Name"),
                    text: Binding(
                        get: { profile.name },
                        set: { newVal in
                            if let idx = store.agentProfiles.firstIndex(where: { $0.id == profile.id }) {
                                store.agentProfiles[idx].name = newVal
                                store.persistAgentProfiles()
                            }
                        }
                    )
                )
                CompactTextFieldRow(
                    label: language.text("摘要", "Summary"),
                    text: Binding(
                        get: { profile.summary },
                        set: { newVal in
                            if let idx = store.agentProfiles.firstIndex(where: { $0.id == profile.id }) {
                                store.agentProfiles[idx].summary = newVal
                                store.persistAgentProfiles()
                            }
                        }
                    )
                )
                CompactTextFieldRow(
                    label: language.text("Persona", "Persona"),
                    text: Binding(
                        get: { profile.persona },
                        set: { newVal in
                            if let idx = store.agentProfiles.firstIndex(where: { $0.id == profile.id }) {
                                store.agentProfiles[idx].persona = newVal
                                store.persistAgentProfiles()
                            }
                        }
                    ),
                    isMultiline: true
                )
                CompactTextFieldRow(
                    label: language.text("工作风格", "Working Style"),
                    text: Binding(
                        get: { profile.workingStyle },
                        set: { newVal in
                            if let idx = store.agentProfiles.firstIndex(where: { $0.id == profile.id }) {
                                store.agentProfiles[idx].workingStyle = newVal
                                store.persistAgentProfiles()
                            }
                        }
                    ),
                    isMultiline: true
                )
            }
        }
    }

    @State private var selectedPublishTool: AgentTargetTool = .codex

    private func publishPreviewSection(profile: AgentProfile) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(language.text("发布预览", "Publish Preview"))
                    .font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 8)

                Picker("", selection: $selectedPublishTool) {
                    Text("Codex").tag(AgentTargetTool.codex)
                    Text("MimoCode").tag(AgentTargetTool.mimocode)
                }
                .pickerStyle(.segmented)
                .frame(width: 140)

                Button {
                    let content = renderAgentProfilePrompt(profile: profile, assets: store.promptRegistry.assets, tool: selectedPublishTool)
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(content, forType: .string)
                } label: {
                    Label(language.text("复制", "Copy"), systemImage: "doc.on.doc")
                        .font(.system(size: 10, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(WidgetPalette.brandPrimary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(WidgetPalette.brandPrimary.opacity(0.1))
                )

                Button {
                    exportProfile(profile: profile, tool: selectedPublishTool)
                } label: {
                    Label(language.text("一键发布", "Publish"), systemImage: "arrow.down.doc")
                        .font(.system(size: 10, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(WidgetPalette.statusSuccess)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(WidgetPalette.statusSuccess.opacity(0.1))
                )
            }

            if let msg = exportSuccessMessage {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(WidgetPalette.statusSuccess)
                    Text(msg)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(WidgetPalette.statusSuccess.opacity(0.08))
                )
            }

            HStack(spacing: 4) {
                Text(language.text("导出到:", "Export to:"))
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.tertiary)
                Text(suggestedExportPath(profile: profile, tool: selectedPublishTool))
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            ScrollView(.vertical, showsIndicators: false) {
                Text(renderAgentProfilePrompt(profile: profile, assets: store.promptRegistry.assets, tool: selectedPublishTool))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(WidgetPalette.controlFill(.light))
                    )
            }
            .frame(height: 150)
        }
    }

    @State private var exportSuccessMessage: String?

    private func exportProfile(profile: AgentProfile, tool: AgentTargetTool) {
        let content = renderAgentProfilePrompt(profile: profile, assets: store.promptRegistry.assets, tool: tool)
        let exportPath = suggestedExportPath(profile: profile, tool: tool)
        let url = URL(fileURLWithPath: exportPath)

        do {
            let dir = url.deletingLastPathComponent().path
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try content.write(to: url, atomically: true, encoding: .utf8)
            exportSuccessMessage = language.text("已保存到 \(exportPath)", "Saved to \(exportPath)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                exportSuccessMessage = nil
            }
        } catch {
            exportSuccessMessage = language.text("导出失败: \(error.localizedDescription)", "Export failed: \(error.localizedDescription)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                exportSuccessMessage = nil
            }
        }
    }

    private var emptyStateView: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text(language.text("选择左侧资产或 Profile 查看详情", "Select an asset or profile from the left to view details"))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sectionBackground()
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
