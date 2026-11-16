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

    @Test func kindOrder() {
        #expect(units.map(\.kind) == [.server, .server, .server, .agent, .agent, .script, .system, .system])
    }
}
