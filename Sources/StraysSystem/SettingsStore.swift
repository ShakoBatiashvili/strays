import Darwin
import Foundation
import StraysCore

/// Settings live in the app's preferences domain, so the CLI and the app share them.
public final class SettingsStore: @unchecked Sendable {
    public static let domain = "io.github.shakobatiashvili.strays"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults? = nil) {
        if let defaults {
            self.defaults = defaults
        } else if Bundle.main.bundleIdentifier == Self.domain {
            self.defaults = .standard
        } else {
            self.defaults = UserDefaults(suiteName: Self.domain) ?? .standard
        }
    }

    public var settings: Settings {
        get {
            guard let data = defaults.data(forKey: "settings"),
                  let value = try? JSONDecoder().decode(Settings.self, from: data) else { return Settings() }
            return value
        }
        set {
            var clamped = newValue
            clamped.clamp()
            if let data = try? JSONEncoder().encode(clamped) { defaults.set(data, forKey: "settings") }
        }
    }

    public var lastNudgeDay: String? {
        get { defaults.string(forKey: "lastNudgeDay") }
        set { defaults.set(newValue, forKey: "lastNudgeDay") }
    }
}

/// Can this port be bound right now? Answers "is :3000 free?" even when the holder is
/// another user's process that Strays cannot see.
public enum PortAvailability {
    public static func isFree(_ port: UInt16) -> Bool {
        bindable(port, AF_INET) && bindable(port, AF_INET6)
    }

    private static func bindable(_ port: UInt16, _ family: Int32) -> Bool {
        let fd = socket(family, SOCK_STREAM, 0)
        guard fd >= 0 else { return true }
        defer { close(fd) }
        if family == AF_INET6 {
            var only: Int32 = 1   // test IPv6 on its own; IPv4 is tested separately
            setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &only, socklen_t(MemoryLayout<Int32>.size))
            var addr = sockaddr_in6()
            addr.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            addr.sin6_family = sa_family_t(AF_INET6)
            addr.sin6_port = port.bigEndian
            addr.sin6_addr = in6addr_any
            return withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) == 0 }
            } || errno != EADDRINUSE
        }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr = in_addr(s_addr: INADDR_ANY)
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 }
        } || errno != EADDRINUSE
    }
}

/// One refresh of everything, shared by the CLI and the app.
public final class StraysScanner: @unchecked Sendable {
    public let claude = ClaudeSessionReader()
    public let projects = ProjectCache()
    private var launchdCache: (time: Date, labels: [Int32: String])?
    private let lock = NSLock()

    public init() {}

    /// Rows with staleness applied, plus the raw records they came from (for stop planning).
    public func scan(settings: Settings, activity: ActivityTracker, now: Date = Date()) -> (strays: [Stray], records: [ProcRecord]) {
        let world = WorldReader.read(claude: claude, launchdLabels: launchdLabels(now: now))
        let strays = StrayBuilder.build(world, project: projects.resolve)
        return (Staleness.apply(strays, now: now, settings: settings, activity: activity), world.records)
    }

    /// launchd jobs change rarely; `launchctl list` runs at most every 30 seconds.
    private func launchdLabels(now: Date) -> [Int32: String] {
        lock.lock()
        if let cache = launchdCache, now.timeIntervalSince(cache.time) < 30 {
            lock.unlock()
            return cache.labels
        }
        lock.unlock()
        let labels = LaunchdReader.labels()
        lock.lock()
        launchdCache = (now, labels)
        lock.unlock()
        return labels
    }
}
