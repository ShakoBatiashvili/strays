import Foundation

public enum StopTargetSpec: Equatable, Sendable {
    case port(UInt16)      // ":3000"
    case pid(Int32)        // "pid:1234"
    case number(Int)       // "3000": a port or a PID, whichever matches
}

public enum CLICommand: Equatable, Sendable {
    case list(all: Bool, json: Bool)
    case who(port: UInt16, json: Bool)
    case stop(targets: [StopTargetSpec], yes: Bool)
    case stale(stop: Bool, yes: Bool, json: Bool)
    case help
    case version
}

public enum CLIError: Error, Equatable, CustomStringConvertible {
    case unknownCommand(String)
    case unknownOption(String)
    case missingArgument(String)
    case badTarget(String)

    public var description: String {
        switch self {
        case .unknownCommand(let c): "unknown command '\(c)'. Try: strays help"
        case .unknownOption(let o): "unknown option '\(o)'. Try: strays help"
        case .missingArgument(let what): "missing \(what). Try: strays help"
        case .badTarget(let t): "'\(t)' is not a port (:3000) or a PID"
        }
    }
}

public enum CLI {
    public static let version = "0.1.0"

    public static let usage = """
    strays \(version): see and stop the dev servers, AI sessions and scripts you left running.

    USAGE
      strays [ls] [--all] [--json]   List servers, AI sessions and scripts (--all adds system & apps)
      strays who <port>              Who is listening on a port (:3000, 3000, localhost:3000)
      strays stop <target>... [-y]   Stop a row and everything it started. Target: :PORT, PID, or pid:PID
      strays stale [--stop] [-y]     List orphaned / idle / old rows (and stop them)
      strays help | version

    Stopping sends SIGTERM, waits (5 s by default), then SIGKILL. It asks first unless you pass -y.
    Strays never stops other users' processes, macOS itself, or the session it runs in.
    """

    public static func parse(_ arguments: [String]) throws -> CLICommand {
        var args = Array(arguments)
        let command = args.first.flatMap { $0.hasPrefix("-") ? nil : $0 } ?? "ls"
        if args.first == command { args.removeFirst() }

        var json = false, all = false, yes = false, stop = false
        var positional: [String] = []
        for arg in args {
            switch arg {
            case "--json": json = true
            case "--all", "-a": all = true
            case "--yes", "-y": yes = true
            case "--stop": stop = true
            case "--help", "-h": return .help
            default:
                if arg.hasPrefix("-") { throw CLIError.unknownOption(arg) }
                positional.append(arg)
            }
        }

        switch command {
        case "ls", "list":
            guard positional.isEmpty else { throw CLIError.unknownCommand(positional[0]) }
            return .list(all: all, json: json)
        case "who":
            guard let text = positional.first else { throw CLIError.missingArgument("port") }
            guard let port = PortQuery.port(in: text) else { throw CLIError.badTarget(text) }
            return .who(port: port, json: json)
        case "stop", "kill":
            guard !positional.isEmpty else { throw CLIError.missingArgument("what to stop (:PORT or PID)") }
            return .stop(targets: try positional.map(target), yes: yes)
        case "stale":
            return .stale(stop: stop, yes: yes, json: json)
        case "help": return .help
        case "version", "--version": return .version
        default:
            throw CLIError.unknownCommand(command)
        }
    }

    static func target(_ text: String) throws -> StopTargetSpec {
        if text.hasPrefix("pid:"), let pid = Int32(text.dropFirst(4)), pid > 0 { return .pid(pid) }
        if text.allSatisfy(\.isNumber), let n = Int(text), n > 0, n <= Int(Int32.max) { return .number(n) }
        if let port = PortQuery.port(in: text) { return .port(port) }
        throw CLIError.badTarget(text)
    }

    public enum Resolution: Equatable {
        case found(Stray)
        case notFound(String)
        case ambiguous(String)
    }

    /// Finds the row a target refers to. A bare number is a port or a PID, whichever matches.
    public static func resolve(_ target: StopTargetSpec, in strays: [Stray]) -> Resolution {
        func byPort(_ port: UInt16) -> Stray? { strays.first { $0.ports.contains(port) } }
        /// The innermost row: a helper's PID finds the helper, not the session around it.
        func byPID(_ pid: Int32) -> Stray? {
            func search(_ rows: [Stray]) -> Stray? {
                for row in rows {
                    if let inner = search(row.helpers) { return inner }
                    if row.members.contains(where: { $0.pid == pid }) { return row }
                }
                return nil
            }
            return search(strays)
        }
        switch target {
        case .port(let port):
            return byPort(port).map(Resolution.found) ?? .notFound("nothing of yours is listening on :\(port)")
        case .pid(let pid):
            return byPID(pid).map(Resolution.found) ?? .notFound("no listed process has PID \(pid)")
        case .number(let n):
            let port = n <= 65_535 ? byPort(UInt16(n)) : nil
            let process = byPID(Int32(n))
            switch (port, process) {
            case (let p?, nil): return .found(p)
            case (nil, let q?): return .found(q)
            case (let p?, let q?) where p.id == q.id: return .found(p)
            case (_?, _?): return .ambiguous("\(n) is both a port and a PID: use :\(n) or pid:\(n)")
            case (nil, nil): return .notFound("nothing listed has port or PID \(n)")
            }
        }
    }
}

/// Plain-text rendering for the CLI (and for tests).
public enum TextReport {
    public static func render(_ strays: [Stray], now: Date, containers: [DockerContainer] = []) -> String {
        var lines: [String] = []
        for kind in StrayKind.allCases {
            let rows = strays.filter { $0.kind == kind }
            guard !rows.isEmpty else { continue }
            if !lines.isEmpty { lines.append("") }
            lines.append("\(kind.title.uppercased()) (\(rows.count))")
            lines += rows.map { "  " + row($0, now: now) }
        }
        if !containers.isEmpty {
            if !lines.isEmpty { lines.append("") }
            lines.append("DOCKER CONTAINERS (\(containers.count))")
            for c in containers {
                let ports = Formatting.ports(c.publishedPorts)
                lines.append("  " + [pad(ports.isEmpty ? "-" : ports, 12), pad(c.title, 22), pad(c.image, 30), c.status].joined(separator: " "))
            }
        }
        if lines.isEmpty { return "Nothing running. Nice and tidy." }
        return lines.joined(separator: "\n")
    }

    public static func row(_ s: Stray, now: Date) -> String {
        let first = s.ports.isEmpty ? "pid \(s.root.pid)" : Formatting.ports(s.ports)
        let what: String
        if let title = s.agentSession?.title { what = "\"\(title)\"" } else { what = s.command }
        var detail = [Formatting.origin(s.origin)]
        if let session = s.agentSession, let updated = session.updatedAt, session.status != .unknown {
            detail.insert(session.status == .busy ? "working" : "idle \(Formatting.duration(now.timeIntervalSince(updated)))", at: 0)
        }
        if !s.helpers.isEmpty { detail.append("+\(s.helpers.count) helper\(s.helpers.count == 1 ? "" : "s")") }
        if !s.ports.isEmpty { detail.append("pid \(s.root.pid)") }
        if !s.tags.isEmpty { detail.append("⚠ " + s.tags.map(Formatting.tag).joined(separator: ", ")) }
        return [pad(first, 12), pad(s.project ?? "-", 22), pad(what, 34), pad("up " + Formatting.duration(s.age(at: now)), 10, right: false),
                detail.joined(separator: " · ")].joined(separator: " ")
    }

    public static func detail(_ s: Stray, now: Date) -> String {
        var lines = ["\(s.title) (\(s.kind.singular))"]
        if !s.ports.isEmpty { lines.append("  ports     " + s.sockets.map { "\($0.address):\($0.port)" }.joined(separator: "  ")) }
        lines.append("  command   \(s.command)")
        if let title = s.agentSession?.title { lines.append("  session   \(title)") }
        lines.append("  runtime   \(s.runtime.displayName)")
        lines.append("  running   \(Formatting.duration(s.age(at: now))) (since \(s.root.startDate.formatted(date: .abbreviated, time: .shortened)))")
        lines.append("  started   \(Formatting.origin(s.origin))")
        if let path = s.projectPath { lines.append("  folder    \(path)") }
        lines.append("  memory    \(Formatting.bytes(s.residentBytes)) across \(s.allMembers.count) process\(s.allMembers.count == 1 ? "" : "es")")
        if !s.tags.isEmpty { lines.append("  stale     " + s.tags.map(Formatting.tag).joined(separator: ", ")) }
        lines.append("  processes")
        for m in s.members { lines.append("    \(m.pid)  \(Recognizer.commandLabel(of: m))") }
        for h in s.helpers {
            for m in h.members { lines.append("    \(m.pid)  \(Recognizer.commandLabel(of: m))  (helper)") }
        }
        return lines.joined(separator: "\n")
    }

    static func pad(_ s: String, _ width: Int, right: Bool = false) -> String {
        let clipped = s.count > width ? String(s.prefix(width - 1)) + "…" : s
        let space = String(repeating: " ", count: max(0, width - clipped.count))
        return right ? space + clipped : clipped + space
    }
}

/// Stable JSON for scripting (`strays ls --json`).
public struct StrayJSON: Codable, Equatable {
    public var kind: String
    public var pid: Int32
    public var ports: [UInt16]
    public var project: String?
    public var folder: String?
    public var command: String
    public var runtime: String
    public var uptimeSeconds: Int
    public var origin: String
    public var tty: String?
    public var tags: [String]
    public var memoryBytes: UInt64
    public var cpuSeconds: Double
    public var pids: [Int32]
    public var session: Session?
    public var helpers: [StrayJSON]

    public struct Session: Codable, Equatable {
        public var name: String?
        public var title: String?
        public var status: String
        public var lastActive: Date?
    }

    public init(_ s: Stray, now: Date) {
        kind = s.kind.rawValue
        pid = s.root.pid
        ports = s.ports
        project = s.project
        folder = s.projectPath
        command = s.command
        runtime = s.runtime.rawValue
        uptimeSeconds = Int(s.age(at: now))
        origin = Formatting.origin(s.origin)
        tty = s.tty
        tags = s.tags.map(\.rawValue)
        memoryBytes = s.residentBytes
        cpuSeconds = (s.cpuSeconds * 10).rounded() / 10
        pids = s.members.map(\.pid)
        session = s.agentSession.map { Session(name: $0.name, title: $0.title, status: $0.status.rawValue, lastActive: $0.updatedAt) }
        helpers = s.helpers.map { StrayJSON($0, now: now) }
    }

    public static func encode(_ strays: [Stray], now: Date) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = (try? encoder.encode(strays.map { StrayJSON($0, now: now) })) ?? Data("[]".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}
