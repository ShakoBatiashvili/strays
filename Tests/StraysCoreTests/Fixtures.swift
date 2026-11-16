import Foundation
@testable import StraysCore

/// A small, made-up process table shaped like a real developer Mac.
enum Fixtures {
    static let me: UInt32 = 501
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static let hour: Int64 = 3_600_000_000

    static func started(hoursAgo: Double) -> Int64 {
        Int64((now.timeIntervalSince1970 - hoursAgo * 3600) * 1_000_000)
    }

    static func p(_ pid: Int32, _ ppid: Int32, _ path: String?, _ args: [String], uid: UInt32 = me, name: String? = nil,
                  cwd: String? = nil, tty: String? = nil, hoursAgo: Double = 1, cpu: Double = 1, rss: UInt64 = 50_000_000,
                  listen: [ListeningSocket] = []) -> ProcRecord {
        let kernelName = name ?? path.map { String($0.split(separator: "/").last ?? "") } ?? args.first ?? "?"
        return ProcRecord(pid: pid, ppid: ppid, uid: uid, name: kernelName, path: path, arguments: args, cwd: cwd, tty: tty,
                          startMicros: started(hoursAgo: hoursAgo), cpuSeconds: cpu, residentBytes: rss, listening: listen)
    }

    static func v4(_ port: UInt16, _ address: String = "127.0.0.1") -> ListeningSocket {
        ListeningSocket(port: port, address: address, family: .ipv4)
    }

    static let node = "/opt/homebrew/Cellar/node/26.3.0/bin/node"
    static let acme = "/Users/dev/code/acme"
    static let novel = "/Users/dev/code/novel"
    static let claudeWrapper = "source /Users/dev/.claude/shell-snapshots/snapshot-zsh-1.sh 2>/dev/null || true && eval 'npm run dev' < /dev/null && pwd -P >| /tmp/claude-1-cwd"

    static let records: [ProcRecord] = [
        p(1, 0, "/sbin/launchd", ["/sbin/launchd"], uid: 0, hoursAgo: 200),
        // Terminal tab 4: a Claude Code session with two MCP helpers and a dev server it started.
        p(3056, 1, "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal", ["Terminal"], hoursAgo: 100),
        p(62268, 3056, "/usr/bin/login", ["login", "-pfl", "dev"], uid: 0, tty: "ttys004", hoursAgo: 50),
        p(62421, 62268, "/bin/zsh", ["-zsh"], cwd: acme, tty: "ttys004", hoursAgo: 50),
        p(63937, 62421, "/Users/dev/.local/share/claude/versions/2.1.319", ["claude"], name: "2.1.319", cwd: acme, tty: "ttys004",
          hoursAgo: 50, cpu: 600, rss: 400_000_000),
        p(63950, 63937, node, ["node", "/opt/homebrew/lib/node_modules/chrome-devtools-mcp/build/src/index.js"], cwd: acme, hoursAgo: 50),
        p(63951, 63950, node, ["node", "/opt/homebrew/lib/node_modules/chrome-devtools-mcp/build/src/telemetry/watchdog/main.js"],
          cwd: acme, hoursAgo: 50),
        p(63960, 63937, "/Users/dev/.local/share/uv/tools/blender-mcp/bin/python",
          ["/Users/dev/.local/share/uv/tools/blender-mcp/bin/python", "/Users/dev/.local/share/uv/tools/blender-mcp/bin/blender-mcp"],
          cwd: acme, hoursAgo: 50),
        p(61224, 63937, "/bin/zsh", ["/bin/zsh", "-c", claudeWrapper], cwd: acme, hoursAgo: 2),
        p(61230, 61224, node, ["npm run dev"], name: "node", cwd: acme, hoursAgo: 2),
        p(61231, 61230, node, ["node", "/Users/dev/code/acme/node_modules/.bin/vite"], cwd: acme, hoursAgo: 2, listen: [v4(5173)]),
        // A server whose terminal is gone: launchd adopted it.
        p(45392, 1, node, ["npm start"], name: "node", cwd: novel, hoursAgo: 9),
        p(45417, 45392, "/bin/sh", ["sh", "-c", "vite build && tsx src/server/main.ts"], cwd: novel, hoursAgo: 9),
        p(45549, 45417, node, ["node", "/Users/dev/code/novel/node_modules/.bin/tsx", "src/server/main.ts"], cwd: novel, hoursAgo: 9),
        p(45583, 45549, node, ["node", "--require", "/x/preflight.cjs", "src/server/main.ts"], cwd: novel, hoursAgo: 9,
          listen: [v4(5317, "*"), ListeningSocket(port: 5317, address: "::", family: .ipv6)]),
        // A brew service: launchd runs it on purpose.
        p(700, 1, "/opt/homebrew/opt/postgresql@16/bin/postgres", ["postgres", "-D", "/opt/homebrew/var/postgresql@16"],
          cwd: "/", hoursAgo: 100, listen: [v4(5432)]),
        // Apple's AirPlay Receiver and an app holding ports.
        p(683, 1, "/System/Library/CoreServices/ControlCenter.app/Contents/MacOS/ControlCenter", ["ControlCenter"],
          cwd: "/", hoursAgo: 200, listen: [v4(5000, "*"), v4(7000, "*")]),
        p(1380, 1, "/Applications/GitHub Desktop.app/Contents/MacOS/GitHub Desktop", ["GitHub Desktop"],
          cwd: "/", hoursAgo: 100, listen: [v4(49154)]),
        // App-launched helpers without ports stay hidden.
        p(80010, 1, "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome", ["Google Chrome"], hoursAgo: 30),
        p(80841, 80010, "/Users/dev/.local/bin/claude", ["/Users/dev/.local/bin/claude", "--chrome-native-host"], hoursAgo: 7),
        p(90000, 1, "/Applications/Cursor.app/Contents/MacOS/Cursor", ["Cursor"], hoursAgo: 30),
        p(90001, 90000, "/Applications/Cursor.app/Contents/Frameworks/Cursor Helper (Plugin).app/Contents/MacOS/Cursor Helper (Plugin)",
          ["Cursor Helper (Plugin)"], hoursAgo: 30),
        p(90002, 90001, "/Applications/Cursor.app/Contents/Resources/app/resources/helpers/node", ["node", "tsserver.js"], hoursAgo: 30),
        // Terminal tab 1: a plain worker script.
        p(42410, 3056, "/usr/bin/login", ["login", "-pfl", "dev"], uid: 0, tty: "ttys001", hoursAgo: 70),
        p(42420, 42410, "/bin/zsh", ["-zsh"], tty: "ttys001", hoursAgo: 70),
        p(42500, 42420, "/usr/bin/python3", ["python3", "worker.py"], cwd: acme, tty: "ttys001", hoursAgo: 30),
        // A headless Claude run by a launchd job.
        p(70000, 1, "/Users/dev/.local/bin/claude", ["claude", "-p", "summarize"], cwd: "/Users/dev", hoursAgo: 0.2),
        // Not ours, and ourselves: never listed.
        p(596, 1, "/Library/PrivilegedHelperTools/com.docker.vmnetd", ["com.docker.vmnetd"], uid: 0, hoursAgo: 200),
        p(99999, 1, "/Users/dev/Applications/Strays.app/Contents/MacOS/Strays", ["Strays"], hoursAgo: 1),
    ]

    static let projects: Set<String> = ["/Users/dev/code/acme/.git", "/Users/dev/code/novel/.git"]

    static func world(records: [ProcRecord] = records) -> World {
        World(records: records, currentUID: me, selfPID: 99999, home: "/Users/dev",
              launchdLabels: [700: "homebrew.mxcl.postgresql@16", 70000: "com.dev.standup", 1380: "application.com.github.GitHubClient.1"],
              agentSessions: [63937: AgentSessionInfo(pid: 63937, sessionID: "s-1", cwd: acme, name: "acme-2b", status: .idle,
                                                      updatedAt: now.addingTimeInterval(-65 * 3600), title: "Fix checkout bug")])
    }

    static func strays() -> [Stray] {
        StrayBuilder.build(world(), project: { ProjectResolver.resolve(cwd: $0, home: "/Users/dev", exists: projects.contains) })
    }
}
