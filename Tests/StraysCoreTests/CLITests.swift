import Foundation
import Testing
@testable import StraysCore

struct CLIParseTests {
    @Test func defaultsToList() throws {
        #expect(try CLI.parse([]) == .list(all: false, json: false))
        #expect(try CLI.parse(["--json"]) == .list(all: false, json: true))
        #expect(try CLI.parse(["ls", "--all"]) == .list(all: true, json: false))
    }

    @Test func who() throws {
        #expect(try CLI.parse(["who", ":3000"]) == .who(port: 3000, json: false))
        #expect(try CLI.parse(["who", "localhost:5173", "--json"]) == .who(port: 5173, json: true))
        #expect(throws: CLIError.missingArgument("port")) { try CLI.parse(["who"]) }
        #expect(throws: CLIError.badTarget("acme")) { try CLI.parse(["who", "acme"]) }
    }

    @Test func stopTargets() throws {
        #expect(try CLI.parse(["stop", ":5317", "45583", "pid:12", "-y"])
                == .stop(targets: [.port(5317), .number(45583), .pid(12)], yes: true))
        #expect(throws: CLIError.self) { try CLI.parse(["stop"]) }
        #expect(throws: CLIError.badTarget("acme")) { try CLI.parse(["stop", "acme"]) }
    }

    @Test func staleAndMisc() throws {
        #expect(try CLI.parse(["stale"]) == .stale(stop: false, yes: false, json: false))
        #expect(try CLI.parse(["stale", "--stop", "--yes"]) == .stale(stop: true, yes: true, json: false))
        #expect(try CLI.parse(["help"]) == .help)
        #expect(try CLI.parse(["ls", "-h"]) == .help)
        #expect(try CLI.parse(["version"]) == .version)
        #expect(throws: CLIError.unknownCommand("frobnicate")) { try CLI.parse(["frobnicate"]) }
        #expect(throws: CLIError.unknownOption("--force")) { try CLI.parse(["stop", ":1", "--force"]) }
    }
}

struct CLIResolveTests {
    let strays = Fixtures.strays()

    @Test func portsAndPIDs() {
        #expect(CLI.resolve(.port(5317), in: strays) == .found(strays.first { $0.root.pid == 45392 }!))
        #expect(CLI.resolve(.pid(45583), in: strays) == .found(strays.first { $0.root.pid == 45392 }!))
        #expect(CLI.resolve(.pid(63951), in: strays) == .found(strays.first { $0.root.pid == 63937 }!))   // a helper's process
        if case .notFound = CLI.resolve(.port(3000), in: strays) {} else { Issue.record("expected notFound") }
    }

    @Test func bareNumbersPickWhateverMatches() {
        #expect(CLI.resolve(.number(5173), in: strays) == .found(strays.first { $0.root.pid == 61224 }!))
        #expect(CLI.resolve(.number(42500), in: strays) == .found(strays.first { $0.root.pid == 42500 }!))
        if case .notFound = CLI.resolve(.number(99), in: strays) {} else { Issue.record("expected notFound") }
    }

    @Test func ambiguousNumbersAsk() {
        // Make a PID that equals another row's port.
        var table = Fixtures.records
        table.append(Fixtures.p(5432, 42420, "/usr/bin/python3", ["python3", "job.py"], cwd: Fixtures.acme, tty: "ttys001"))
        let strays = StrayBuilder.build(Fixtures.world(records: table), project: { _ in nil })
        if case .ambiguous(let message) = CLI.resolve(.number(5432), in: strays) {
            #expect(message.contains(":5432") && message.contains("pid:5432"))
        } else {
            Issue.record("expected ambiguous")
        }
    }
}

struct TextReportTests {
    let strays = Staleness.apply(Fixtures.strays(), now: Fixtures.now, settings: Settings(), activity: ActivityTracker())

    @Test func listsSectionsWithCounts() {
        let text = TextReport.render(strays, now: Fixtures.now)
        #expect(text.contains("SERVERS (3)"))
        #expect(text.contains("AI SESSIONS (2)"))
        #expect(text.contains("SCRIPTS & WORKERS (1)"))
        #expect(text.contains("SYSTEM & APPS (2)"))
        #expect(text.contains(":5317"))
        #expect(text.contains("\"Fix checkout bug\""))
        #expect(text.contains("idle 2d 17h"))
        #expect(text.contains("⚠ orphaned, idle"))
        #expect(text.contains("+2 helpers"))
    }

    @Test func emptyIsFriendly() {
        #expect(TextReport.render([], now: Fixtures.now) == "Nothing running. Nice and tidy.")
    }

    @Test func detailListsEveryProcess() {
        let session = strays.first { $0.root.pid == 63937 }!
        let text = TextReport.detail(session, now: Fixtures.now)
        #expect(text.contains("63951"))
        #expect(text.contains("(helper)"))
        #expect(text.contains("Fix checkout bug"))
    }

    @Test func jsonRoundTrips() throws {
        let json = StrayJSON.encode(strays, now: Fixtures.now)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode([StrayJSON].self, from: Data(json.utf8))
        #expect(decoded.count == strays.count)
        let orphan = try #require(decoded.first { $0.pid == 45392 })
        #expect(orphan.ports == [5317])
        #expect(orphan.tags == ["orphaned", "idle"])
        #expect(orphan.pids == [45392, 45417, 45549, 45583])
        #expect(decoded.first { $0.pid == 63937 }?.helpers.count == 2)
    }
}
