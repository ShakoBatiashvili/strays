import Darwin
import Foundation
import StraysCore

public struct StopOutcome: Equatable, Sendable {
    /// Exited after SIGTERM.
    public var terminated: [Int32] = []
    /// Needed SIGKILL.
    public var killed: [Int32] = []
    /// Still running, could not be signalled, or changed owner (exec'd a setuid program).
    public var failed: [Int32] = []
    /// Not signalled: gone or no longer the same process when it was its turn.
    public var vanished: [Int32] = []
    /// Processes that appeared during the stop (a supervisor respawning a child) and were stopped too.
    public var lateArrivals: [Int32] = []

    public var succeeded: Bool { failed.isEmpty }
    public var stoppedCount: Int { terminated.count + killed.count + vanished.count }
}

/// Carries out a StopPlan:
/// 1. SIGSTOP the tree (and anything new below it, until nothing new appears), so nothing can respawn while we look;
/// 2. SIGTERM everything, then SIGCONT so each process can handle the request;
/// 3. wait for the grace period, stopping anything that still appears below a survivor;
/// 4. freeze the survivors the same way and SIGKILL them.
/// Every signal is preceded by a live check that the PID still belongs to the same process (start time and owner).
/// These are the only places Strays sends signals.
public enum Stopper {
    public static func execute(_ plan: StopPlan, grace: TimeInterval, spare: Set<Int32> = [],
                               currentUID: uid_t = getuid(), selfPID: Int32 = getpid(),
                               snapshot: () -> [ProcRecord] = { ProcessReader.treeSnapshot() },
                               sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }) -> StopOutcome {
        var outcome = StopOutcome()
        var known = Set(plan.targets.map(\.pid))
        var live: [ProcRecord] = []

        func freezeNewcomers(under parents: [ProcRecord], into list: inout [ProcRecord]) {
            for _ in 0..<6 {
                let fresh = StopPlanner.newDescendants(of: Set(parents.map(\.pid) + list.map(\.pid)), known: known,
                                                       records: snapshot(), currentUID: currentUID, selfPID: selfPID, spare: spare)
                if fresh.isEmpty { return }
                for p in fresh {
                    known.insert(p.pid)
                    if send(SIGSTOP, to: p, uid: currentUID) { list.append(p); outcome.lateArrivals.append(p.pid) }
                }
            }
        }

        // 1. Freeze.
        for target in plan.targets {
            if send(SIGSTOP, to: target, uid: currentUID) { live.append(target) } else { outcome.vanished.append(target.pid) }
        }
        freezeNewcomers(under: live, into: &live)

        // 2. Ask, then let them run to handle it.
        for target in live { _ = send(SIGTERM, to: target, uid: currentUID) }
        for target in live { _ = send(SIGCONT, to: target, uid: currentUID) }

        // 3. Wait, picking up anything spawned during shutdown.
        var pending = live
        let deadline = Date().addingTimeInterval(grace)
        var lastScan = Date()
        while !pending.isEmpty, Date() < deadline {
            sleep(0.1)
            pending.removeAll { target in
                switch state(of: target, uid: currentUID) {
                case .running: return false
                case .gone: outcome.terminated.append(target.pid); return true
                case .changedOwner: outcome.failed.append(target.pid); return true
                }
            }
            if Date().timeIntervalSince(lastScan) >= 0.5, !pending.isEmpty {
                lastScan = Date()
                let fresh = StopPlanner.newDescendants(of: Set(pending.map(\.pid)), known: known, records: snapshot(),
                                                       currentUID: currentUID, selfPID: selfPID, spare: spare)
                for p in fresh {
                    known.insert(p.pid)
                    if send(SIGTERM, to: p, uid: currentUID) { pending.append(p); outcome.lateArrivals.append(p.pid) }
                }
            }
        }

        // 4. Freeze what is left (and anything new below it), then kill.
        var survivors: [ProcRecord] = []
        for target in pending {
            if send(SIGSTOP, to: target, uid: currentUID) { survivors.append(target) } else { outcome.terminated.append(target.pid) }
        }
        if !survivors.isEmpty { freezeNewcomers(under: survivors, into: &survivors) }
        var dying: [ProcRecord] = []
        for target in survivors {
            if send(SIGKILL, to: target, uid: currentUID) { dying.append(target) } else { outcome.terminated.append(target.pid) }
        }
        let killDeadline = Date().addingTimeInterval(2)
        while !dying.isEmpty, Date() < killDeadline {
            sleep(0.05)
            dying.removeAll { target in
                switch state(of: target, uid: currentUID) {
                case .running: return false
                case .gone: outcome.killed.append(target.pid); return true
                case .changedOwner: outcome.failed.append(target.pid); return true
                }
            }
        }
        outcome.failed.append(contentsOf: dying.map(\.pid))
        return outcome
    }

    enum LiveState { case running, gone, changedOwner }

    static func state(of target: ProcRecord, uid: uid_t) -> LiveState {
        guard let live = ProcessReader.identity(of: target.pid), live.identity == target.identity else { return .gone }
        return live.uid == uid ? .running : .changedOwner
    }

    /// Signals only if the PID is still the same process, still yours.
    static func send(_ signal: Int32, to target: ProcRecord, uid: uid_t) -> Bool {
        guard state(of: target, uid: uid) == .running else { return false }
        return kill(target.pid, signal) == 0
    }
}
