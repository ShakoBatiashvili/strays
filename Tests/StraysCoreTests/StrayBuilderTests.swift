import Testing
@testable import StraysCore

struct StrayBuilderTests {
    let units = Fixtures.strays()

    func unit(_ pid: Int32) -> Stray? { units.first { $0.root.pid == pid } }
    func ofKind(_ kind: StrayKind) -> [Stray] { units.filter { $0.kind == kind } }

    @Test func serversAreSortedByPort() {
        #expect(ofKind(.server).map(\.ports) == [[5173], [5317], [5432]])
    }

    @Test func aServerStartedByClaudeIsItsOwnRowAndRemembersTheSession() throws {
        let vite = try #require(ofKind(.server).first)
        #expect(vite.root.pid == 61224)                 // the wrapper Claude's Bash tool started
        #expect(vite.members.map(\.pid) == [61224, 61230, 61231])
        #expect(vite.command == "npm run dev")
        #expect(vite.project == "acme")
        #expect(vite.projectPath == "/Users/dev/code/acme")
        #expect(vite.runtime == .node)
        #expect(vite.tty == "ttys004")                   // found through the session's tab
        guard case .agent(let id, _) = vite.origin else { Issue.record("origin \(vite.origin)"); return }
        #expect(id.pid == 63937)
    }

    @Test func orphanedServerKeepsItsWholeTree() throws {
        let server = try #require(unit(45392))
        #expect(server.kind == .server)
        #expect(server.origin == .orphaned)
        #expect(server.command == "npm start")
        #expect(server.project == "novel")
        #expect(server.members.map(\.pid) == [45392, 45417, 45549, 45583])
        #expect(server.ports == [5317])                  // IPv4 and IPv6 sockets on one port count once
        #expect(server.tty == nil)
    }

    @Test func brewServiceIsALaunchdJob() throws {
        let postgres = try #require(unit(700))
        #expect(postgres.kind == .server)
        #expect(postgres.origin == .launchd(label: "homebrew.mxcl.postgresql@16"))
        #expect(postgres.project == nil)                 // runs in /
        #expect(postgres.command == "postgres -D postgresql@16")
    }

    @Test func claudeSessionFoldsItsHelpers() throws {
        let session = try #require(unit(63937))
        #expect(session.kind == .agent)
        #expect(session.runtime == .claude)
        #expect(session.origin == .terminal(tty: "ttys004", app: "Terminal"))
        #expect(session.tty == "ttys004")
        #expect(session.project == "acme")
        #expect(session.helpers.map(\.command) == ["chrome-devtools-mcp", "blender-mcp"])
        #expect(session.helpers.first?.members.map(\.pid) == [63950, 63951])
        #expect(session.members.map(\.pid) == [63937])   // the dev server is its own row
        #expect(session.agentSession?.title == "Fix checkout bug")
        #expect(session.allMembers.count == 4)
    }

    @Test func headlessClaudeFromLaunchd() throws {
        let run = try #require(unit(70000))
        #expect(run.kind == .agent)
        #expect(run.origin == .launchd(label: "com.dev.standup"))
        #expect(run.project == nil)                      // home folder
    }

    @Test func plainScriptFromATerminalTab() throws {
        let worker = try #require(unit(42500))
        #expect(worker.kind == .script)
        #expect(worker.origin == .terminal(tty: "ttys001", app: "Terminal"))
        #expect(worker.command == "python worker.py")
    }

    @Test func systemAndAppPortHolders() {
        let system = ofKind(.system)
        #expect(system.map(\.root.pid) == [683, 1380])
        #expect(system.map(\.title) == ["ControlCenter", "GitHub Desktop"])
        #expect(system.first?.ports == [5000, 7000])
        #expect(system.map(\.origin) == [.macOS, .application])
    }

    @Test func appHelpersOtherUsersAndSelfAreHidden() {
        let listed = Set(units.flatMap(\.allMembers).map(\.pid))
        for hidden: Int32 in [80841, 90002, 596, 99999, 3056, 62421, 1] {
            #expect(!listed.contains(hidden), "pid \(hidden) should not be listed")
        }
    }

    @Test func everyProcessAppearsAtMostOnce() {
        let pids = units.flatMap(\.allMembers).map(\.pid)
        #expect(pids.count == Set(pids).count)
    }

    @Test func unknownShellsNeverJoinARow() {
        // A tab running pwsh (session leader) with vim open and a dev server started from it.
        var table = Fixtures.records
        table += [
            Fixtures.p(800, 3056, "/usr/bin/login", ["login", "-pfl", "dev"], uid: 0, tty: "ttys020"),
            Fixtures.p(801, 800, "/opt/homebrew/bin/pwsh", ["-pwsh"], tty: "ttys020"),
            Fixtures.p(802, 801, "/usr/bin/vim", ["vim", "notes.md"], tty: "ttys020"),
            Fixtures.p(803, 801, Fixtures.node, ["node", "/Users/dev/code/acme/node_modules/.bin/vite"], cwd: Fixtures.acme,
                       tty: "ttys020", listen: [Fixtures.v4(5199)]),
            // nix develop: a bash with --rcfile, then a server and an editor inside it.
            Fixtures.p(810, 42420, "/nix/store/abc-nix/bin/nix", ["nix", "develop"], cwd: Fixtures.acme, tty: "ttys001"),
            Fixtures.p(811, 810, "/nix/store/def-bash/bin/bash", ["bash", "--rcfile", "/tmp/nix-shell.x"], cwd: Fixtures.acme, tty: "ttys001"),
            Fixtures.p(812, 811, "/usr/bin/vim", ["vim", "x"], tty: "ttys001"),
            Fixtures.p(813, 811, Fixtures.node, ["npm run dev"], name: "node", cwd: Fixtures.acme, tty: "ttys001"),
            Fixtures.p(814, 813, Fixtures.node, ["node", "server.js"], cwd: Fixtures.acme, tty: "ttys001", listen: [Fixtures.v4(5299)]),
        ]
        table[table.firstIndex { $0.pid == 801 }!].isSessionLeader = true
        let strays = StrayBuilder.build(Fixtures.world(records: table), project: { _ in nil })
        let pwshServer = strays.first { $0.ports == [5199] }
        let nixServer = strays.first { $0.ports == [5299] }
        #expect(pwshServer?.members.map(\.pid) == [803])
        #expect(nixServer?.members.map(\.pid) == [813, 814])
        let listed = Set(strays.flatMap(\.allMembers).map(\.pid))
        for pid: Int32 in [801, 802, 810, 811, 812] { #expect(!listed.contains(pid), "pid \(pid) must not be in a row") }
    }

    @Test func kindOrder() {
        #expect(units.map(\.kind) == [.server, .server, .server, .agent, .agent, .script, .system, .system])
    }
}
