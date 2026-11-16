import AppKit
import SwiftUI
import StraysCore

struct SettingsPage: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Button { model.page = .list } label: {
                    Label("Back", systemImage: "chevron.left").labelStyle(.titleAndIcon)
                }
                .buttonStyle(.plain).foregroundStyle(Color.accentColor)
                .keyboardShortcut(.cancelAction)
                Spacer()
                Text("Settings").font(.headline)
                Spacer()
                Color.clear.frame(width: 50, height: 1)
            }
            .padding(12)
            Divider()

            Form {
                Section {
                    Stepper(value: $model.settings.idleHours, in: 1...48, step: 1) {
                        LabeledContent("Idle after", value: hours(model.settings.idleHours))
                    }
                    Stepper(value: $model.settings.oldHours, in: 4...720, step: 4) {
                        LabeledContent("Old after", value: hours(model.settings.oldHours))
                    }
                } header: {
                    Text("Stale")
                } footer: {
                    Text("Idle: no real CPU use (or an idle AI session) for that long. Orphaned: its terminal is gone. Services started by launchd are never stale.")
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Section("Daily reminder") {
                    Toggle("Remind me about stale things", isOn: Binding(
                        get: { model.settings.nudgeEnabled },
                        set: { on in
                            model.settings.nudgeEnabled = on
                            if on { Notifier.requestAuthorizationIfNeeded(); model.refreshNotificationStatus() }
                        }))
                    if model.settings.nudgeEnabled {
                        DatePicker("At", selection: nudgeTime, displayedComponents: .hourAndMinute)
                        if model.notificationsDenied {
                            Text("Notifications are off for Strays. Turn them on in System Settings > Notifications.")
                                .font(.caption).foregroundStyle(Theme.stale)
                        }
                    }
                }

                Section("Stopping") {
                    Stepper(value: $model.settings.stopGraceSeconds, in: 1...30, step: 1) {
                        LabeledContent("Force-quit after", value: "\(Int(model.settings.stopGraceSeconds)) s")
                    }
                }

                Section("General") {
                    Picker("Shortcut", selection: $model.settings.hotKey) {
                        ForEach(HotKeyChoice.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    Toggle("Open at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                }

                Section("Command line") {
                    Text("strays ls · strays who :3000 · strays stop :5173 · strays stale")
                        .font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                    Button("Copy install command") {
                        Actions.copy("ln -sf \"\(Bundle.main.bundlePath)/Contents/Helpers/strays\" /usr/local/bin/strays")
                    }
                    .help("Puts the strays command on your PATH (a symlink into this app)")
                }

                Section {
                    HStack {
                        Text("Strays \(CLI.version)").foregroundStyle(.secondary)
                        Spacer()
                        Button("Quit Strays") { NSApp.terminate(nil) }
                            .keyboardShortcut("q", modifiers: .command)
                    }
                }
            }
            .formStyle(.grouped)
            .frame(height: 520)
        }
        .onAppear { model.refreshNotificationStatus() }
    }

    private func hours(_ value: Double) -> String {
        let h = Int(value)
        if h >= 48, h % 24 == 0 { return "\(h / 24) days" }
        return h == 1 ? "1 hour" : "\(h) hours"
    }

    private var nudgeTime: Binding<Date> {
        Binding(
            get: {
                Calendar.current.date(bySettingHour: model.settings.nudgeMinute / 60, minute: model.settings.nudgeMinute % 60,
                                      second: 0, of: Date()) ?? Date()
            },
            set: { date in
                let c = Calendar.current.dateComponents([.hour, .minute], from: date)
                model.settings.nudgeMinute = (c.hour ?? 18) * 60 + (c.minute ?? 0)
            })
    }
}
