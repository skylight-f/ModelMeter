import Cocoa
import Carbon.HIToolbox
import SwiftUI

// MARK: - AppKit Helpers

final class DraggableHostingView<Content: View>: NSHostingView<Content> {
    override var mouseDownCanMoveWindow: Bool { true }
}

final class GlassHostingContainer<Content: View>: NSView {
    private let cornerRadius: CGFloat
    private let draggable: Bool

    init(rootView: Content, cornerRadius: CGFloat, draggable: Bool = true) {
        self.cornerRadius = cornerRadius
        self.draggable = draggable
        super.init(frame: .zero)

        wantsLayer = true
        layer?.cornerRadius = cornerRadius

        let host: NSView
        if draggable {
            let d = DraggableHostingView(rootView: rootView)
            d.frame = bounds
            d.autoresizingMask = [.width, .height]
            host = d
        } else {
            let h = NSHostingView(rootView: rootView)
            h.frame = bounds
            h.autoresizingMask = [.width, .height]
            host = h
        }

        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: bounds)
            glass.autoresizingMask = [.width, .height]
            glass.cornerRadius = cornerRadius
            glass.style = .clear
            glass.tintColor = nil
            glass.contentView = host
            addSubview(glass)
        } else {
            let material = NSVisualEffectView(frame: bounds)
            material.autoresizingMask = [.width, .height]
            material.material = .hudWindow
            material.blendingMode = .behindWindow
            material.state = .active
            material.wantsLayer = true
            material.layer?.cornerRadius = cornerRadius
            material.layer?.masksToBounds = true
            material.addSubview(host)
            addSubview(material)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var mouseDownCanMoveWindow: Bool { draggable }
}

final class DesktopWidgetWindow: NSPanel {
    private static let desktopLevel = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1)

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .resizable],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true
        isMovableByWindowBackground = true
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        level = Self.desktopLevel
        hidesOnDeactivate = false
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    func moveToDesktopLayer() {
        level = Self.desktopLevel
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        orderFrontRegardless()
    }

    func moveToFrontLayer() {
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - AppDelegate

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    static var shared: AppDelegate?
    private enum WindowStorageKey {
        static let settingsFrame = "AgentDesk.windowFrame.settings"
    }
    private let store = UsageStore()
    private var window: DesktopWidgetWindow?
    private var settingsWindow: NSWindow?
    private var statusItem: NSStatusItem?
    private var statusMenu: NSMenu?
    private var globalHotKeyRef: EventHotKeyRef?
    private var globalHotKeyHandler: EventHandlerRef?
    private var isFrontMode = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        NSApp.setActivationPolicy(.accessory)
        WidgetThemeMode.storedOrAutomatic().applyAppearance()
        debugLog("app launched bundle=\(Bundle.main.bundlePath)")

        let width = UsageWidgetView.widgetWidth
        let height = UsageWidgetView.widgetDefaultHeight
        let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let origin = CGPoint(
            x: max(screenFrame.minX + 16, screenFrame.maxX - width - 28),
            y: max(screenFrame.minY + 16, screenFrame.maxY - height - 36)
        )

        let panel = DesktopWidgetWindow(contentRect: NSRect(origin: origin, size: CGSize(width: width, height: height)))
        panel.delegate = self
        panel.minSize = CGSize(width: UsageWidgetView.widgetWidth, height: UsageWidgetView.widgetMinHeight)
        panel.maxSize = CGSize(width: UsageWidgetView.widgetWidth, height: UsageWidgetView.widgetMaxHeight)
        panel.contentMinSize = panel.minSize
        panel.contentMaxSize = panel.maxSize
        panel.contentView = GlassHostingContainer(rootView: UsageWidgetView(store: store), cornerRadius: 24)
        panel.moveToFrontLayer()
        isFrontMode = true
        window = panel

        setupStatusItem()
        registerGlobalHotKey()
        store.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        unregisterGlobalHotKey()
        store.stop()
    }

    func toggleWindowLayer() {
        guard let window else { return }
        if isFrontMode {
            window.moveToDesktopLayer()
            isFrontMode = false
        } else {
            window.moveToFrontLayer()
            isFrontMode = true
        }
    }

    @objc private func statusItemButtonPressed() {
        guard let event = NSApp.currentEvent else {
            toggleWindowLayer()
            return
        }

        if event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
            if let statusMenu {
                statusItem?.menu = statusMenu
                statusItem?.button?.performClick(nil)
                statusItem?.menu = nil
            }
            return
        }

        toggleWindowLayer()
    }

    func refreshStatusItemLocalization() {
        statusMenu = makeStatusMenu()
        let language = WidgetLanguage.storedOrAutomatic()
        statusItem?.button?.toolTip = language.text(
            "AgentDesk：左键切换前台/桌面层，右键打开菜单，快捷键 ⌘U",
            "AgentDesk: left click toggles front/desktop layer, right click opens the menu, shortcut ⌘U"
        )
        settingsWindow?.title = language.text("设置", "Settings")
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem = item

        guard let button = item.button else { return }
        if let image = NSImage(systemSymbolName: "gauge.with.dots.needle.67percent", accessibilityDescription: "AgentDesk") {
            image.isTemplate = true
            button.image = image
        } else {
            button.title = "C"
        }
        button.target = self
        button.action = #selector(statusItemButtonPressed)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        refreshStatusItemLocalization()
    }

    private func makeStatusMenu() -> NSMenu {
        let language = WidgetLanguage.storedOrAutomatic()
        let menu = NSMenu()
        menu.addItem(withTitle: language.text("切换前台/桌面层", "Toggle Front/Desktop Layer"), action: #selector(toggleWindowLayerFromMenu), keyEquivalent: "")
        menu.addItem(withTitle: language.text("刷新数据", "Refresh Data"), action: #selector(refreshDataFromMenu), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: language.text("设置", "Settings"), action: #selector(openSettingsFromMenu), keyEquivalent: ",")
        menu.addItem(.separator())
        menu.addItem(withTitle: language.text("退出 AgentDesk", "Quit AgentDesk"), action: #selector(quitFromMenu), keyEquivalent: "q")
        menu.items.forEach { $0.target = self }
        return menu
    }

    @objc private func toggleWindowLayerFromMenu() {
        toggleWindowLayer()
    }

    @objc private func refreshDataFromMenu() {
        store.refresh()
    }

    @objc private func openSettingsFromMenu() {
        openSettings()
    }

    func openSettings() {
        WidgetThemeMode.storedOrAutomatic().applyAppearance()

        settingsWindow?.close()
        let settingsView = SettingsView(
            store: store,
            languageChanged: { [weak self] in
                self?.refreshStatusItemLocalization()
            },
            themeChanged: { [weak self] in
                self?.settingsWindow?.title = WidgetLanguage.storedOrAutomatic().text("设置", "Settings")
            }
        )
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 460),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.title = WidgetLanguage.storedOrAutomatic().text("设置", "Settings")
        panel.contentView = GlassHostingContainer(rootView: settingsView, cornerRadius: 18, draggable: false)
        panel.isReleasedWhenClosed = false
        panel.minSize = CGSize(width: 600, height: 440)
        panel.delegate = self
        panel.identifier = NSUserInterfaceItemIdentifier("AgentDeskSettingsWindow")
        if !restoreFrame(for: panel, storageKey: WindowStorageKey.settingsFrame) {
            panel.center()
        }
        settingsWindow = panel

        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func quitFromMenu() {
        NSApp.terminate(nil)
    }

    func windowDidMove(_ notification: Notification) {
        persistWindowFrame(from: notification)
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        persistWindowFrame(from: notification)
    }

    private func persistWindowFrame(from notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        let storageKey: String?
        switch window.identifier?.rawValue {
        case "AgentDeskSettingsWindow":
            storageKey = WindowStorageKey.settingsFrame
        default:
            storageKey = nil
        }
        guard let storageKey else { return }
        AgentDeskDatabase.shared.set(NSStringFromRect(window.frame), forKey: storageKey)
    }

    private func restoreFrame(for window: NSWindow, storageKey: String) -> Bool {
        guard let frameString = AgentDeskDatabase.shared.string(forKey: storageKey) else { return false }
        let rect = NSRectFromString(frameString)
        guard rect.width > 0, rect.height > 0 else { return false }
        window.setFrame(rect, display: false)
        return true
    }

    private func registerGlobalHotKey() {
        debugLog("register global hotkey command+u")
        var eventSpec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData in
                guard let userData else { return noErr }
                let delegate = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
                DispatchQueue.main.async {
                    delegate.toggleWindowLayer()
                }
                return noErr
            },
            1,
            &eventSpec,
            Unmanaged.passUnretained(self).toOpaque(),
            &globalHotKeyHandler
        )
        guard handlerStatus == noErr else {
            debugLog("InstallEventHandler failed status=\(handlerStatus)")
            return
        }

        let hotKeyID = EventHotKeyID(signature: fourCharCode("CDXU"), id: 1)
        let hotKeyStatus = RegisterEventHotKey(
            UInt32(kVK_ANSI_U),
            UInt32(cmdKey),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &globalHotKeyRef
        )
        if hotKeyStatus == noErr {
            debugLog("global hotkey registered")
        } else {
            debugLog("RegisterEventHotKey failed status=\(hotKeyStatus)")
        }
    }

    private func unregisterGlobalHotKey() {
        if let globalHotKeyRef {
            UnregisterEventHotKey(globalHotKeyRef)
        }
        if let globalHotKeyHandler {
            RemoveEventHandler(globalHotKeyHandler)
        }
        globalHotKeyRef = nil
        globalHotKeyHandler = nil
    }
}

// MARK: - Entry Point

@main
struct AgentDeskMain {
    static func main() {
        if CommandLine.arguments.contains("--dump-json") {
            let provider: UsageProvider
            if let index = CommandLine.arguments.firstIndex(of: "--provider"),
               CommandLine.arguments.indices.contains(index + 1),
               let selected = UsageProvider(rawValue: CommandLine.arguments[index + 1]) {
                provider = selected
            } else {
                provider = .stored()
            }
            dumpJSON(CodexUsageReader(provider: provider).load())
            return
        }

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
