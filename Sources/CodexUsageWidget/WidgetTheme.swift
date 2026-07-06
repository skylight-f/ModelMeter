import Foundation
import SwiftUI
import AppKit

extension Notification.Name {
    static let modelMeterPreferencesDidChange = Notification.Name("AgentDesk.preferencesDidChange")
}

func postPreferencesDidChange() {
    NotificationCenter.default.post(name: .modelMeterPreferencesDidChange, object: nil)
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
