import Foundation

/// A process is identified by its PID *and* its start time, so a recycled PID is never
/// mistaken for the process the user saw (and never signalled by accident).
public struct ProcIdentity: Hashable, Codable, Sendable, CustomStringConvertible {
    public var pid: Int32
    /// Start time in microseconds since 1970, as the kernel reports it.
    public var startMicros: Int64

    public init(pid: Int32, startMicros: Int64) {
        self.pid = pid
        self.startMicros = startMicros
    }

    public var description: String { "\(pid)@\(startMicros)" }
}

/// One TCP socket in the LISTEN state.
public struct ListeningSocket: Hashable, Codable, Sendable {
    public enum Family: String, Codable, Sendable { case ipv4, ipv6 }

    public var port: UInt16
    /// "127.0.0.1", "::1", "*" (all IPv4 interfaces), "::" (all IPv6 interfaces), or a specific address.
    public var address: String
    public var family: Family

    public init(port: UInt16, address: String, family: Family) {
        self.port = port
        self.address = address
        self.family = family
    }

    /// Reachable only from this Mac.
    public var isLoopbackOnly: Bool {
        address == "127.0.0.1" || address == "::1" || address.hasPrefix("127.")
    }

    /// Reachable from other machines on the network.
    public var isExposed: Bool { !isLoopbackOnly }
}

/// A snapshot of one process, as read from the kernel.
public struct ProcRecord: Hashable, Codable, Sendable {
    public var pid: Int32
    public var ppid: Int32
    public var uid: UInt32
    /// The kernel's short name ("node", "claude", "Python").
    public var name: String
    /// Full path of the executable, when readable.
    public var path: String?
    /// argv as the process currently presents it (node's `process.title` rewrites it; so does npm).
    public var arguments: [String]
    /// Current working directory, when readable (own processes only).
    public var cwd: String?
    /// Controlling terminal ("ttys001"), nil when the process has none.
    public var tty: String?
    public var startMicros: Int64
    /// User + system CPU time used so far, in seconds.
    public var cpuSeconds: Double
    public var residentBytes: UInt64
    public var listening: [ListeningSocket]

    public init(pid: Int32, ppid: Int32, uid: UInt32, name: String, path: String? = nil,
                arguments: [String] = [], cwd: String? = nil, tty: String? = nil,
                startMicros: Int64, cpuSeconds: Double = 0, residentBytes: UInt64 = 0,
                listening: [ListeningSocket] = []) {
        self.pid = pid
        self.ppid = ppid
        self.uid = uid
        self.name = name
        self.path = path
        self.arguments = arguments
        self.cwd = cwd
        self.tty = tty
        self.startMicros = startMicros
        self.cpuSeconds = cpuSeconds
        self.residentBytes = residentBytes
        self.listening = listening
    }

    public var identity: ProcIdentity { ProcIdentity(pid: pid, startMicros: startMicros) }
    public var startDate: Date { Date(timeIntervalSince1970: Double(startMicros) / 1_000_000) }

    public func age(at now: Date) -> TimeInterval { max(0, now.timeIntervalSince(startDate)) }

    /// Basename of the executable path, falling back to the kernel name.
    public var executableName: String {
        if let path, let last = path.split(separator: "/").last, !last.isEmpty { return String(last) }
        return name
    }

    /// Basename of argv[0] without a login-shell dash ("-zsh" -> "zsh").
    public var launchName: String? {
        guard let first = arguments.first, !first.isEmpty else { return nil }
        var base = first.split(separator: "/").last.map(String.init) ?? first
        if base.hasPrefix("-") { base.removeFirst() }
        // A rewritten title such as "npm start" or "next-server (v15.1.0)": keep its first word.
        if let space = base.firstIndex(of: " ") { base = String(base[..<space]) }
        return base.isEmpty ? nil : base
    }

    /// Was started as a login shell ("-zsh").
    public var isLoginShell: Bool { arguments.first?.hasPrefix("-") == true }
}

/// Where a unit came from, which is also how a person finds it again.
public enum Origin: Hashable, Codable, Sendable {
    /// Started from a terminal tab that is still open. `app` is the app that owns the tab
    /// ("Terminal", "iTerm2", "Cursor", "tmux"), when known.
    case terminal(tty: String, app: String?)
    /// Started by an AI coding session (identified by the session's root process).
    case agent(ProcIdentity, name: String)
    /// Started by a GUI app (Chrome, Cursor, Docker Desktop...).
    case app(name: String)
    /// A launchd job (brew services, login agents). Meant to run in the background.
    case launchd(label: String)
    /// Its parent went away and launchd adopted it: nobody is watching this one.
    case orphaned
    case unknown
}

public enum StrayKind: String, Codable, Sendable, CaseIterable {
    case server       // listens on a TCP port
    case agent        // an AI coding session (Claude Code, Codex, ...)
    case script       // a dev runtime without a port (watchers, workers, scripts)
    case system       // Apple or app processes that hold a port

    public var title: String {
        switch self {
        case .server: "Servers"
        case .agent: "AI sessions"
        case .script: "Scripts & workers"
        case .system: "System & apps"
        }
    }
}

public enum StaleTag: String, Codable, Sendable, CaseIterable, Comparable {
    /// Lost its terminal or parent session; launchd adopted it.
    case orphaned
    /// Hasn't used meaningful CPU (or the AI session has been idle) for the idle threshold.
    case idle
    /// Running longer than the "old" threshold.
    case old

    public static func < (lhs: StaleTag, rhs: StaleTag) -> Bool {
        allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
    }
}

/// Status published by Claude Code in ~/.claude/sessions/<pid>.json.
public struct AgentSessionInfo: Hashable, Codable, Sendable {
    public enum Status: String, Codable, Sendable { case idle, busy, unknown }

    public var pid: Int32
    public var sessionID: String
    public var cwd: String?
    /// Claude's short session name ("myproject-2b").
    public var name: String?
    public var status: Status
    /// Last time the session reported activity.
    public var updatedAt: Date?
    /// The user's /rename title, else Claude's AI title for the conversation.
    public var title: String?

    public init(pid: Int32, sessionID: String, cwd: String? = nil, name: String? = nil,
                status: Status = .unknown, updatedAt: Date? = nil, title: String? = nil) {
        self.pid = pid
        self.sessionID = sessionID
        self.cwd = cwd
        self.name = name
        self.status = status
        self.updatedAt = updatedAt
        self.title = title
    }
}

/// What the UI shows as one row: a root process plus everything it started.
public struct Stray: Hashable, Codable, Sendable, Identifiable {
    public var id: ProcIdentity { root.identity }

    public var kind: StrayKind
    public var root: ProcRecord
    /// Every process in the unit, root first.
    public var members: [ProcRecord]
    public var runtime: Runtime
    /// Project folder name ("acme-web"), when the unit runs inside a project.
    public var project: String?
    /// Project root folder (git root or nearest package manifest).
    public var projectPath: String?
    /// Short human command ("npm run dev", "uvicorn app:main", "chrome-devtools-mcp").
    public var command: String
    public var origin: Origin
    /// Tab the unit can be found in: the root's tty, or the tty of the session that started it.
    public var tty: String?
    /// Helper units folded under this one (an AI session's MCP servers).
    public var helpers: [Stray]
    public var agentSession: AgentSessionInfo?
    public var tags: [StaleTag]

    public init(kind: StrayKind, root: ProcRecord, members: [ProcRecord], runtime: Runtime,
                project: String? = nil, projectPath: String? = nil, command: String,
                origin: Origin, tty: String? = nil, helpers: [Stray] = [],
                agentSession: AgentSessionInfo? = nil, tags: [StaleTag] = []) {
        self.kind = kind
        self.root = root
        self.members = members
        self.runtime = runtime
        self.project = project
        self.projectPath = projectPath
        self.command = command
        self.origin = origin
        self.tty = tty
        self.helpers = helpers
        self.agentSession = agentSession
        self.tags = tags
    }

    /// All listening sockets in the unit (helpers excluded), de-duplicated by port.
    public var sockets: [ListeningSocket] {
        var seen = Set<UInt16>()
        var out: [ListeningSocket] = []
        for socket in members.flatMap(\.listening).sorted(by: { $0.port < $1.port }) where seen.insert(socket.port).inserted {
            out.append(socket)
        }
        return out
    }

    public var ports: [UInt16] { sockets.map(\.port) }

    /// Processes in the unit and its helpers.
    public var allMembers: [ProcRecord] { members + helpers.flatMap(\.allMembers) }

    public var residentBytes: UInt64 { allMembers.reduce(0) { $0 + $1.residentBytes } }
    public var cpuSeconds: Double { allMembers.reduce(0) { $0 + $1.cpuSeconds } }

    public func age(at now: Date) -> TimeInterval { root.age(at: now) }

    public var isStale: Bool { !tags.isEmpty }

    /// The name a person recognises first.
    public var title: String { project ?? command }
}
