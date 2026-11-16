import Foundation

/// Everything the builder needs, read from the system in one pass.
public struct World: Sendable {
    public var records: [ProcRecord]
    public var currentUID: UInt32
    /// The Strays process itself (never listed, never stopped by itself).
    public var selfPID: Int32
    public var home: String
    /// launchd job labels by PID (`launchctl list`), to tell services from orphans.
    public var launchdLabels: [Int32: String]
    /// Claude Code session status by PID.
    public var agentSessions: [Int32: AgentSessionInfo]

    public init(records: [ProcRecord], currentUID: UInt32, selfPID: Int32, home: String,
                launchdLabels: [Int32: String] = [:], agentSessions: [Int32: AgentSessionInfo] = [:]) {
        self.records = records
        self.currentUID = currentUID
        self.selfPID = selfPID
        self.home = home
        self.launchdLabels = launchdLabels
        self.agentSessions = agentSessions
    }
}

/// Groups raw processes into the rows a person thinks in: "the acme dev server",
/// "that Claude session and its MCP helpers", "the worker I left running".
///
/// A unit is rooted at the top-most process that was started by something the user
/// interacts with: a shell they typed into, an AI session, launchd (after the terminal went
/// away), or an app. Everything below that root belongs to the unit.
public enum StrayBuilder {
    public static func build(_ world: World, project: (String?) -> ProjectRef?) -> [Stray] {
        let graph = Graph(world)

        // 1. Seeds: own processes that run a dev runtime or hold a port.
        let seeds = world.records.filter { r in
            guard r.uid == world.currentUID, r.pid > 1, !graph.isSelfOrBelowSelf(r) else { return false }
            if !r.listening.isEmpty { return true }
            return Recognizer.runtime(of: r).isDevRuntime && !Recognizer.isGUIApp(r)
        }

        // 2. Roots: climb from each seed while the parent is part of the same thing.
        var roots: [Int32: ProcRecord] = [:]
        for seed in seeds {
            let root = graph.root(of: seed)
            roots[root.pid] = root
        }

        // 3. Members: each root plus its descendants, stopping at other roots and boundaries.
        var units: [Int32: Stray] = [:]
        for root in roots.values {
            let members = graph.members(from: root, roots: Set(roots.keys))
            let origin = graph.origin(of: root, labels: world.launchdLabels)
            guard let kind = kind(root: root, members: members, origin: origin) else { continue }

            let runtime = Recognizer.runtime(of: root) == .shell
                ? (members.map(Recognizer.runtime(of:)).first { $0 != .shell } ?? .shell)
                : Recognizer.runtime(of: root)
            let labelSource = members.first { Recognizer.runtime(of: $0) != .shell } ?? root
            let isSystem = kind == .system
            let session = world.agentSessions[root.pid]
            let ref = isSystem ? nil : project(session?.cwd ?? root.cwd)

            units[root.pid] = Stray(
                kind: kind, root: root, members: isSystem ? [root] : members, runtime: runtime,
                project: ref?.name, projectPath: ref?.path,
                command: isSystem ? (Recognizer.appName(path: root.path) ?? root.executableName) : Recognizer.commandLabel(of: labelSource),
                origin: origin, tty: graph.tty(of: root, origin: origin),
                agentSession: session
            )
        }

        // 4. Fold port-less units started by an AI session under that session.
        for (pid, unit) in units {
            guard case .agent(let parent, _) = unit.origin, unit.kind != .server, unit.kind != .system,
                  units[parent.pid] != nil else { continue }
            units[parent.pid]?.helpers.append(unit)
            units[pid] = nil
        }
        for pid in units.keys {
            units[pid]?.helpers.sort { $0.root.startMicros == $1.root.startMicros ? $0.root.pid < $1.root.pid : $0.root.startMicros < $1.root.startMicros }
        }

        return units.values.sorted(by: order)
    }

    private static func kind(root: ProcRecord, members: [ProcRecord], origin: Origin) -> StrayKind? {
        let listens = members.contains { !$0.listening.isEmpty }
        let rootRuntime = Recognizer.runtime(of: root)
        let isAppOrSystem = Recognizer.isGUIApp(root) || Recognizer.isAppleSystem(path: root.path) || rootRuntime == .docker

        if isAppOrSystem { return listens ? .system : nil }
        // Things apps start for themselves (editor language servers, browser bridges) are the app's business.
        if case .app = origin, !listens { return nil }
        if rootRuntime.isAgent { return .agent }
        if listens { return .server }
        if members.contains(where: { Recognizer.runtime(of: $0).isDevRuntime }) { return .script }
        return nil
    }

    private static func order(_ a: Stray, _ b: Stray) -> Bool {
        let kinds = StrayKind.allCases
        let ka = kinds.firstIndex(of: a.kind)!, kb = kinds.firstIndex(of: b.kind)!
        if ka != kb { return ka < kb }
        switch a.kind {
        case .server, .system:
            let pa = a.ports.first ?? .max, pb = b.ports.first ?? .max
            if pa != pb { return pa < pb }
        case .agent, .script:
            break
        }
        // Oldest first: the forgotten ones float up.
        if a.root.startMicros != b.root.startMicros { return a.root.startMicros < b.root.startMicros }
        return a.root.pid < b.root.pid
    }
}

/// The process tree with the questions the builder asks of it.
private struct Graph {
    let world: World
    let byPID: [Int32: ProcRecord]
    let children: [Int32: [ProcRecord]]

    init(_ world: World) {
        self.world = world
        var byPID: [Int32: ProcRecord] = [:]
        var children: [Int32: [ProcRecord]] = [:]
        for r in world.records {
            byPID[r.pid] = r
            children[r.ppid, default: []].append(r)
        }
        for key in children.keys { children[key]?.sort { $0.pid < $1.pid } }
        self.byPID = byPID
        self.children = children
    }

    /// Where "what the user started" ends going up the tree.
    func isBoundary(_ r: ProcRecord) -> Bool {
        r.pid <= 1
            || r.uid != world.currentUID
            || Recognizer.isGUIApp(r)
            || Recognizer.isAppleSystem(path: r.path)
            || Recognizer.isTerminalBoundary(r)
            || r.executableName == "login" || r.executableName == "sshd"
    }

    func isSelfOrBelowSelf(_ r: ProcRecord) -> Bool {
        var current: ProcRecord? = r
        var hops = 0
        while let c = current, hops < 64 {
            if c.pid == world.selfPID { return true }
            if c.ppid <= 1 { return false }
            current = byPID[c.ppid]
            hops += 1
        }
        return false
    }

    func root(of seed: ProcRecord) -> ProcRecord {
        if isBoundary(seed) || Recognizer.runtime(of: seed).isAgent { return seed }
        var current = seed
        var hops = 0
        while let parent = byPID[current.ppid], !isBoundary(parent), !Recognizer.runtime(of: parent).isAgent, hops < 64 {
            current = parent
            hops += 1
        }
        return current
    }

    func members(from root: ProcRecord, roots: Set<Int32>) -> [ProcRecord] {
        var out = [root]
        var queue = children[root.pid] ?? []
        while !queue.isEmpty {
            let next = queue.removeFirst()
            if roots.contains(next.pid) || isBoundary(next) || Recognizer.runtime(of: next).isAgent { continue }
            out.append(next)
            queue.append(contentsOf: children[next.pid] ?? [])
        }
        return out
    }

    func origin(of root: ProcRecord, labels: [Int32: String]) -> Origin {
        if Recognizer.isAppleSystem(path: root.path) { return .macOS }
        if Recognizer.isGUIApp(root), root.ppid <= 1 { return .application }
        guard root.ppid > 1, let parent = byPID[root.ppid] else {
            if let label = labels[root.pid] { return .launchd(label: label) }
            return root.ppid <= 1 ? .orphaned : .unknown
        }
        let parentRuntime = Recognizer.runtime(of: parent)
        if parentRuntime.isAgent {
            return .agent(parent.identity, name: parentRuntime.displayName)
        }
        if Recognizer.isTerminalBoundary(parent) {
            guard let tty = root.tty ?? parent.tty else { return .unknown }
            return .terminal(tty: tty, app: terminalApp(above: parent))
        }
        if Recognizer.isGUIApp(parent) {
            return .app(name: Recognizer.appName(path: parent.path) ?? parent.name)
        }
        return .unknown
    }

    /// The app that owns a terminal tab: the first GUI app (or multiplexer) above the shell.
    private func terminalApp(above shell: ProcRecord) -> String? {
        if Recognizer.isMultiplexer(shell) { return shell.launchName ?? shell.executableName }
        if Recognizer.isGUIApp(shell) { return Recognizer.appName(path: shell.path) }
        var current = byPID[shell.ppid]
        var hops = 0
        while let c = current, hops < 16 {
            if Recognizer.isMultiplexer(c) { return c.launchName ?? c.executableName }
            if Recognizer.isGUIApp(c) { return Recognizer.appName(path: c.path) }
            if c.ppid <= 1 { return nil }
            current = byPID[c.ppid]
            hops += 1
        }
        return nil
    }

    func tty(of root: ProcRecord, origin: Origin) -> String? {
        if let tty = root.tty { return tty }
        if case .agent(let parent, _) = origin { return byPID[parent.pid]?.tty }
        return nil
    }
}
