import Cocoa
import Carbon.HIToolbox
import SwiftUI

// MARK: - AppKit Helpers

final class DraggableHostingView<Content: View>: NSHostingView<Content> {
    override var mouseDownCanMoveWindow: Bool { true }
}

final class GlassHostingContainer<Content: View>: NSView {
    private let cornerRadius: CGFloat

    init(rootView: Content, cornerRadius: CGFloat) {
        self.cornerRadius = cornerRadius
        super.init(frame: .zero)

        wantsLayer = true
        layer?.cornerRadius = cornerRadius

        let host = DraggableHostingView(rootView: rootView)
        host.frame = bounds
        host.autoresizingMask = [.width, .height]

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

    override var mouseDownCanMoveWindow: Bool { true }
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
    private let store = UsageStore()
    private var window: DesktopWidgetWindow?
    private var statusItem: NSStatusItem?
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
        panel.moveToDesktopLayer()
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

    @objc private func statusItemClicked() {
        toggleWindowLayer()
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem = item

        guard let button = item.button else { return }
        if let image = NSImage(systemSymbolName: "gauge.with.dots.needle.67percent", accessibilityDescription: "ModelMeter") {
            image.isTemplate = true
            button.image = image
        } else {
            button.title = "C"
        }
        button.toolTip = "ModelMeter：点击切换前台/桌面层，快捷键 ⌘U"
        button.target = self
        button.action = #selector(statusItemClicked)
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
struct ModelMeterMain {
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
