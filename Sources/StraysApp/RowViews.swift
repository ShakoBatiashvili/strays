import AppKit
import SwiftUI
import StraysCore
import StraysSystem

/// One running thing: a server, an AI session, a script, or a system port holder.
struct StrayRow: View {
    @Bindable var model: AppModel
    let stray: Stray
    var isHelper = false

    @State private var hovering = false
    @State private var confirming = false
    @State private var confirmTask: Task<Void, Never>?
    @State private var preview: StopPreview?

    private var expanded: Bool { model.expanded.contains(stray.id) }
    private var isStopping: Bool { model.stopping.contains(stray.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                statusDot.padding(.top, 5)
                VStack(alignment: .leading, spacing: 3) {
                    titleLine
                    subtitleLine
                    if !stray.tags.isEmpty || model.rowErrors[stray.id] != nil { tagLine }
                }
                Spacer(minLength: 6)
                trailing
            }
            .padding(.horizontal, isHelper ? 8 : 12)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
            .onTapGesture { toggleExpanded() }

            if confirming { confirmStrip }
            if expanded { DetailView(model: model, stray: stray).padding(.leading, isHelper ? 8 : 28).padding(.trailing, 12) }
        }
        .background(
            RoundedRectangle(cornerRadius: Theme.rowRadius)
                .fill(Color.primary.opacity(hovering || expanded ? 0.05 : 0))
                .padding(.horizontal, isHelper ? 0 : 4)
        )
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.08), value: hovering)
        .animation(.easeOut(duration: 0.2), value: expanded)
        .animation(.easeOut(duration: 0.15), value: confirming)
        .contextMenu { RowMenu(model: model, stray: stray, startStop: askToStop) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityText)
    }

    // MARK: Pieces

    private var statusDot: some View {
        let color: Color = stray.isStale ? Theme.stale : (stray.kind == .system ? Color.secondary.opacity(0.5) : .green)
        return Circle().fill(color).frame(width: 7, height: 7)
            .help(stray.isStale ? "Stale: " + stray.tags.map(Formatting.tag).joined(separator: ", ") : "Running")
    }

    private var titleLine: some View {
        HStack(spacing: 6) {
            Text(stray.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
            ForEach(stray.ports.prefix(3), id: \.self) { port in PortChip(model: model, stray: stray, port: port) }
            if stray.ports.count > 3 { Text(verbatim: "+\(stray.ports.count - 3)").font(.caption2).foregroundStyle(.secondary) }
            if stray.sockets.contains(where: \.isExposed), stray.kind != .system {
                Image(systemName: "network").font(.system(size: 10)).foregroundStyle(.secondary)
                    .help("Reachable from other devices on your network, not just this Mac")
            }
        }
    }

    @ViewBuilder private var subtitleLine: some View {
        if let session = stray.agentSession, let title = session.title {
            Text(title).font(.system(size: 12)).lineLimit(1)
        }
        HStack(spacing: 0) {
            Text(subtitle).lineLimit(1).truncationMode(.middle)
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
    }

    private var subtitle: String {
        var parts: [String] = []
        if stray.agentSession?.title == nil || stray.title != stray.command { parts.append(stray.command) }
        if let session = stray.agentSession, session.status != .unknown {
            if session.status == .busy { parts.append("working") }
            else if let updated = session.updatedAt { parts.append("idle \(Formatting.duration(model.now.timeIntervalSince(updated)))") }
        }
        parts.append(shortOrigin)
        if !stray.helpers.isEmpty { parts.append("\(stray.helpers.count) helper\(stray.helpers.count == 1 ? "" : "s")") }
        if stray.title == stray.command, parts.first == stray.command { parts.removeFirst() }
        return parts.joined(separator: " · ")
    }

    private var shortOrigin: String {
        switch stray.origin {
        case .terminal(let tty, _): return tty
        case .agent(_, let name): return "via \(name)"
        case .app(let name): return "via \(name)"
        case .launchd: return "service"
        case .orphaned: return "no terminal"
        case .macOS: return "macOS"
        case .application: return "app"
        case .unknown: return stray.runtime.displayName
        }
    }

    private var tagLine: some View {
        HStack(spacing: 4) {
            ForEach(stray.tags, id: \.self) { tag in
                Text(Formatting.tag(tag))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Theme.stale)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill(Theme.stale.opacity(0.14)))
                    .help(tagHelp(tag))
            }
            if let error = model.rowErrors[stray.id] {
                Text(error).font(.system(size: 10)).foregroundStyle(Theme.danger).lineLimit(1)
            }
        }
    }

    private func tagHelp(_ tag: StaleTag) -> String {
        switch tag {
        case .orphaned: "Its terminal or parent is gone; nothing is watching it."
        case .idle: "No real activity for \(Int(model.settings.idleHours)) h or more."
        case .old: "Running for more than \(Int(model.settings.oldHours)) h."
        }
    }

    @ViewBuilder private var trailing: some View {
        HStack(spacing: 2) {
            if hovering && !confirming && !isStopping {
                QuickActions(model: model, stray: stray)
            } else {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(Formatting.duration(stray.age(at: model.now)))
                        .font(.system(size: 11, weight: .medium)).monospacedDigit()
                        .foregroundStyle(stray.tags.contains(.old) ? Theme.stale : .secondary)
                        .help("Running since \(stray.root.startDate.formatted(date: .abbreviated, time: .shortened))")
                    Text(Formatting.bytes(stray.residentBytes)).font(.system(size: 10)).monospacedDigit().foregroundStyle(.tertiary)
                }
                .frame(minWidth: 56, alignment: .trailing)
            }
            if stray.origin != .macOS {
                StopButton(stopping: isStopping, armed: confirming, action: askToStop)
            }
        }
    }

    private var confirmStrip: some View {
        let count = preview?.processCount
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Group {
                    if let count {
                        Text(count == 1 ? "Stop \(stray.title)? 1 process." : "Stop \(stray.title)? \(count) processes.")
                    } else {
                        Text("Stop \(stray.title)?")
                    }
                }
                .font(.caption).lineLimit(2)
                Spacer()
                Button("Keep running") { cancelConfirm() }.keyboardShortcut(.cancelAction)
                Button(count.map { $0 > 1 ? "Stop \($0)" : "Stop" } ?? "Stop") {
                    cancelConfirm()
                    model.stop([stray], label: stray.title)
                }
                .buttonStyle(DangerButtonStyle())
                .disabled(model.isLive && preview == nil)
            }
            if let left = preview?.leftRunning, !left.isEmpty {
                Text("Leaves running: " + left.joined(separator: ", "))
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .padding(.leading, isHelper ? 0 : 16)
    }

    // MARK: Behaviour

    private func toggleExpanded() {
        if expanded { model.expanded.remove(stray.id) } else { model.expanded.insert(stray.id) }
    }

    /// First click arms; the inline strip names what will stop. It disarms itself after 6 s.
    private func askToStop() {
        guard !isStopping else { return }
        confirming = true
        preview = nil
        confirmTask?.cancel()
        confirmTask = Task {
            // The real plan, from a fresh snapshot: the count shown is the count that will be signalled.
            if model.isLive { preview = await model.preview([stray]) }
            try? await Task.sleep(for: .seconds(8))
            if !Task.isCancelled { confirming = false }
        }
    }

    private func cancelConfirm() {
        confirmTask?.cancel()
        confirming = false
    }

    private var accessibilityText: String {
        var parts = [stray.kind.singular, stray.title]
        if !stray.ports.isEmpty { parts.append("port " + stray.ports.map(String.init).joined(separator: ", ")) }
        parts.append("running \(Formatting.duration(stray.age(at: model.now)))")
        if stray.isStale { parts.append(stray.tags.map(Formatting.tag).joined(separator: ", ")) }
        return parts.joined(separator: ", ")
    }
}

/// Always visible, so stopping never depends on hover.
private struct StopButton: View {
    let stopping: Bool
    let armed: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Group {
                if stopping {
                    ProgressView().controlSize(.small).scaleEffect(0.6)
                } else {
                    Image(systemName: "stop.fill").font(.system(size: 9, weight: .bold))
                }
            }
            .frame(width: 24, height: 24)
            .foregroundStyle(hovering || armed ? Theme.danger : Color.secondary)
            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.danger.opacity(hovering || armed ? 0.12 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(stopping)
        .onHover { hovering = $0 }
        .help(stopping ? "Stopping…" : "Stop this and everything it started")
        .accessibilityLabel(stopping ? "Stopping" : "Stop")
    }
}

/// A port as a small chip; clicking opens it in the browser when it speaks HTTP.
private struct PortChip: View {
    @Bindable var model: AppModel
    let stray: Stray
    let port: UInt16

    var body: some View {
        let proto = model.probes[model.probeKey(stray, port)]
        let isWeb = proto == .http || proto == .https
        Button {
            if isWeb, let url = URL(string: "\(proto == .https ? "https" : "http")://localhost:\(port)") { Actions.open(url) }
            else { Actions.copy(String(port)) }
        } label: {
            Text(verbatim: ":\(port)")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .padding(.horizontal, 5).padding(.vertical, 1)
                .foregroundStyle(isWeb ? Color.accentColor : .primary)
                .background(RoundedRectangle(cornerRadius: 4).fill((isWeb ? Color.accentColor : .primary).opacity(0.1)))
        }
        .buttonStyle(.plain)
        .help(isWeb ? "Open \(proto == .https ? "https" : "http")://localhost:\(port)" : "Copy port \(port)")
    }
}

/// Shortcuts that appear on hover; the same actions are in the right-click menu and the details.
private struct QuickActions: View {
    @Bindable var model: AppModel
    let stray: Stray

    var body: some View {
        HStack(spacing: 0) {
            if let url = model.httpURL(for: stray) {
                IconButton(symbol: "safari", help: "Open \(url.absoluteString)") { Actions.open(url) }
            }
            if stray.tty != nil {
                IconButton(symbol: "terminal", help: "Show its terminal tab") {
                    Actions.jumpToTab(tty: stray.tty, app: Actions.terminalApp(for: stray, in: model.strays))
                }
            }
            if let path = stray.projectPath {
                IconButton(symbol: "chevron.left.forwardslash.chevron.right",
                           help: Actions.editor.map { "Open \(stray.title) in \($0.name)" } ?? "Show in Finder") {
                    Actions.openInEditor(path)
                }
            }
            Menu {
                CopyItems(stray: stray, url: model.httpURL(for: stray))
            } label: {
                Image(systemName: "doc.on.doc").font(.system(size: 12, weight: .medium))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 26, height: 26)
            .help("Copy…")
        }
    }
}

struct CopyItems: View {
    let stray: Stray
    let url: URL?

    var body: some View {
        if let url { Button("Copy URL") { Actions.copy(url.absoluteString) } }
        Button("Copy PID (\(stray.root.pid))") { Actions.copy(String(stray.root.pid)) }
        Button("Copy command") { Actions.copy(stray.command) }
        Button("Copy full command line") { Actions.copy(stray.root.arguments.joined(separator: " ")) }
        if let path = stray.projectPath { Button("Copy folder path") { Actions.copy(path) } }
        Button("Copy stop command") {
            // pid: always resolves to exactly this row (helpers included); a port could belong to a parent row.
            Actions.copy("strays stop pid:\(stray.root.pid)")
        }
    }
}

private struct RowMenu: View {
    @Bindable var model: AppModel
    let stray: Stray
    let startStop: () -> Void

    var body: some View {
        if let url = model.httpURL(for: stray) { Button("Open \(url.absoluteString)") { Actions.open(url) } }
        if stray.tty != nil {
            Button("Show terminal tab") { Actions.jumpToTab(tty: stray.tty, app: Actions.terminalApp(for: stray, in: model.strays)) }
        }
        if let path = stray.projectPath {
            Button(Actions.editor.map { "Open in \($0.name)" } ?? "Open folder") { Actions.openInEditor(path) }
            Button("Show in Finder") { Actions.revealInFinder(path) }
        }
        Divider()
        CopyItems(stray: stray, url: model.httpURL(for: stray))
        Divider()
        Button(model.expanded.contains(stray.id) ? "Hide details" : "Show details") {
            if model.expanded.contains(stray.id) { model.expanded.remove(stray.id) } else { model.expanded.insert(stray.id) }
        }
        if stray.origin != .macOS {
            Divider()
            if let project = stray.project, let folder = stray.projectPath {
                // Same folder, not just the same name: two repos called "api" are different projects.
                let siblings = model.strays.filter { $0.projectPath == folder && $0.kind != .system }
                if siblings.count > 1 {
                    Button("Stop everything in \(project) (\(siblings.count))…") { model.confirmBulk("everything in \(project)", siblings) }
                }
            }
            Button("Stop…", role: .destructive, action: startStop)
        }
    }
}

// MARK: - Details

private struct DetailView: View {
    @Bindable var model: AppModel
    let stray: Stray

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 3) {
                field("PID", "\(stray.root.pid)")
                if !stray.sockets.isEmpty {
                    field("Listening", stray.sockets.map { "\($0.address == "*" ? "all interfaces" : $0.address == "::" ? "all (IPv6)" : $0.address):\($0.port)" }
                        .joined(separator: ", "))
                }
                if stray.agentSession?.title != nil || stray.title != stray.command { field("Command", stray.command) }
                if let session = stray.agentSession {
                    if let name = session.name { field("Session", name) }
                    if let updated = session.updatedAt { field("Last active", updated.formatted(date: .abbreviated, time: .shortened)) }
                }
                field("Started", stray.root.startDate.formatted(date: .abbreviated, time: .shortened) + " (\(Formatting.duration(stray.age(at: model.now))) ago)")
                field("From", Formatting.origin(stray.origin))
                if let path = stray.projectPath { field("Folder", (path as NSString).abbreviatingWithTildeInPath) }
                field("Runtime", stray.runtime.displayName)
                field("Memory", "\(Formatting.bytes(stray.residentBytes)) in \(stray.allMembers.count) process\(stray.allMembers.count == 1 ? "" : "es")")
                field("CPU time", Formatting.duration(stray.cpuSeconds))
            }
            .font(.system(size: 11))

            if stray.members.count > 1 {
                Text("PROCESSES").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary).padding(.top, 2)
                ForEach(stray.members, id: \.pid) { member in
                    HStack(spacing: 6) {
                        Text(verbatim: "\(member.pid)").monospacedDigit().foregroundStyle(.secondary).frame(width: 46, alignment: .leading)
                        Text(Recognizer.commandLabel(of: member)).lineLimit(1).truncationMode(.middle)
                        if !member.listening.isEmpty {
                            Text(Formatting.ports(member.listening.map(\.port).uniqued())).foregroundStyle(.secondary)
                        }
                    }
                    .font(.system(size: 11))
                }
            }

            if !stray.helpers.isEmpty {
                Text("HELPERS (MCP SERVERS AND TOOLS)").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary).padding(.top, 2)
                ForEach(stray.helpers) { helper in StrayRow(model: model, stray: helper, isHelper: true) }
            }

            if stray.origin == .macOS, let hint = PortHints.hint(port: stray.ports.first ?? 0, holder: stray) {
                Text(hint).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.bottom, 10)
        .textSelection(.enabled)
    }

    private func field(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            Text(value).lineLimit(2).truncationMode(.middle)
        }
    }
}

// MARK: - Docker

struct ContainerRow: View {
    @Bindable var model: AppModel
    let container: DockerContainer
    @State private var confirming = false
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "shippingbox.fill").font(.system(size: 9)).foregroundStyle(.blue).padding(.top, 4)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(container.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        ForEach(container.publishedPorts.prefix(3), id: \.self) { port in
                            Button { Actions.open(URL(string: "http://localhost:\(port)")!) } label: {
                                Text(verbatim: ":\(port)").font(.system(size: 11, weight: .medium, design: .monospaced))
                                    .padding(.horizontal, 5).padding(.vertical, 1)
                                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.1)))
                            }
                            .buttonStyle(.plain).help("Open http://localhost:\(port)")
                        }
                    }
                    Text("\(container.image) · \(container.status)").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                StopButton(stopping: model.stoppingContainers.contains(container.id), armed: confirming) { confirming = true }
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            if confirming {
                HStack {
                    Text("Stop container \(container.title)?").font(.caption)
                    Spacer()
                    Button("Keep running") { confirming = false }.keyboardShortcut(.cancelAction)
                    Button("Stop") { confirming = false; model.stopContainer(container) }
                        .buttonStyle(DangerButtonStyle())
                }
                .controlSize(.small).padding(.horizontal, 12).padding(.bottom, 8).padding(.leading, 16)
            }
        }
        .background(RoundedRectangle(cornerRadius: Theme.rowRadius).fill(Color.primary.opacity(hovering ? 0.05 : 0)).padding(.horizontal, 4))
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Copy container ID") { Actions.copy(container.id) }
            Button("Copy name") { Actions.copy(container.name) }
        }
    }
}

extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}

/// The one red, filled button: it confirms a stop. Drawn by hand so it stays red in every window state.
struct DangerButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.danger.opacity(configuration.isPressed ? 0.75 : 1)))
            .contentShape(Rectangle())
            .animation(.easeOut(duration: 0.06), value: configuration.isPressed)
    }
}
