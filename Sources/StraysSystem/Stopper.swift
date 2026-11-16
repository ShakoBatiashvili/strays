import Darwin
import Foundation
import StraysCore

public struct StopOutcome: Equatable, Sendable {
    /// Exited after SIGTERM.
    public var terminated: [Int32] = []
    /// Needed SIGKILL.
    public var killed: [Int32] = []
    /// Still running (or could not be signalled), with errno.
    public var failed: [Int32] = []
    /// Not signalled: gone or no longer the same process when it was its turn.
    public var vanished: [Int32] = []

    public var succeeded: Bool { failed.isEmpty }
    public var stoppedCount: Int { terminated.count + killed.count + vanished.count }
}

/// Carries out a StopPlan: SIGTERM to every target (root first), wait, SIGKILL what's left.
/// Every signal is preceded by a live check that the PID still belongs to the same process.
/// These are the only places Strays sends signals.
public enum Stopper {
    public static func execute(_ plan: StopPlan, grace: TimeInterval, currentUID: uid_t = getuid(),
                               sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }) -> StopOutcome {
        var outcome = StopOutcome()
        var pending: [ProcRecord] = []

        for target in plan.targets {
            guard isSameProcess(target, uid: currentUID) else { outcome.vanished.append(target.pid); continue }
            if kill(target.pid, SIGTERM) == 0 {
                pending.append(target)
            } else if errno == ESRCH {
                outcome.vanished.append(target.pid)
            } else {
                outcome.failed.append(target.pid)
            }
        }

        let deadline = Date().addingTimeInterval(grace)
        while !pending.isEmpty, Date() < deadline {
            sleep(0.1)
            pending.removeAll { target in
                if isSameProcess(target, uid: currentUID) { return false }
                outcome.terminated.append(target.pid)
                return true
            }
        }

        var survivors: [ProcRecord] = []
        for target in pending {
            guard isSameProcess(target, uid: currentUID) else { outcome.terminated.append(target.pid); continue }
            if kill(target.pid, SIGKILL) == 0 { survivors.append(target) } else { outcome.failed.append(target.pid) }
        }
        let killDeadline = Date().addingTimeInterval(2)
        while !survivors.isEmpty, Date() < killDeadline {
            sleep(0.05)
            survivors.removeAll { target in
                if isSameProcess(target, uid: currentUID) { return false }
                outcome.killed.append(target.pid)
                return true
            }
        }
        outcome.failed.append(contentsOf: survivors.map(\.pid))
        return outcome
    }

    static func isSameProcess(_ target: ProcRecord, uid: uid_t) -> Bool {
        guard let live = ProcessReader.identity(of: target.pid) else { return false }
        return live.identity == target.identity && live.uid == uid
    }
}
