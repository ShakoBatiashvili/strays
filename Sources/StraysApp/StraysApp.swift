import AppKit
import SwiftUI
import UserNotifications
import StraysCore
import StraysSystem

/// Entry point. `--snapshot <dir>` renders the panel to PNGs (light and dark) from canned data
/// and exits; it never reads processes, settings, or the network.
@main
enum StraysMain {
    static func main() {
        let args = CommandLine.arguments
        if let flag = args.firstIndex(of: "--snapshot") {
            let directory = args.indices.contains(flag + 1) ? args[flag + 1] : "."
            MainActor.assumeIsolated { Snapshot.run(outputDirectory: directory) }
            return
        }
        let app = NSApplication.shared
        let delegate = MainActor.assumeIsolated { AppDelegate() }
        app.delegate = delegate
        app.setActivationPolicy(.accessory)   // menu-bar only, no Dock icon
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private var model: AppModel!
    private var statusItem: StatusItemController!
    private let hotKey = HotKey()

    func applicationDidFinishLaunching(_ notification: Notification) {
        model = AppModel()
        statusItem = StatusItemController(model: model)
        model.onSettingsChanged = { [weak self] settings in self?.applyHotKey(settings.hotKey) }
        applyHotKey(model.settings.hotKey)

        if Notifier.isBundledApp {
            UNUserNotificationCenter.current().delegate = self
            if model.settings.nudgeEnabled { Notifier.requestAuthorizationIfNeeded() }
        }
        model.start()
    }

    private func applyHotKey(_ choice: HotKeyChoice) {
        hotKey.register(choice) { [weak self] in self?.statusItem.toggle() }
    }

    // Clicking the daily reminder opens the panel.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        Task { @MainActor in self.statusItem.show() }
        completionHandler()
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
