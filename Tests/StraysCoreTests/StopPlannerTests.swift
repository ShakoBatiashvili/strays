import Testing
@testable import StraysCore

struct StopPlannerTests {
    let records = Fixtures.records

    func id(_ pid: Int32, in records: [ProcRecord] = Fixtures.records) -> ProcIdentity {
        records.first { $0.pid == pid }!.identity
    }

    func plan(_ pids: [Int32], records: [ProcRecord] = Fixtures.records, selfPID: Int32 = 99999) -> StopPlan {
        StopPlanner.plan(roots: pids.map { id($0, in: records) }, records: records, currentUID: Fixtures.me, selfPID: selfPID)
    }

    @Test func wholeTreeRootFirst() {
        let p = plan([45392])
        #expect(p.targets.map(\.pid) == [45392, 45417, 45549, 45583])
        #expect(p.refused.isEmpty && p.skipped.isEmpty)
    }

    @Test func sessionTreeGoesLevelByLevel() {
        let p = plan([63937])
        #expect(p.targets.map(\.pid) == [63937, 61224, 63950, 63960, 61230, 63951, 61231])
    }

    @Test func overlappingRootsAreMergedOnce() {
        let p = plan([63937, 61224, 45392])
        #expect(p.targets.count == 7 + 4)
        #expect(Set(p.targets.map(\.pid)).count == p.targets.count)
    }

    @Test func recycledPIDIsRefused() {
        let stale = ProcIdentity(pid: 45392, startMicros: 1)
        let p = StopPlanner.plan(roots: [stale], records: records, currentUID: Fixtures.me, selfPID: 99999)
        #expect(p.targets.isEmpty)
        #expect(p.refused.map(\.reason) == [.gone])
    }

    @Test func refusals() {
        #expect(plan([62268]).refused.map(\.reason) == [.notYours])        // root-owned login
        #expect(plan([683]).refused.map(\.reason) == [.appleSystem])       // ControlCenter
        #expect(plan([99999]).refused.map(\.reason) == [.isStrays])
        #expect(plan([1]).refused.map(\.reason) == [.notYours])            // launchd is root's
    }

    @Test func neverStopsWhatStraysRunsInside() {
        // The CLI running inside a Claude session must not stop that session.
        var table = records
        table.append(Fixtures.p(88888, 61224, "/usr/local/bin/strays", ["strays", "stop"]))
        let p = plan([63937], records: table, selfPID: 88888)
        #expect(p.targets.isEmpty)
        #expect(p.refused.map(\.reason) == [.runsStrays])
        // Stopping a sibling tree is fine.
        #expect(plan([45392], records: table, selfPID: 88888).targets.count == 4)
    }

    @Test func otherUsersChildrenAreSkippedNotSignalled() {
        var table = records
        table.append(Fixtures.p(45600, 45583, "/usr/bin/sudo", ["sudo", "something"], uid: 0))
        let p = plan([45392], records: table)
        #expect(p.targets.map(\.pid) == [45392, 45417, 45549, 45583])
        #expect(p.skipped.map(\.pid) == [45600])
    }

    @Test func summary() {
        #expect(plan([45392]).summary == "4 processes")
        #expect(plan([42500]).summary == "1 process")
    }
}
