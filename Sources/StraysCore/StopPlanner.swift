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
    /// Descendants left running on purpose (and everything below them): terminal shells, apps, macOS,
    /// other AI sessions, and other rows that were not selected.
    public var spared: [ProcRecord] = []
    public var refused: [Refusal] = []

    public init(targets: [ProcRecord] = [], skipped: [ProcRecord] = [], spared: [ProcRecord] = [], refused: [Refusal] = []) {
        self.targets = targets
        self.skipped = skipped
        self.spared = spared
        self.refused = refused
    }

    public var summary: String { targets.count == 1 ? "1 process" : "\(targets.count) processes" }
}

public enum StopPlanner {
    /// Roots of the rows that were not selected: a stop never reaches into them.
    public static func spare(selected: [Stray], among all: [Stray]) -> Set<Int32> {
        let chosen = Set(selected.map(\.root.pid))
        return Set(all.map(\.root.pid)).subtracting(chosen)
    }

    public static func plan(roots: [ProcIdentity], records: [ProcRecord], currentUID: UInt32, selfPID: Int32,
                            spare: Set<Int32> = []) -> StopPlan {
        let tree = Tree(records)
        let protected = tree.selfAndAncestors(selfPID)

        var plan = StopPlan()
        var queued: Set<Int32> = []
        var frontier: [ProcRecord] = []

        for identity in roots {
            guard let live = tree.byPID[identity.pid], live.startMicros == identity.startMicros else {
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
        let level0 = frontier.filter { !tree.hasAncestor($0, in: queued) }
        let walk = descend(from: level0, tree: tree, currentUID: currentUID, protected: protected,
                           spare: spare.subtracting(queued), seen: Set(level0.map(\.pid)))
        plan.targets = level0 + walk.targets
        plan.skipped = walk.skipped
        plan.spared = walk.spared
        return plan
    }

    /// Processes that appeared below `parents` since the plan was made (a supervisor respawning a child),
    /// by the same rules as `plan`.
    public static func newDescendants(of parents: Set<Int32>, known: Set<Int32>, records: [ProcRecord], currentUID: UInt32,
                                      selfPID: Int32, spare: Set<Int32>) -> [ProcRecord] {
        let tree = Tree(records)
        let start = parents.compactMap { tree.byPID[$0] }
        let walk = descend(from: start, tree: tree, currentUID: currentUID, protected: tree.selfAndAncestors(selfPID),
                           spare: spare, seen: Set(start.map(\.pid)))
        return walk.targets.filter { !known.contains($0.pid) }
    }

    /// Breadth-first, level by level, stopping at everything a stop must not reach.
    private static func descend(from start: [ProcRecord], tree: Tree, currentUID: UInt32, protected: Set<Int32>,
                                spare: Set<Int32>, seen initial: Set<Int32>)
        -> (targets: [ProcRecord], skipped: [ProcRecord], spared: [ProcRecord]) {
        var seen = initial
        var targets: [ProcRecord] = [], skipped: [ProcRecord] = [], spared: [ProcRecord] = []
        var level = start
        while !level.isEmpty {
            var next: [ProcRecord] = []
            for parent in level {
                for child in tree.children[parent.pid] ?? [] where !seen.contains(child.pid) {
                    seen.insert(child.pid)
                    if protected.contains(child.pid) { continue }
                    if child.uid != currentUID { skipped.append(child); continue }
                    if spare.contains(child.pid) || isBoundary(child) { spared.append(child); continue }
                    next.append(child)
                }
            }
            targets += next
            level = next
        }
        return (targets, skipped, spared)
    }

    /// The same edges the row builder uses: a stop never crosses into a terminal tab, an app, macOS, or another AI session.
    static func isBoundary(_ r: ProcRecord) -> Bool {
        Recognizer.isTerminalBoundary(r)
            || Recognizer.isGUIApp(r)
            || Recognizer.isAppleSystem(path: r.path)
            || Recognizer.runtime(of: r).isAgent
            || r.executableName == "login" || r.executableName == "sshd"
    }

    private struct Tree {
        var byPID: [Int32: ProcRecord] = [:]
        var children: [Int32: [ProcRecord]] = [:]

        init(_ records: [ProcRecord]) {
            for r in records {
                byPID[r.pid] = r
                children[r.ppid, default: []].append(r)
            }
            for key in children.keys { children[key]?.sort { $0.pid < $1.pid } }
        }

        func selfAndAncestors(_ selfPID: Int32) -> Set<Int32> {
            var out: Set<Int32> = [selfPID]
            var cursor = byPID[selfPID]
            var hops = 0
            while let c = cursor, c.ppid > 0, hops < 64 {
                out.insert(c.ppid)
                cursor = byPID[c.ppid]
                hops += 1
            }
            return out
        }

        func hasAncestor(_ r: ProcRecord, in set: Set<Int32>) -> Bool {
            var cursor = byPID[r.ppid]
            var hops = 0
            while let c = cursor, hops < 64 {
                if set.contains(c.pid) { return true }
                if c.ppid <= 1 { return false }
                cursor = byPID[c.ppid]
                hops += 1
            }
            return false
        }
    }
}

/// What a person needs to see before confirming: how many processes, and what stays running.
public struct StopPreview: Equatable, Sendable {
    public var plan: StopPlan
    /// Human names for the trees left running on purpose ("acme :5173", "a terminal tab (ttys004)").
    public var leftRunning: [String]

    public var processCount: Int { plan.targets.count }

    public init(plan: StopPlan, rows: [Stray]) {
        self.plan = plan
        func all(_ rows: [Stray]) -> [Stray] { rows.flatMap { [$0] + all($0.helpers) } }
        let byRoot = Dictionary(all(rows).map { ($0.root.pid, $0) }, uniquingKeysWith: { first, _ in first })
        var names: [String] = []
        for record in plan.spared {
            let name: String
            if let row = byRoot[record.pid] {
                name = row.ports.isEmpty ? row.title : "\(row.title) \(Formatting.ports(row.ports))"
            } else if Recognizer.isTerminalBoundary(record) {
                name = record.tty.map { "a terminal tab (\($0))" } ?? "a shell"
            } else if Recognizer.runtime(of: record).isAgent {
                name = "an AI session (pid \(record.pid))"
            } else if let app = Recognizer.appName(path: record.path) {
                name = app
            } else if Recognizer.isAppleSystem(path: record.path) {
                name = "a macOS process"
            } else {
                name = Recognizer.commandLabel(of: record)
            }
            if !names.contains(name) { names.append(name) }
        }
        leftRunning = names
    }
}
