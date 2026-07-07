import SwiftUI

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

struct CompactTextFieldRow: View {
    let label: String
    @Binding var text: String
    var isMultiline: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
            if isMultiline {
                TextEditor(text: $text)
                    .font(.system(size: 10))
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 40, maxHeight: 80)
                    .padding(4)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(WidgetPalette.controlFill(.light))
                    )
            } else {
                TextField("", text: $text)
                    .font(.system(size: 10))
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(WidgetPalette.controlFill(.light))
                    )
            }
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
                Text(item.shortLabel(language: language)).tag(item)
            }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .controlSize(.mini)
        .frame(width: 122)
        .help(language.text("数据源：全部 / Codex / MimoCode", "Source: All / Codex / MimoCode"))
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
                        Text(localizedProviderName(provider, language: language))
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
                    Text(localizedProviderShortName(selected, language: language))
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

private func localizedProviderName(_ provider: DiscoveredProvider, language: WidgetLanguage) -> String {
    if let usageProvider = UsageProvider(rawValue: provider.id) {
        return usageProvider.displayName(language: language)
    }
    return provider.name
}

private func localizedProviderShortName(_ provider: DiscoveredProvider, language: WidgetLanguage) -> String {
    if let usageProvider = UsageProvider(rawValue: provider.id) {
        return usageProvider.shortLabel(language: language)
    }
    return provider.shortName
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
