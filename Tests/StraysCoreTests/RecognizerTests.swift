import Testing
@testable import StraysCore

private func proc(_ path: String?, _ args: [String], name: String? = nil, cwd: String? = "/Users/dev/code/acme") -> ProcRecord {
    let kernelName = name ?? path.map { String($0.split(separator: "/").last ?? "") } ?? (args.first ?? "?")
    return ProcRecord(pid: 100, ppid: 1, uid: 501, name: kernelName, path: path, arguments: args, cwd: cwd, startMicros: 0)
}

private let brewNode = "/opt/homebrew/Cellar/node/26.3.0/bin/node"
private let nvmNode = "/Users/dev/.nvm/versions/node/v24.22.2/bin/node"
private let fwPython = "/opt/homebrew/Cellar/python@3.12/3.12.9/Frameworks/Python.framework/Versions/3.12/Resources/Python.app/Contents/MacOS/Python"

struct RuntimeTests {
    static let cases: [(ProcRecord, Runtime)] = [
        (proc(brewNode, ["node", "server.js"]), .node),
        (proc(nvmNode, ["npm start"], name: "node"), .node),
        (proc("/opt/homebrew/bin/bun", ["bun", "run", "dev"]), .bun),
        (proc("/opt/homebrew/bin/deno", ["deno", "run", "-A", "main.ts"]), .deno),
        (proc(fwPython, [fwPython, "-m", "uvicorn", "app:app"], name: "Python"), .python),
        (proc("/usr/bin/python3", ["python3", "manage.py", "runserver"]), .python),
        (proc("/Users/dev/.local/share/uv/tools/blender-mcp/bin/python", ["python"]), .python),
        (proc("/opt/homebrew/opt/ruby/bin/ruby", ["ruby", "bin/rails", "server"]), .ruby),
        (proc("/usr/bin/java", ["java", "-jar", "app.jar"]), .java),
        (proc("/opt/homebrew/bin/php", ["php", "-S", "localhost:8000"]), .php),
        (proc("/private/var/folders/xy/abc/T/go-build123/b001/exe/main", ["main"]), .go),
        (proc("/Users/dev/code/acme/target/debug/acme-server", ["acme-server"]), .rust),
        (proc("/bin/zsh", ["-zsh"]), .shell),
        (proc("/bin/sh", ["sh", "-c", "vite build"]), .shell),
        (proc("/opt/homebrew/bin/pwsh", ["-pwsh"]), .shell),
        (proc("/opt/homebrew/bin/nu", ["nu", "--config", "/Users/dev/.config/nu/config.nu"]), .shell),
        (proc("/opt/homebrew/bin/elvish", ["elvish"]), .shell),
        (proc("/opt/homebrew/Cellar/xonsh/0.19/libexec/bin/python3.12", ["python3.12", "/opt/homebrew/bin/xonsh"]), .shell),
        (proc("/Users/dev/.local/share/claude/versions/2.1.319", ["claude"], name: "2.1.319"), .claude),
        (proc("/Users/dev/.local/bin/claude", ["/Users/dev/.local/bin/claude", "--chrome-native-host"]), .claude),
        (proc("/opt/homebrew/bin/codex", ["codex"]), .codex),
        (proc(brewNode, ["node", "/opt/homebrew/bin/gemini"]), .gemini),
        (proc("/Users/dev/.venv/bin/python", ["python", "/Users/dev/.local/bin/aider"]), .aider),
        (proc("/Applications/Docker.app/Contents/MacOS/com.docker.backend", ["com.docker.backend"]), .docker),
        (proc("/Applications/Cursor.app/Contents/MacOS/Cursor", ["Cursor"]), .other),
        (proc("/System/Library/CoreServices/ControlCenter.app/Contents/MacOS/ControlCenter", ["ControlCenter"]), .other),
    ]

    @Test(arguments: cases)
    func detectsRuntime(record: ProcRecord, expected: Runtime) {
        #expect(Recognizer.runtime(of: record) == expected)
    }

    @Test func agentsAreAgents() {
        #expect(Runtime.claude.isAgent && Runtime.codex.isAgent && Runtime.gemini.isAgent && Runtime.aider.isAgent)
        #expect(!Runtime.node.isAgent && !Runtime.shell.isAgent)
    }

    @Test func devRuntimes() {
        #expect(Runtime.node.isDevRuntime && Runtime.python.isDevRuntime && Runtime.claude.isDevRuntime)
        #expect(!Runtime.shell.isDevRuntime && !Runtime.other.isDevRuntime && !Runtime.docker.isDevRuntime)
    }
}

struct CommandLabelTests {
    static let cases: [(ProcRecord, String)] = [
        // Rewritten process titles are kept as they are.
        (proc(nvmNode, ["npm start"], name: "node"), "npm start"),
        (proc(brewNode, ["next-server (v15.1.0)"], name: "node"), "next-server (v15.1.0)"),
        // Package binaries and packages inside node_modules are named after the package.
        (proc(nvmNode, ["node", "/Users/dev/code/acme/node_modules/.bin/vite", "--port", "5173"]), "vite --port 5173"),
        (proc(nvmNode, ["node", "/Users/dev/code/acme/node_modules/.bin/tsx", "src/server/main.ts"]), "tsx src/server/main.ts"),
        (proc(brewNode, [brewNode, "/opt/homebrew/lib/node_modules/chrome-devtools-mcp/build/src/index.js"]), "chrome-devtools-mcp"),
        (proc(brewNode, ["node", "/Users/dev/.npm/_npx/9f1/node_modules/@modelcontextprotocol/server-filesystem/dist/index.js", "/Users/dev"]),
         "@modelcontextprotocol/server-filesystem dev"),
        // Global CLIs run through node.
        (proc(brewNode, ["node", "/opt/homebrew/bin/npm", "run", "dev"]), "npm run dev"),
        // Node options (and their values) before the script are skipped.
        (proc(nvmNode, ["node", "--require", "/x/tsx/dist/preflight.cjs", "--import", "file:///x/tsx/dist/loader.mjs", "src/server/main.ts"]),
         "node src/server/main.ts"),
        (proc(brewNode, ["node", "--inspect=9229", "server.js"]), "node server.js"),
        // Python.
        (proc(fwPython, [fwPython, "-m", "uvicorn", "app.main:app", "--reload"], name: "Python"), "uvicorn app.main:app --reload"),
        (proc("/usr/bin/python3", ["python3", "manage.py", "runserver"]), "python manage.py runserver"),
        (proc("/Users/dev/.venv/bin/python", ["/Users/dev/.venv/bin/python", "/Users/dev/.venv/bin/flask", "run"]), "flask run"),
        (proc("/Users/dev/.local/share/uv/tools/blender-mcp/bin/python",
              ["/Users/dev/.local/share/uv/tools/blender-mcp/bin/python", "/Users/dev/.local/share/uv/tools/blender-mcp/bin/blender-mcp"]),
         "blender-mcp"),
        (proc("/Users/dev/.cache/uv/environments-v2/server-3c57/bin/python3", ["/Users/dev/.cache/uv/environments-v2/server-3c57/bin/python3"]),
         "python3"),
        (proc("/usr/bin/python3", ["python3", "-c", "import http.server"]), "python -c import http.server"),
        // Shell wrappers show the command they run.
        (proc("/bin/sh", ["sh", "-c", "vite build && tsx src/server/main.ts"]), "vite build && tsx src/server/main.ts"),
        (proc("/bin/zsh", ["/bin/zsh", "-c", "source /Users/dev/.claude/shell-snapshots/s.sh 2>/dev/null || true && eval 'python3 -m http.server 8000 | grep '\"'\"'GET'\"'\"'' < /dev/null && pwd -P >| /tmp/c"]),
         "python3 -m http.server 8000 | grep 'GET'"),
        // Others: name plus arguments, absolute paths shortened.
        (proc("/opt/homebrew/bin/bun", ["bun", "run", "dev"]), "bun run dev"),
        (proc("/usr/bin/java", ["java", "-Xmx2g", "-jar", "/Users/dev/code/acme/build/app.jar"]), "java -Xmx2g -jar app.jar"),
        (proc("/Users/dev/code/acme/target/debug/acme-server", ["/Users/dev/code/acme/target/debug/acme-server", "--port", "8080"]),
         "acme-server --port 8080"),
        (proc("/Users/dev/.local/share/claude/versions/2.1.319", ["claude"], name: "2.1.319"), "claude"),
        (proc("/Users/dev/.local/bin/claude", ["/Users/dev/.local/bin/claude", "--chrome-native-host"]), "claude --chrome-native-host"),
        // No readable arguments: fall back to the executable name.
        (proc("/opt/homebrew/bin/redis-server", []), "redis-server"),
    ]

    @Test(arguments: cases)
    func labelsCommands(record: ProcRecord, expected: String) {
        #expect(Recognizer.commandLabel(of: record) == expected)
    }

    @Test func longCommandsAreTruncated() {
        let args = ["node", "server.js"] + (1...40).map { "--flag\($0)" }
        let label = Recognizer.commandLabel(of: proc(brewNode, args))
        #expect(label.count <= 80)
        #expect(label.hasSuffix("…"))
    }
}

struct ProcessKindTests {
    @Test func applePathsAreSystem() {
        #expect(Recognizer.isAppleSystem(path: "/System/Library/CoreServices/ControlCenter.app/Contents/MacOS/ControlCenter"))
        #expect(Recognizer.isAppleSystem(path: "/usr/libexec/rapportd"))
        #expect(Recognizer.isAppleSystem(path: "/usr/sbin/sshd"))
        #expect(!Recognizer.isAppleSystem(path: "/usr/bin/python3"))   // a dev runtime
        #expect(!Recognizer.isAppleSystem(path: "/opt/homebrew/bin/node"))
        #expect(!Recognizer.isAppleSystem(path: nil))
    }

    @Test func appBundlesAreApps() {
        #expect(Recognizer.appName(path: "/Applications/Cursor.app/Contents/MacOS/Cursor") == "Cursor")
        #expect(Recognizer.appName(path: "/Applications/Cursor.app/Contents/Frameworks/Cursor Helper (Plugin).app/Contents/MacOS/Cursor Helper (Plugin)") == "Cursor")
        #expect(Recognizer.appName(path: "/Applications/Docker.app/Contents/MacOS/com.docker.backend") == "Docker")
        #expect(Recognizer.appName(path: "/opt/homebrew/bin/node") == nil)
    }

    @Test func frameworkPythonIsNotAnApp() {
        let record = proc(fwPython, ["Python"], name: "Python")
        #expect(Recognizer.isGUIApp(record) == false)
    }

    @Test func terminalAndShells() {
        #expect(Recognizer.isGUIApp(proc("/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal", ["Terminal"])))
        #expect(Recognizer.isInteractiveShell(proc("/bin/zsh", ["-zsh"])))
        #expect(Recognizer.isInteractiveShell(proc("/bin/zsh", ["/bin/zsh"])))
        #expect(Recognizer.isInteractiveShell(proc("/bin/zsh", ["/bin/zsh", "-il"])))
        #expect(!Recognizer.isInteractiveShell(proc("/bin/zsh", ["/bin/zsh", "-c", "npm run dev"])))
        #expect(!Recognizer.isInteractiveShell(proc("/bin/zsh", ["zsh", "script.sh"])))
        #expect(!Recognizer.isInteractiveShell(proc(brewNode, ["node"])))
        #expect(!Recognizer.isInteractiveShell(proc("/bin/zsh", ["zsh", "-lc", "npm run dev"])))
        #expect(!Recognizer.isInteractiveShell(proc("/bin/bash", ["bash", "-ic", "make"])))
    }

    @Test func shellsPeopleTypeInto() {
        // Login shells of any kind, shells with only options, and option values that look like operands.
        #expect(Recognizer.isInteractiveShell(proc("/opt/homebrew/bin/pwsh", ["-pwsh"])))
        #expect(Recognizer.isInteractiveShell(proc("/bin/bash", ["bash", "--rcfile", "/tmp/nix-shell.abc"])))
        #expect(Recognizer.isInteractiveShell(proc("/opt/homebrew/bin/nu", ["nu", "--config", "/Users/dev/.config/nu/config.nu"])))
        #expect(Recognizer.isInteractiveShell(proc("/opt/homebrew/bin/fish", ["fish", "-l"])))
        #expect(!Recognizer.isInteractiveShell(proc("/opt/homebrew/bin/pwsh", ["pwsh", "-Command", "Get-Date"])))
        #expect(!Recognizer.isInteractiveShell(proc("/opt/homebrew/bin/nu", ["nu", "--commands", "ls"])))
        // Whatever leads a terminal session is the tab's own process, whatever it is.
        var leader = proc("/opt/homebrew/bin/some-shell", ["some-shell"])
        leader.isSessionLeader = true
        leader.tty = "ttys009"
        #expect(Recognizer.isTerminalBoundary(leader))
        leader.tty = nil
        #expect(!Recognizer.isTerminalBoundary(leader))     // a daemon that called setsid() is not a tab
    }
}
