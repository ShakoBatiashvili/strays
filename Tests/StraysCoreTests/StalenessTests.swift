import Foundation
import Testing
@testable import StraysCore

struct StalenessTests {
    let now = Fixtures.now
    let settings = Settings()

    private func stray(origin: Origin = .terminal(tty: "ttys001", app: "Terminal"), kind: StrayKind = .server,
                       hoursAgo: Double, cpu: Double, session: AgentSessionInfo? = nil) -> Stray {
        let root = Fixtures.p(500, 400, Fixtures.node, ["node", "server.js"], hoursAgo: hoursAgo, cpu: cpu)
        return Stray(kind: kind, root: root, members: [root], runtime: kind == .agent ? .claude : .node,
                     command: "node server.js", origin: origin, agentSession: session)
    }

    @Test func orphanedIsTagged() {
        let tags = Staleness.tags(for: stray(origin: .orphaned, hoursAgo: 1, cpu: 500), now: now, settings: settings, activity: ActivityTracker())
        #expect(tags == [.orphaned])
    }

    @Test func oldIsTaggedAfterTheThreshold() {
        let young = Staleness.tags(for: stray(hoursAgo: 23, cpu: 50_000), now: now, settings: settings, activity: ActivityTracker())
        let old = Staleness.tags(for: stray(hoursAgo: 25, cpu: 50_000), now: now, settings: settings, activity: ActivityTracker())
        #expect(young.isEmpty)
        #expect(old == [.old])
    }

    @Test func idleFromLifetimeAverageWhenThereIsNoHistory() {
        // 5 hours, 2 seconds of CPU: clearly idle. 5 hours, 10 minutes of CPU: busy.
        #expect(Staleness.tags(for: stray(hoursAgo: 5, cpu: 2), now: now, settings: settings, activity: ActivityTracker()) == [.idle])
        #expect(Staleness.tags(for: stray(hoursAgo: 5, cpu: 600), now: now, settings: settings, activity: ActivityTracker()).isEmpty)
        // Younger than the idle window: never idle yet.
        #expect(Staleness.tags(for: stray(hoursAgo: 2, cpu: 0), now: now, settings: settings, activity: ActivityTracker()).isEmpty)
    }

    @Test func idleFromObservedHistory() {
        // Busy all its life (lifetime average high), but quiet for the last 3+ hours.
        var activity = ActivityTracker()
        let busyThenQuiet = stray(hoursAgo: 10, cpu: 7_200)
        activity.record([busyThenQuiet], now: now.addingTimeInterval(-3.5 * 3600))
        let tags = Staleness.tags(for: busyThenQuiet, now: now, settings: settings, activity: activity)
        #expect(tags == [.idle])

        // Same history, but it used five minutes of CPU since: active.
        var active = ActivityTracker()
        active.record([stray(hoursAgo: 10, cpu: 6_900)], now: now.addingTimeInterval(-3.5 * 3600))
        #expect(Staleness.tags(for: busyThenQuiet, now: now, settings: settings, activity: active).isEmpty)
    }

    @Test func agentIdlenessComesFromTheSessionStatus() {
        let idle = AgentSessionInfo(pid: 500, sessionID: "a", status: .idle, updatedAt: now.addingTimeInterval(-4 * 3600))
        let recent = AgentSessionInfo(pid: 500, sessionID: "a", status: .idle, updatedAt: now.addingTimeInterval(-600))
        let busy = AgentSessionInfo(pid: 500, sessionID: "a", status: .busy, updatedAt: now.addingTimeInterval(-9 * 3600))
        func tags(_ s: AgentSessionInfo) -> [StaleTag] {
            Staleness.tags(for: stray(kind: .agent, hoursAgo: 5, cpu: 0, session: s), now: now, settings: settings, activity: ActivityTracker())
        }
        #expect(tags(idle) == [.idle])
        #expect(tags(recent).isEmpty)        // low CPU, but it answered 10 minutes ago
        #expect(tags(busy).isEmpty)
    }

    @Test func servicesAndSystemAreNeverStale() {
        let service = stray(origin: .launchd(label: "homebrew.mxcl.redis"), hoursAgo: 500, cpu: 1)
        let system = stray(kind: .system, hoursAgo: 500, cpu: 1)
        #expect(Staleness.tags(for: service, now: now, settings: settings, activity: ActivityTracker()).isEmpty)
        #expect(Staleness.tags(for: system, now: now, settings: settings, activity: ActivityTracker()).isEmpty)
    }

    @Test func tagsCombineInOrder() {
        let tags = Staleness.tags(for: stray(origin: .orphaned, hoursAgo: 30, cpu: 1), now: now, settings: settings, activity: ActivityTracker())
        #expect(tags == [.orphaned, .idle, .old])
    }

    @Test func applyTagsEveryStray() {
        let tagged = Staleness.apply(Fixtures.strays(), now: now, settings: settings, activity: ActivityTracker())
        let byPID = Dictionary(uniqueKeysWithValues: tagged.map { ($0.root.pid, $0.tags) })
        #expect(byPID[45392] == [.orphaned, .idle])   // 4 s of CPU over 9 h
        #expect(byPID[61224] == [])                   // started 2 h ago by Claude
        #expect(byPID[700] == [])                 // brew service
        #expect(byPID[63937] == [.idle, .old])    // Claude idle 65h, running 50h
    }

    @Test func trackerKeepsOneSampleOlderThanTheWindow() {
        var activity = ActivityTracker()
        let s = stray(hoursAgo: 20, cpu: 10)
        for minutes in stride(from: 600, through: 0, by: -5) {
            activity.record([s], now: now.addingTimeInterval(Double(-minutes) * 60))
        }
        let count = activity.sampleCount(for: s.id)
        #expect(count > 0 && count < 60)          // throttled and pruned, not 121 samples
        activity.forget(except: [])
        #expect(activity.sampleCount(for: s.id) == 0)
    }
}

struct NudgeTests {
    let settings = Settings()

    private func at(_ hour: Int, _ minute: Int = 0) -> Date {
        var c = DateComponents()
        c.year = 2026; c.month = 11; c.day = 16; c.hour = hour; c.minute = minute
        return Calendar.current.date(from: c)!
    }

    @Test func firesOnceAfterTheTimeWhenSomethingIsStale() {
        #expect(!NudgePlanner.shouldNudge(now: at(17, 59), staleCount: 3, lastNudgeDay: nil, settings: settings))
        #expect(NudgePlanner.shouldNudge(now: at(18, 0), staleCount: 3, lastNudgeDay: nil, settings: settings))
        #expect(NudgePlanner.shouldNudge(now: at(21, 30), staleCount: 1, lastNudgeDay: "2026-11-15", settings: settings))
        #expect(!NudgePlanner.shouldNudge(now: at(18, 5), staleCount: 3, lastNudgeDay: "2026-11-16", settings: settings))
        #expect(!NudgePlanner.shouldNudge(now: at(18, 5), staleCount: 0, lastNudgeDay: nil, settings: settings))
        var off = settings
        off.nudgeEnabled = false
        #expect(!NudgePlanner.shouldNudge(now: at(19), staleCount: 3, lastNudgeDay: nil, settings: off))
    }

    @Test func dayKeyIsLocal() {
        #expect(NudgePlanner.dayKey(at(0, 1)) == "2026-11-16")
        #expect(NudgePlanner.dayKey(at(23, 59)) == "2026-11-16")
    }

    @Test func messageNamesTheStrays() {
        let strays = Staleness.apply(Fixtures.strays(), now: Fixtures.now, settings: settings, activity: ActivityTracker()).filter(\.isStale)
        let notice = NudgePlanner.notice(for: strays, now: Fixtures.now)
        #expect(notice.title == "\(strays.count) things still running")
        #expect(notice.body.contains("novel :5317"))
        #expect(notice.body.count < 200)
    }
}
