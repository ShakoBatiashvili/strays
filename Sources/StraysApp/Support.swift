import AppKit
import Carbon.HIToolbox
import SwiftUI
import Foundation
import UserNotifications
import StraysCore

/// Local notifications only. Everything is a no-op outside a real .app bundle
/// (UNUserNotificationCenter traps when there's no bundle identifier).
enum Notifier {
    static var isBundledApp: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundlePath.hasSuffix(".app")
    }

    static func requestAuthorizationIfNeeded() {
        guard isBundledApp else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func authorizationDenied(_ completion: @escaping @Sendable (Bool) -> Void) {
        guard isBundledApp else { completion(false); return }
        UNUserNotificationCenter.current().getNotificationSettings { completion($0.authorizationStatus == .denied) }
    }

    static func post(_ notice: Notice) {
        guard isBundledApp else { return }
        let content = UNMutableNotificationContent()
        content.title = notice.title
        content.body = notice.body
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "strays.nudge", content: content, trigger: nil))
    }
}

/// A global shortcut through Carbon's RegisterEventHotKey: no Accessibility permission needed.
@MainActor
final class HotKey {
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private static var action: (() -> Void)?

    func register(_ choice: HotKeyChoice, action: @escaping () -> Void) {
        unregister()
        guard let (code, modifiers) = Self.keys(for: choice) else { return }
        Self.action = action

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { HotKey.action?() } }
            return noErr
        }, 1, &spec, nil, &handler)
        let id = EventHotKeyID(signature: OSType(0x5354_5259), id: 1)   // "STRY"
        RegisterEventHotKey(code, modifiers, id, GetApplicationEventTarget(), 0, &ref)
    }

    func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        if let handler { RemoveEventHandler(handler) }
        ref = nil
        handler = nil
    }

    private static func keys(for choice: HotKeyChoice) -> (UInt32, UInt32)? {
        switch choice {
        case .off: nil
        case .controlOptionP: (UInt32(kVK_ANSI_P), UInt32(controlKey | optionKey))
        case .controlOptionS: (UInt32(kVK_ANSI_S), UInt32(controlKey | optionKey))
        case .commandShiftOptionP: (UInt32(kVK_ANSI_P), UInt32(cmdKey | shiftKey | optionKey))
        }
    }
}

/// What the row buttons do. None of these send anything off this Mac.
@MainActor
enum Actions {
    static func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    // MARK: Editor

    private static let editors: [(name: String, bundleID: String)] = [
        ("Cursor", "com.todesktop.230313mzl4w4u92"),
        ("VS Code", "com.microsoft.VSCode"),
        ("Zed", "dev.zed.Zed"),
        ("Xcode", "com.apple.dt.Xcode"),
    ]

    static let editor: (name: String, url: URL)? = {
        for e in editors {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: e.bundleID) { return (e.name, url) }
        }
        return nil
    }()

    static func openInEditor(_ path: String) {
        let folder = URL(fileURLWithPath: path, isDirectory: true)
        guard let editor else { return revealInFinder(path) }
        NSWorkspace.shared.open([folder], withApplicationAt: editor.url, configuration: NSWorkspace.OpenConfiguration())
    }

    static func revealInFinder(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path, isDirectory: true)])
    }

    // MARK: Terminal tab

    /// Only real tty names ever reach the AppleScript.
    static func validTTY(_ tty: String?) -> String? {
        guard let tty, tty.range(of: #"^ttys[0-9]{1,4}$"#, options: .regularExpression) != nil else { return nil }
        return "/dev/" + tty
    }

    static func terminalApp(for stray: Stray, in all: [Stray]) -> String? {
        switch stray.origin {
        case .terminal(_, let app): return app
        case .agent(let parent, _): return all.first { $0.id == parent }.flatMap { terminalApp(for: $0, in: all) }
        default: return nil
        }
    }

    /// Brings the tab that owns `tty` to the front (Terminal and iTerm2), or just activates the app.
    static func jumpToTab(tty: String?, app: String?) {
        let appName = app ?? "Terminal"
        guard let device = validTTY(tty) else { return activate(appName) }
        let script: String
        switch appName {
        case "Terminal":
            script = """
            tell application id "com.apple.Terminal"
              repeat with w in windows
                repeat with t in tabs of w
                  if tty of t is "\(device)" then
                    set miniaturized of w to false
                    set selected of t to true
                    set index of w to 1
                  end if
                end repeat
              end repeat
              activate
            end tell
            """
        case "iTerm2", "iTerm":
            script = """
            tell application id "com.googlecode.iterm2"
              repeat with w in windows
                repeat with t in tabs of w
                  repeat with s in sessions of t
                    if tty of s is "\(device)" then
                      select w
                      select t
                      select s
                    end if
                  end repeat
                end repeat
              end repeat
              activate
            end tell
            """
        default:
            return activate(appName)
        }
        var error: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&error)
        if error != nil { activate(appName) }
    }

    static func activate(_ name: String) {
        NSWorkspace.shared.runningApplications.first { $0.localizedName == name }?.activate()
    }

    // MARK: Clipboard

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// The menu-bar item and its popover.
@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private let model: AppModel

    init(model: AppModel) {
        self.model = model
        super.init()
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        let host = NSHostingController(rootView: PanelView(model: model))
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host

        if let button = item.button {
            button.target = self
            button.action = #selector(clicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.imagePosition = .imageLeading
            button.setAccessibilityLabel("Strays")
        }
        observe()
    }

    /// Redraws the badge whenever the counts change.
    private func observe() {
        withObservationTracking {
            updateButton(servers: model.serverCount, stale: model.stale.count)
        } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
    }

    private func updateButton(servers: Int, stale: Int) {
        guard let button = item.button else { return }
        button.image = Self.menuBarImage(stale: stale > 0)
        button.contentTintColor = nil
        let title = servers > 0 ? " \(servers)" : ""
        button.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .medium),
            .foregroundColor: NSColor.white,
            .baselineOffset: 0.5,
        ])
        var tip = servers == 1 ? "1 server running" : "\(servers) servers running"
        if stale > 0 { tip += ", \(stale) stale" }
        button.toolTip = "Strays: " + tip
    }

    /// A white paw (drawn white on purpose, not as a template that macOS may tint dark), with a small
    /// orange dot at its top-right corner when something is stale.
    static func menuBarImage(stale: Bool) -> NSImage {
        let size = NSSize(width: 19, height: 16)
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
        let paw = NSImage(systemSymbolName: "pawprint.fill", accessibilityDescription: "Strays")?.withSymbolConfiguration(config)
        let image = NSImage(size: size, flipped: false) { rect in
            if let paw {
                let s = paw.size
                paw.draw(in: NSRect(x: 0, y: (rect.height - s.height) / 2, width: s.width, height: s.height))
            }
            if stale {
                let dot = NSRect(x: rect.width - 5, y: rect.height - 5.5, width: 5, height: 5)
                NSColor.black.withAlphaComponent(0.35).setFill()
                NSBezierPath(ovalIn: dot.insetBy(dx: -1, dy: -1)).fill()
                NSColor.systemOrange.setFill()
                NSBezierPath(ovalIn: dot).fill()
            }
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = stale ? "Strays, something is stale" : "Strays"
        return image
    }

    @objc private func clicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showMenu()
        } else {
            toggle()
        }
    }

    func toggle() {
        popover.isShown ? popover.performClose(nil) : show()
    }

    func show() {
        guard let button = item.button else { return }
        model.page = .list
        model.panelOpen = true
        NSApp.activate()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    func popoverDidClose(_ notification: Notification) {
        model.panelOpen = false
        model.bulkConfirm = nil
    }

    private func showMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: "Open Strays", action: #selector(openFromMenu), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Refresh", action: #selector(refreshFromMenu), keyEquivalent: "r").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(settingsFromMenu), keyEquivalent: ",").target = self
        menu.addItem(withTitle: "Quit Strays", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        item.button?.performClick(nil)
        item.menu = nil   // so the next left click opens the panel again
    }

    @objc private func openFromMenu() { show() }
    @objc private func refreshFromMenu() { model.refreshSoon() }
    @objc private func settingsFromMenu() {
        show()
        model.page = .settings
    }
}
