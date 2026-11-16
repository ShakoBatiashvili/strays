import Foundation

/// Remembers CPU usage over time, so "idle" means "quiet lately", not "quiet on average".
public struct ActivityTracker: Sendable {
    struct Sample: Sendable {
        var time: Date
        var cpu: Double
    }

    private var samples: [ProcIdentity: [Sample]] = [:]
    /// Samples closer together than this are skipped.
    static let spacing: TimeInterval = 60

    public init() {}

    public mutating func record(_ strays: [Stray], now: Date, window: TimeInterval = 3 * 3600) {
        for stray in strays {
            var list = samples[stray.id] ?? []
            if let last = list.last, now.timeIntervalSince(last.time) < Self.spacing { continue }
            list.append(Sample(time: now, cpu: stray.cpuSeconds))
            // Keep exactly one sample older than the window (the reference point), drop the rest.
            let cutoff = now.addingTimeInterval(-max(window, Self.spacing))
            while list.count > 1, list[1].time <= cutoff { list.removeFirst() }
            samples[stray.id] = list
        }
    }

    /// Drops history for processes that are gone.
    public mutating func forget(except alive: Set<ProcIdentity>) {
        samples = samples.filter { alive.contains($0.key) }
    }

    func sampleCount(for id: ProcIdentity) -> Int { samples[id]?.count ?? 0 }

    /// Average share of one CPU core over the last `window`, or nil without enough history.
    func recentShare(of stray: Stray, now: Date, window: TimeInterval) -> Double? {
        guard let reference = samples[stray.id]?.last(where: { now.timeIntervalSince($0.time) >= window }) else { return nil }
        let elapsed = now.timeIntervalSince(reference.time)
        guard elapsed > 0 else { return nil }
        return max(0, stray.cpuSeconds - reference.cpu) / elapsed
    }
}

public enum Staleness {
    public static func apply(_ strays: [Stray], now: Date, settings: Settings, activity: ActivityTracker) -> [Stray] {
        strays.map { stray in
            var copy = stray
            copy.tags = tags(for: stray, now: now, settings: settings, activity: activity)
            return copy
        }
    }

    public static func tags(for stray: Stray, now: Date, settings: Settings, activity: ActivityTracker) -> [StaleTag] {
        if stray.kind == .system { return [] }
        if case .launchd = stray.origin { return [] }   // services are meant to keep running

        var tags: [StaleTag] = []
        if stray.origin == .orphaned { tags.append(.orphaned) }
        if isIdle(stray, now: now, settings: settings, activity: activity) { tags.append(.idle) }
        if stray.age(at: now) >= settings.oldAge { tags.append(.old) }
        return tags
    }

    static func isIdle(_ stray: Stray, now: Date, settings: Settings, activity: ActivityTracker) -> Bool {
        let window = settings.idleWindow
        // AI sessions say themselves whether they are working and when they last did.
        if let session = stray.agentSession, session.status != .unknown {
            guard session.status == .idle, let updated = session.updatedAt else { return false }
            return now.timeIntervalSince(updated) >= window
        }
        guard stray.age(at: now) >= window else { return false }
        if let share = activity.recentShare(of: stray, now: now, window: window) {
            return share < settings.idleCPUShare
        }
        let lifetime = stray.cpuSeconds / max(stray.age(at: now), 1)
        return lifetime < settings.idleCPUShare
    }
}

/// A local notification's text.
public struct Notice: Equatable, Sendable {
    public var title: String
    public var body: String

    public init(title: String, body: String) {
        self.title = title
        self.body = body
    }
}

/// The once-a-day reminder about things left running.
public enum NudgePlanner {
    public static func shouldNudge(now: Date, staleCount: Int, lastNudgeDay: String?, settings: Settings,
                                   calendar: Calendar = .current) -> Bool {
        guard settings.nudgeEnabled, staleCount > 0 else { return false }
        let parts = calendar.dateComponents([.hour, .minute], from: now)
        let minute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        guard minute >= settings.nudgeMinute else { return false }
        return lastNudgeDay != dayKey(now, calendar: calendar)
    }

    public static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    public static func notice(for stale: [Stray], now: Date) -> Notice {
        let title = stale.count == 1 ? "1 thing still running" : "\(stale.count) things still running"
        var names: [String] = []
        var body = ""
        for stray in stale {
            var name = stray.title
            if let port = stray.ports.first { name += " :\(port)" }
            let candidate = (names + [name]).joined(separator: ", ")
            if candidate.count > 140 { break }
            names.append(name)
            body = candidate
        }
        let rest = stale.count - names.count
        if rest > 0 { body += " and \(rest) more" }
        return Notice(title: title, body: body)
    }
}
