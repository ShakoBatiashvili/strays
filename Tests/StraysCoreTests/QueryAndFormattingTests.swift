import Foundation
import Testing
@testable import StraysCore

struct PortQueryTests {
    static let ports: [(String, UInt16?)] = [
        (":3000", 3000), ("3000", 3000), (" :3000 ", 3000), ("port 3000", 3000), ("localhost:3000", 3000),
        ("127.0.0.1:8080", 8080), ("http://localhost:5173/app", 5173), ("[::1]:9229", 9229),
        ("acme", nil), ("", nil), (":0", nil), ("70000", nil), ("v24", nil), ("3000a", nil),
    ]

    @Test(arguments: ports)
    func parsesPorts(text: String, expected: UInt16?) {
        #expect(PortQuery.port(in: text) == expected)
    }
}

struct FilterTests {
    let strays = Staleness.apply(Fixtures.strays(), now: Fixtures.now, settings: Settings(), activity: ActivityTracker())

    func match(_ text: String) -> [Int32] { Filter.apply(text, to: strays).map(\.root.pid) }

    @Test func emptyShowsEverything() { #expect(match("").count == strays.count) }

    @Test func portFindsTheHolder() {
        #expect(match(":5317") == [45392])
        #expect(match("5000") == [683])
        #expect(match(":3000").isEmpty)
    }

    @Test func textMatchesNamesCommandsTitlesAndHelpers() {
        #expect(match("novel") == [45392])
        #expect(match("NPM START") == [45392])
        #expect(match("checkout") == [63937])          // the session's title
        #expect(match("blender") == [63937])           // a helper's command
        #expect(match("ttys001") == [42500])
        #expect(match("orphaned") == [45392])          // tags are searchable too
        #expect(match("45583") == [45392])             // any member's PID
    }
}

struct FormattingTests {
    static let durations: [(Double, String)] = [
        (0, "<1m"), (59, "<1m"), (60, "1m"), (720, "12m"), (3_600, "1h"), (4_320, "1h 12m"),
        (86_340, "23h 59m"), (86_400, "1d"), (293_346, "3d 9h"), (12 * 86_400 + 7_200, "12d"),
    ]

    @Test(arguments: durations)
    func durations(seconds: Double, expected: String) {
        #expect(Formatting.duration(seconds) == expected)
    }

    @Test func absurdDurationsDoNotCrash() {
        #expect(Formatting.duration(.infinity) == "<1m")
        #expect(Formatting.duration(-.infinity) == "<1m")
        #expect(Formatting.duration(.nan) == "<1m")
        #expect(Formatting.duration(1e300) == Formatting.duration(Formatting.maxDuration))
        #expect(Formatting.duration(-1e300) == "<1m")
    }

    @Test func bytes() {
        #expect(Formatting.bytes(0) == "0 MB")
        #expect(Formatting.bytes(512_000) == "0.5 MB")
        #expect(Formatting.bytes(216_688 * 1024) == "212 MB")
        #expect(Formatting.bytes(1_610_612_736) == "1.5 GB")
    }

    @Test func ports() {
        #expect(Formatting.ports([5173]) == ":5173")
        #expect(Formatting.ports([5000, 7000]) == ":5000 :7000")
        #expect(Formatting.ports([1, 2, 3, 4, 5]) == ":1 :2 :3 +2")
    }

    @Test func origins() {
        #expect(Formatting.origin(.terminal(tty: "ttys004", app: "Terminal")) == "Terminal tab ttys004")
        #expect(Formatting.origin(.terminal(tty: "ttys004", app: nil)) == "tab ttys004")
        #expect(Formatting.origin(.orphaned) == "no terminal (orphaned)")
        #expect(Formatting.origin(.macOS) == "part of macOS")
        #expect(Formatting.origin(.launchd(label: "homebrew.mxcl.redis")) == "launchd: homebrew.mxcl.redis")
        #expect(Formatting.origin(.app(name: "Cursor")) == "started by Cursor")
        #expect(Formatting.origin(.agent(ProcIdentity(pid: 1, startMicros: 0), name: "Claude Code")) == "started by Claude Code")
    }
}
