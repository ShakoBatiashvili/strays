import Testing
@testable import StraysCore

struct StopPlannerTests {
    let records = Fixtures.records

    func id(_ pid: Int32, in records: [ProcRecord] = Fixtures.records) -> ProcIdentity {
        records.first { $0.pid == pid }!.identity
    }

    func plan(_ pids: [Int32], records: [ProcRecord] = Fixtures.records, selfPID: Int32 = 99999, spare: Set<Int32> = []) -> StopPlan {
        StopPlanner.plan(roots: pids.map { id($0, in: records) }, records: records, currentUID: Fixtures.me, selfPID: selfPID,
                         spare: spare)
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

    @Test func otherRowsInsideTheTreeAreLeftRunning() {
        // Stopping the Claude session leaves the dev server it started (its own row) running.
        let p = plan([63937], spare: [61224])
        #expect(p.targets.map(\.pid) == [63937, 63950, 63960, 63951])
        #expect(p.spared.map(\.pid) == [61224])
        // Selecting both stops both.
        #expect(plan([63937, 61224], spare: []).targets.count == 7)
    }

    @Test func spareComesFromTheOtherRows() {
        let strays = Fixtures.strays()
        let session = strays.first { $0.root.pid == 63937 }!
        let spare = StopPlanner.spare(selected: [session], among: strays)
        #expect(spare.contains(61224) && spare.contains(45392))
        #expect(!spare.contains(63937))
        #expect(!spare.contains(63950))   // its own helpers go with it
    }

    @Test func terminalShellsAppsAndMacOSAreNeverPartOfAStop() {
        var table = records
        table += [
            // An app that holds a port, with an integrated terminal running a dev server.
            Fixtures.p(900, 1, "/Applications/Editor.app/Contents/MacOS/Editor", ["Editor"], listen: [Fixtures.v4(51000)]),
            Fixtures.p(901, 900, "/bin/zsh", ["/bin/zsh", "-il"], tty: "ttys030"),
            Fixtures.p(902, 901, Fixtures.node, ["node", "next", "dev"], tty: "ttys030", listen: [Fixtures.v4(3000)]),
            // A dev server whose child is a GUI app (a test browser) and an Apple helper.
            Fixtures.p(910, 1, Fixtures.node, ["node", "e2e.js"], listen: [Fixtures.v4(4444)]),
            Fixtures.p(911, 910, "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome", ["Google Chrome"]),
            Fixtures.p(912, 910, "/usr/libexec/sometool", ["sometool"]),
            Fixtures.p(913, 910, Fixtures.node, ["node", "worker.js"]),
        ]
        table[table.firstIndex { $0.pid == 901 }!].isSessionLeader = true
        let editor = plan([900], records: table)
        #expect(editor.targets.map(\.pid) == [900])
        #expect(editor.spared.map(\.pid) == [901])
        let e2e = plan([910], records: table)
        #expect(e2e.targets.map(\.pid) == [910, 913])
        #expect(Set(e2e.spared.map(\.pid)) == [911, 912])
    }

    @Test func newDescendantsUseTheSameRules() {
        var table = records
        table.append(Fixtures.p(45700, 45583, Fixtures.node, ["node", "respawned.js"]))
        table.append(Fixtures.p(45701, 45583, "/bin/zsh", ["-zsh"], tty: "ttys031"))
        let fresh = StopPlanner.newDescendants(of: [45583], known: [45392, 45417, 45549, 45583], records: table,
                                               currentUID: Fixtures.me, selfPID: 99999, spare: [])
        #expect(fresh.map(\.pid) == [45700])
    }

    @Test func summary() {
        #expect(plan([45392]).summary == "4 processes")
        #expect(plan([42500]).summary == "1 process")
    }
}

struct StopPreviewTests {
    @Test func namesWhatALeftRunningTreeIs() {
        let strays = Fixtures.strays()
        let session = strays.first { $0.root.pid == 63937 }!
        var table = Fixtures.records
        table.append(Fixtures.p(64000, 63937, "/bin/zsh", ["-zsh"], tty: "ttys040"))
        let spare = StopPlanner.spare(selected: [session], among: strays)
        let plan = StopPlanner.plan(roots: [session.id], records: table, currentUID: Fixtures.me, selfPID: 99999, spare: spare)
        let preview = StopPreview(plan: plan, rows: strays)
        #expect(preview.processCount == 4)
        #expect(preview.leftRunning == ["acme :5173", "a terminal tab (ttys040)"])
    }
}
