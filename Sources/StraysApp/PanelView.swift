import AppKit
import SwiftUI
import StraysCore
import StraysSystem

/// Sizes and colours used across the panel (4 pt spacing scale, one accent, red only for Stop).
enum Theme {
    static let width: CGFloat = 440
    static var maxListHeight: CGFloat = 520
    static let stale = Color.orange
    static let danger = Color.red
    static let rowRadius: CGFloat = 8
}

struct PanelView: View {
    @Bindable var model: AppModel

    var body: some View {
        Group {
            switch model.page {
            case .list: ListPage(model: model)
            case .settings: SettingsPage(model: model)
            }
        }
        .frame(width: Theme.width)
    }
}

// MARK: - List page

private struct ListPage: View {
    @Bindable var model: AppModel
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let bulk = model.bulkConfirm {
                BulkConfirmView(model: model, bulk: bulk)
                Divider()
            }
            content
            Divider()
            footer
        }
        .onAppear { searchFocused = model.isLive }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Filter by name, port or PID", text: $model.filter)
                        .textFieldStyle(.plain)
                        .focused($searchFocused)
                        .onExitCommand { if model.filter.isEmpty { NSApp.keyWindow?.performClose(nil) } else { model.filter = "" } }
                    if !model.filter.isEmpty {
                        Button { model.filter = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).foregroundStyle(.secondary).help("Clear filter")
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))

                IconButton(symbol: "arrow.clockwise", help: "Refresh (⌘R)", spinning: model.isRefreshing) { model.refreshSoon() }
                    .keyboardShortcut("r", modifiers: .command)
                IconButton(symbol: "gearshape", help: "Settings (⌘,)") { model.page = .settings }
                    .keyboardShortcut(",", modifiers: .command)
            }
            summary
        }
        .padding(12)
    }

    @ViewBuilder private var summary: some View {
        let servers = model.strays.filter { $0.kind == .server }.count
        let agents = model.strays.filter { $0.kind == .agent }.count
        let scripts = model.strays.filter { $0.kind == .script }.count
        let stale = model.stale
        HStack(spacing: 6) {
            Text(countText(servers, "server") + " · " + countText(agents, "AI session") + " · " + countText(scripts, "script"))
                .font(.caption).foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 4)
            if !stale.isEmpty {
                Button {
                    model.confirmBulk("\(stale.count) stale", stale)
                } label: {
                    HStack(spacing: 4) {
                        Circle().fill(Theme.stale).frame(width: 6, height: 6)
                        Text("Stop \(stale.count) stale…")
                    }
                    .font(.caption.weight(.medium))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Capsule().fill(Theme.stale.opacity(0.14)))
                .help("Review and stop everything tagged orphaned, idle or old")
            }
        }
    }

    @ViewBuilder private var content: some View {
        let sections: [StrayKind] = [.server, .agent, .script]
        let visibleCount = sections.map { model.section($0).count }.reduce(0, +) + model.visibleContainers.count
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if visibleCount == 0 {
                    EmptyStateView(model: model)
                }
                ForEach(sections, id: \.self) { kind in
                    let rows = model.section(kind)
                    if !rows.isEmpty {
                        SectionHeader(title: kind.title, count: rows.count)
                        ForEach(rows) { stray in StrayRow(model: model, stray: stray) }
                    }
                }
                if !model.visibleContainers.isEmpty {
                    SectionHeader(title: "Docker containers", count: model.visibleContainers.count)
                    ForEach(model.visibleContainers) { container in ContainerRow(model: model, container: container) }
                }
                let system = model.section(.system)
                if !system.isEmpty {
                    SectionHeader(title: StrayKind.system.title, count: system.count,
                                  collapsed: !(model.showSystem || !model.filter.isEmpty)) {
                        model.showSystem.toggle()
                    }
                    if model.showSystem || !model.filter.isEmpty {
                        ForEach(system) { stray in StrayRow(model: model, stray: stray) }
                    }
                }
            }
            .padding(.vertical, 4)
            .background(GeometryReader { proxy in
                Color.clear.preference(key: ContentHeightKey.self, value: proxy.size.height)
            })
        }
        .frame(height: listHeight)
        .onPreferenceChange(ContentHeightKey.self) { listContentHeight = $0 }
    }

    @State private var listContentHeight: CGFloat = 200
    private var listHeight: CGFloat { min(max(listContentHeight, 120), Theme.maxListHeight) }

    private var footer: some View {
        HStack(spacing: 6) {
            if let banner = model.banner {
                Image(systemName: banner.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(banner.isError ? Theme.stale : Color.green)
                Text(banner.text).lineLimit(2)
            } else {
                Text(updatedText).foregroundStyle(.secondary)
                Spacer()
                if model.settings.hotKey != .off {
                    Text(model.settings.hotKey.label).foregroundStyle(.tertiary).help("Shortcut that opens Strays")
                }
            }
            Spacer(minLength: 0)
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .animation(.easeOut(duration: 0.2), value: model.banner)
    }

    private var updatedText: String {
        guard let last = model.lastRefresh else { return "Looking…" }
        let age = model.now.timeIntervalSince(last)
        let when = age < 10 ? "just now" : Formatting.duration(age) + " ago"
        return "Updated \(when) · \(model.processCount) processes checked"
    }

    private func countText(_ n: Int, _ noun: String) -> String { n == 1 ? "1 \(noun)" : "\(n) \(noun)s" }
}

private struct ContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct IconButton: View {
    let symbol: String
    let help: String
    var spinning = false
    var tint: Color? = nil
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Group {
                if spinning {
                    ProgressView().controlSize(.small).scaleEffect(0.7)
                } else {
                    Image(systemName: symbol).font(.system(size: 13, weight: .medium))
                }
            }
            .frame(width: 26, height: 26)
            .foregroundStyle(tint ?? (hovering ? .primary : .secondary))
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(hovering ? 0.08 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.08), value: hovering)
        .accessibilityLabel(help)
    }
}

private struct SectionHeader: View {
    let title: String
    let count: Int
    var collapsed: Bool? = nil
    var toggle: (() -> Void)? = nil

    var body: some View {
        let label = HStack(spacing: 6) {
            if let collapsed {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .rotationEffect(.degrees(collapsed ? 0 : 90))
                    .animation(.easeOut(duration: 0.2), value: collapsed)
            }
            Text(title.uppercased()).font(.system(size: 10, weight: .semibold)).tracking(0.6)
            Text(verbatim: "\(count)").font(.system(size: 10, weight: .semibold)).monospacedDigit().foregroundStyle(.tertiary)
            Spacer()
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 4)
        .contentShape(Rectangle())

        if let toggle {
            Button(action: toggle) { label }.buttonStyle(.plain)
                .accessibilityLabel("\(title), \(count). \(collapsed == true ? "Show" : "Hide")")
        } else {
            label.accessibilityAddTraits(.isHeader)
        }
    }
}

// MARK: - Empty states

private struct EmptyStateView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 8) {
            if model.filter.isEmpty {
                Image(systemName: "pawprint").font(.system(size: 28)).foregroundStyle(.tertiary)
                Text(model.lastRefresh == nil ? "Looking for strays…" : "Nothing running. Nice and tidy.").font(.headline)
                Text("Dev servers, AI sessions and scripts you start show up here.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if let port = model.filterPort {
                PortAnswer(port: port, model: model)
            } else {
                Image(systemName: "magnifyingglass").font(.system(size: 24)).foregroundStyle(.tertiary)
                Text("Nothing matches “\(model.filter)”").font(.headline)
                Button("Clear filter") { model.filter = "" }.controlSize(.small)
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .padding(.horizontal, 24)
    }
}

/// "Who's on :3000?" when nothing of yours holds it.
private struct PortAnswer: View {
    let port: UInt16
    @Bindable var model: AppModel

    var body: some View {
        let free = model.isLive ? PortAvailability.isFree(port) : true
        Image(systemName: free ? "checkmark.circle" : "lock.circle").font(.system(size: 26))
            .foregroundStyle(free ? Color.green : Theme.stale)
        Text(verbatim: free ? ":\(port) is free" : ":\(port) is in use").font(.headline)
        Text(free ? "Nothing is listening on it. Go ahead and start your server."
                  : PortHints.hint(port: port, holder: nil) ?? "Something Strays can't see holds it: another user's process, or macOS.")
            .font(.caption).foregroundStyle(.secondary)
    }
}

// MARK: - Bulk confirm

private struct BulkConfirmView: View {
    @Bindable var model: AppModel
    let bulk: AppModel.BulkConfirm

    var body: some View {
        let processes = bulk.strays.reduce(0) { $0 + $1.allMembers.count }
        VStack(alignment: .leading, spacing: 8) {
            Text("Stop \(bulk.label)?").font(.headline)
            VStack(alignment: .leading, spacing: 3) {
                ForEach(bulk.strays.prefix(6)) { s in
                    HStack(spacing: 4) {
                        Text(s.title).fontWeight(.medium)
                        if !s.ports.isEmpty { Text(Formatting.ports(s.ports)).monospacedDigit().foregroundStyle(.secondary) }
                        if let t = s.agentSession?.title { Text("“\(t)”").foregroundStyle(.secondary).lineLimit(1) }
                        Spacer(minLength: 4)
                        Text(s.tags.map(Formatting.tag).joined(separator: ", ")).foregroundStyle(Theme.stale)
                    }
                    .font(.caption)
                }
                if bulk.strays.count > 6 {
                    Text("and \(bulk.strays.count - 6) more").font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack {
                Text("\(processes) processes, SIGTERM then SIGKILL after \(Int(model.settings.stopGraceSeconds)) s")
                    .font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Button("Keep running") { model.bulkConfirm = nil }
                    .keyboardShortcut(.cancelAction)
                Button("Stop \(bulk.strays.count)") { model.stop(bulk.strays, label: bulk.label) }
                    .buttonStyle(DangerButtonStyle())
            }
            .controlSize(.small)
        }
        .padding(12)
        .background(Theme.stale.opacity(0.06))
    }
}
