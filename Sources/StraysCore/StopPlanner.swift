import Foundation

public enum RefusalReason: String, Codable, Sendable {
    /// The process exited, or its PID now belongs to a different process.
    case gone
    /// Owned by another user (or root). Strays never asks for more rights than yours.
    case notYours
    /// One of Apple's system processes.
    case appleSystem
    /// Strays itself.
    case isStrays
    /// Strays is running inside this tree (stopping it would stop Strays mid-way).
    case runsStrays

    public var message: String {
        switch self {
        case .gone: "it already exited (or its PID was reused)"
        case .notYours: "it belongs to another user"
        case .appleSystem: "it is part of macOS"
        case .isStrays: "that is Strays itself"
        case .runsStrays: "Strays is running inside it"
        }
    }
}

public struct Refusal: Equatable, Sendable {
    public var identity: ProcIdentity
    public var reason: RefusalReason
}

/// Exactly which processes a Stop will signal, decided up front from one snapshot.
public struct StopPlan: Equatable, Sendable {
    /// Ordered roots first, then level by level, so supervisors stop before they can restart children.
    public var targets: [ProcRecord] = []
    /// Descendants that are not yours: left alone.
    public var skipped: [ProcRecord] = []
    public var refused: [Refusal] = []

    public var summary: String { targets.count == 1 ? "1 process" : "\(targets.count) processes" }
}

public enum StopPlanner {
    public static func plan(roots: [ProcIdentity], records: [ProcRecord], currentUID: UInt32, selfPID: Int32) -> StopPlan {
        var byPID: [Int32: ProcRecord] = [:]
        var children: [Int32: [ProcRecord]] = [:]
        for r in records {
            byPID[r.pid] = r
            children[r.ppid, default: []].append(r)
        }
        for key in children.keys { children[key]?.sort { $0.pid < $1.pid } }

        // Strays and everything above it.
        var protected: Set<Int32> = []
        var cursor = byPID[selfPID]
        protected.insert(selfPID)
        var hops = 0
        while let c = cursor, c.ppid > 0, hops < 64 {
            protected.insert(c.ppid)
            cursor = byPID[c.ppid]
            hops += 1
        }

        var plan = StopPlan()
        var queued: Set<Int32> = []
        var frontier: [ProcRecord] = []

        for identity in roots {
            guard let live = byPID[identity.pid], live.startMicros == identity.startMicros else {
                plan.refused.append(Refusal(identity: identity, reason: .gone)); continue
            }
            if queued.contains(live.pid) { continue }
            if live.pid == selfPID {
                plan.refused.append(Refusal(identity: identity, reason: .isStrays)); continue
            }
            if live.uid != currentUID || live.pid <= 1 {
                plan.refused.append(Refusal(identity: identity, reason: .notYours)); continue
            }
            if Recognizer.isAppleSystem(path: live.path) {
                plan.refused.append(Refusal(identity: identity, reason: .appleSystem)); continue
            }
            if protected.contains(live.pid) {
                plan.refused.append(Refusal(identity: identity, reason: .runsStrays)); continue
            }
            frontier.append(live)
            queued.insert(live.pid)
        }

        // Roots that sit inside another requested tree are reached through it; keep the order clean.
        var levels: [[ProcRecord]] = [frontier.filter { root in !hasQueuedAncestor(root, queued: queued, byPID: byPID) }]
        var seen = Set(levels[0].map(\.pid))
        while let level = levels.last, !level.isEmpty {
            var next: [ProcRecord] = []
            for parent in level {
                for child in children[parent.pid] ?? [] where !seen.contains(child.pid) {
                    seen.insert(child.pid)
                    if protected.contains(child.pid) { continue }
                    if child.uid != currentUID { plan.skipped.append(child); continue }
                    next.append(child)
                }
            }
            levels.append(next)
        }
        plan.targets = levels.flatMap { $0 }
        return plan
    }

    private static func hasQueuedAncestor(_ r: ProcRecord, queued: Set<Int32>, byPID: [Int32: ProcRecord]) -> Bool {
        var cursor = byPID[r.ppid]
        var hops = 0
        while let c = cursor, hops < 64 {
            if queued.contains(c.pid) { return true }
            if c.ppid <= 1 { return false }
            cursor = byPID[c.ppid]
            hops += 1
        }
        return false
    }
}
