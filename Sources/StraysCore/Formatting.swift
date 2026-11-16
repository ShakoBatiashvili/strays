import Foundation

public enum Formatting {
    /// "<1m", "12m", "1h 12m", "3d 9h", "12d".
    public static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds))
        let minutes = total / 60
        let hours = minutes / 60
        let days = hours / 24
        if minutes < 1 { return "<1m" }
        if hours < 1 { return "\(minutes)m" }
        if days < 1 { return minutes % 60 == 0 ? "\(hours)h" : "\(hours)h \(minutes % 60)m" }
        if days >= 10 || hours % 24 == 0 { return "\(days)d" }
        return "\(days)d \(hours % 24)h"
    }

    /// Memory the way Activity Monitor shows it (binary units, "MB"/"GB" labels).
    public static func bytes(_ value: UInt64) -> String {
        if value == 0 { return "0 MB" }
        let mib = Double(value) / 1_048_576
        if mib < 1 { return String(format: "%.1f MB", mib) }
        if mib < 1024 { return String(format: "%.0f MB", mib) }
        return String(format: "%.1f GB", mib / 1024)
    }

    /// ":5000 :7000", at most three, then "+N".
    public static func ports(_ ports: [UInt16]) -> String {
        let shown = ports.prefix(3).map { ":\($0)" }.joined(separator: " ")
        return ports.count > 3 ? shown + " +\(ports.count - 3)" : shown
    }

    public static func cpuPercent(_ share: Double) -> String {
        let percent = share * 100
        return percent < 10 ? String(format: "%.1f%%", percent) : String(format: "%.0f%%", percent)
    }

    public static func origin(_ origin: Origin) -> String {
        switch origin {
        case .terminal(let tty, let app): app.map { "\($0) tab \(tty)" } ?? "tab \(tty)"
        case .agent(_, let name): "started by \(name)"
        case .app(let name): "started by \(name)"
        case .launchd(let label): "launchd: \(label)"
        case .orphaned: "no terminal (orphaned)"
        case .macOS: "part of macOS"
        case .application: "app"
        case .unknown: "parent unknown"
        }
    }

    public static func tag(_ tag: StaleTag) -> String {
        switch tag {
        case .orphaned: "orphaned"
        case .idle: "idle"
        case .old: "old"
        }
    }
}

/// Understands ":3000", "3000", "localhost:3000", "http://localhost:5173/x", "port 3000".
public enum PortQuery {
    public static func port(in text: String) -> UInt16? {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !s.isEmpty else { return nil }
        for scheme in ["http://", "https://"] where s.hasPrefix(scheme) { s.removeFirst(scheme.count) }
        if s.hasPrefix("port ") { s.removeFirst(5) }
        if let slash = s.firstIndex(of: "/") { s = String(s[..<slash]) }
        if let colon = s.lastIndex(of: ":") {
            let host = s[..<colon]
            let allowedHosts = ["", "localhost", "127.0.0.1", "0.0.0.0", "[::1]", "[::]", "*"]
            guard allowedHosts.contains(String(host)) else { return nil }
            s = String(s[s.index(after: colon)...])
        }
        guard !s.isEmpty, s.allSatisfy(\.isNumber), let value = Int(s), (1...65_535).contains(value) else { return nil }
        return UInt16(value)
    }
}

/// The search box: a port finds its holder, digits also find PIDs, anything else matches text.
public enum Filter {
    public static func apply(_ text: String, to strays: [Stray]) -> [Stray] {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return strays }

        if let port = PortQuery.port(in: query) {
            let pid = query.allSatisfy(\.isNumber) ? Int32(query) : nil
            return strays.filter { stray in
                stray.ports.contains(port) || (pid.map { p in stray.allMembers.contains { $0.pid == p } } ?? false)
            }
        }
        if query.allSatisfy(\.isNumber), let pid = Int32(query) {
            return strays.filter { $0.allMembers.contains { $0.pid == pid } }
        }
        let needle = query.lowercased()
        return strays.filter { haystack($0).contains(needle) }
    }

    static func haystack(_ stray: Stray) -> String {
        var parts: [String] = [stray.title, stray.command, stray.runtime.displayName, stray.runtime.rawValue]
        let optional: [String?] = [stray.project, stray.tty, stray.agentSession?.title, stray.agentSession?.name]
        parts.append(contentsOf: optional.compactMap { $0 })
        parts.append(contentsOf: stray.tags.map { Formatting.tag($0) })
        parts.append(Formatting.origin(stray.origin))
        parts.append(contentsOf: stray.helpers.map { $0.command })
        return parts.joined(separator: "\u{1}").lowercased()
    }
}

/// Explanations for ports that macOS itself holds, which people often trip over.
public enum PortHints {
    public static func hint(port: UInt16, holder: Stray?) -> String? {
        let isControlCenter = holder.map { $0.root.executableName == "ControlCenter" } ?? true
        if (port == 5000 || port == 7000), isControlCenter {
            return "That's macOS's AirPlay Receiver. To free :\(port), turn it off in System Settings > General > AirDrop & Handoff."
        }
        if let holder, holder.origin == .macOS {
            return "That's part of macOS, so Strays won't stop it."
        }
        return nil
    }
}
