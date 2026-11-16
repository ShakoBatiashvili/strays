import Foundation

/// The language runtime or tool behind a process.
public enum Runtime: String, Codable, Sendable, CaseIterable {
    case node, bun, deno, python, ruby, java, go, rust, php, dotnet, beam
    case claude, codex, gemini, aider, opencode
    case docker, shell, other

    /// AI coding sessions get their own section.
    public var isAgent: Bool {
        switch self {
        case .claude, .codex, .gemini, .aider, .opencode: true
        default: false
        }
    }

    /// Runtimes that make a process interesting even without a port.
    public var isDevRuntime: Bool {
        switch self {
        case .shell, .other, .docker: false
        default: true
        }
    }

    public var displayName: String {
        switch self {
        case .node: "Node"
        case .bun: "Bun"
        case .deno: "Deno"
        case .python: "Python"
        case .ruby: "Ruby"
        case .java: "Java"
        case .go: "Go"
        case .rust: "Rust"
        case .php: "PHP"
        case .dotnet: ".NET"
        case .beam: "Erlang/Elixir"
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .gemini: "Gemini CLI"
        case .aider: "Aider"
        case .opencode: "opencode"
        case .docker: "Docker"
        case .shell: "Shell"
        case .other: "Process"
        }
    }
}

/// Works out what a process is from its executable path and arguments. Pure string logic.
public enum Recognizer {
    // MARK: Runtime

    private static let agentNames: [String: Runtime] = [
        "claude": .claude, "codex": .codex, "gemini": .gemini, "aider": .aider, "opencode": .opencode,
    ]
    static let shells: Set<String> = ["zsh", "bash", "sh", "fish", "dash", "tcsh", "ksh", "csh", "nu", "pwsh", "elvish", "xonsh",
                                      "ion", "osh", "ysh", "oil", "mksh", "oksh", "yash", "rc", "es", "murex"]

    public static func runtime(of record: ProcRecord) -> Runtime {
        let exe = record.executableName
        let launch = record.launchName ?? exe
        let path = record.path ?? ""

        // AI agents: native binaries ("claude" lives at .../claude/versions/2.1.319) ...
        if path.contains("/claude/versions/") { return .claude }
        if let agent = agentNames[exe] ?? agentNames[launch] { return agent }

        let interpreter = interpreterRuntime(exe: exe, launch: launch, path: path)
        // ... or scripts run by an interpreter (gemini via node, aider via python). Some shells are scripts too (xonsh).
        if let interpreter, interpreter == .node || interpreter == .python || interpreter == .bun,
           let script = scriptArgument(record, interpreter: interpreter) {
            if let agent = agentNames[basename(script)] { return agent }
            if shells.contains(basename(script)) { return .shell }
        }
        if let interpreter { return interpreter }

        if exe.hasPrefix("com.docker.") || exe == "docker" || exe == "dockerd" { return .docker }
        if shells.contains(exe) || shells.contains(launch) { return .shell }
        if path.contains("/go-build") || exe == "go" { return .go }
        if path.contains("/target/debug/") || path.contains("/target/release/") || exe == "cargo" { return .rust }
        return .other
    }

    private static func interpreterRuntime(exe: String, launch: String, path: String) -> Runtime? {
        for name in [exe, launch] {
            switch name {
            case "node", "nodejs": return .node
            case "bun": return .bun
            case "deno": return .deno
            case "ruby": return .ruby
            case "java": return .java
            case "php", "php-fpm": return .php
            case "dotnet": return .dotnet
            case "beam.smp", "erl", "elixir", "iex", "mix": return .beam
            default:
                if name == "Python" || name == "python" || name.hasPrefix("python3") || name.hasPrefix("python2") {
                    return .python
                }
            }
        }
        if path.hasSuffix("/Python.app/Contents/MacOS/Python") { return .python }
        return nil
    }

    // MARK: Command label

    private static let maxLabel = 80

    /// A short command a person recognises: "npm run dev", "uvicorn app:app", "chrome-devtools-mcp".
    public static func commandLabel(of record: ProcRecord) -> String {
        truncate(Redactor.redact(rawLabel(of: record)))
    }

    private static func rawLabel(of record: ProcRecord) -> String {
        let args = record.arguments
        guard let first = args.first else { return displayExecutable(record) }

        // node's process.title (npm, next-server, puma...) rewrites argv into one readable string.
        if args.count == 1, first.contains(" "), !first.hasPrefix("/") { return first }

        let runtime = runtime(of: record)
        let interpreter = interpreterRuntime(exe: record.executableName, launch: record.launchName ?? "", path: record.path ?? "")
        switch interpreter ?? runtime {
        case .node:
            return nodeLabel(record)
        case .python:
            return pythonLabel(record)
        case .shell:
            if let c = args.firstIndex(of: "-c"), args.indices.contains(c + 1) { return unwrapEval(args[c + 1]) }
        default:
            break
        }
        let name = runtime == .claude ? "claude" : (record.launchName ?? displayExecutable(record))
        return ([name] + args.dropFirst().map(shortenPath)).joined(separator: " ")
    }

    /// Tools that run commands for you (Claude Code's Bash tool) wrap them as
    /// `… && eval '<command>' < /dev/null && …`. Show the command, not the wrapper.
    static func unwrapEval(_ script: String) -> String {
        guard let start = script.range(of: "eval '") else { return script }
        var out = ""
        var i = start.upperBound
        let quoteEscape = "'\"'\"'"   // '"'"' is how a quote inside single quotes is written
        while i < script.endIndex {
            if script[i...].hasPrefix(quoteEscape) {
                out.append("'")
                i = script.index(i, offsetBy: quoteEscape.count)
                continue
            }
            if script[i] == "'" { return out }
            out.append(script[i])
            i = script.index(after: i)
        }
        return script
    }

    private static func displayExecutable(_ record: ProcRecord) -> String {
        let exe = record.executableName
        // Version-named binaries (claude lives at .../versions/2.1.319): use what it was started as.
        if exe.first?.isNumber == true, let launch = record.launchName { return launch }
        return exe
    }

    private static let nodeOptionsWithValue: Set<String> = [
        "-r", "--require", "--import", "--loader", "--experimental-loader", "--inspect-port", "--title",
        "--env-file", "--conditions", "-C", "--max-old-space-size",
    ]
    private static let pythonOptionsWithValue: Set<String> = ["-W", "-X", "-Q"]

    /// Index of the script argument for an interpreter, skipping its own options.
    private static func scriptIndex(_ args: [String], optionsWithValue: Set<String>) -> Int? {
        var i = 1
        while i < args.count {
            let arg = args[i]
            if arg == "--" { return args.indices.contains(i + 1) ? i + 1 : nil }
            if arg.hasPrefix("-") {
                if optionsWithValue.contains(arg) { i += 2 } else { i += 1 }
                continue
            }
            return i
        }
        return nil
    }

    private static func scriptArgument(_ record: ProcRecord, interpreter: Runtime) -> String? {
        let options = interpreter == .python ? pythonOptionsWithValue : nodeOptionsWithValue
        if interpreter == .python, record.arguments.contains("-m") || record.arguments.contains("-c") { return nil }
        guard let index = scriptIndex(record.arguments, optionsWithValue: options) else { return nil }
        return record.arguments[index]
    }

    private static func nodeLabel(_ record: ProcRecord) -> String {
        let args = record.arguments
        guard let index = scriptIndex(args, optionsWithValue: nodeOptionsWithValue) else {
            return displayExecutable(record)
        }
        let script = args[index]
        let rest = args[(index + 1)...].map(shortenPath)
        if let package = packageName(fromScript: script) ?? globalBinName(script) {
            return ([package] + rest).joined(separator: " ")
        }
        return (["node", shortenPath(script)] + rest).joined(separator: " ")
    }

    private static func pythonLabel(_ record: ProcRecord) -> String {
        let args = record.arguments
        if let m = args.firstIndex(of: "-m"), args.indices.contains(m + 1) {
            return args[(m + 1)...].map(shortenPath).joined(separator: " ")
        }
        if let c = args.firstIndex(of: "-c"), args.indices.contains(c + 1) {
            return "python -c " + args[c + 1]
        }
        if let index = scriptIndex(args, optionsWithValue: pythonOptionsWithValue) {
            let script = args[index]
            let rest = args[(index + 1)...].map(shortenPath)
            // Console scripts installed into a bin folder (flask, uvicorn, blender-mcp) are commands.
            if script.contains("/bin/") {
                return ([basename(script)] + rest).joined(separator: " ")
            }
            return (["python", shortenPath(script)] + rest).joined(separator: " ")
        }
        // A tool installed with `uv tool install` runs from .../uv/tools/<name>/bin/python.
        if let tool = segment(after: "/uv/tools/", in: record.path ?? "") { return tool }
        return record.launchName ?? displayExecutable(record)
    }

    /// "…/node_modules/.bin/vite" -> "vite"; "…/node_modules/@scope/pkg/dist/x.js" -> "@scope/pkg".
    static func packageName(fromScript script: String) -> String? {
        guard let range = script.range(of: "/node_modules/", options: .backwards) else { return nil }
        let tail = script[range.upperBound...].split(separator: "/").map(String.init)
        guard let first = tail.first else { return nil }
        if first == ".bin" { return tail.count > 1 ? tail[1] : nil }
        if first.hasPrefix("@"), tail.count > 1 { return first + "/" + tail[1] }
        return first
    }

    /// "/opt/homebrew/bin/npm" -> "npm" (a global CLI, not a project file).
    private static func globalBinName(_ script: String) -> String? {
        guard script.hasPrefix("/"), script.contains("/bin/") else { return nil }
        let name = basename(script)
        return name.contains(".") ? nil : name
    }

    private static func segment(after marker: String, in path: String) -> String? {
        guard let range = path.range(of: marker) else { return nil }
        return path[range.upperBound...].split(separator: "/").first.map(String.init)
    }

    static func basename(_ path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }

    /// Absolute paths become their last component; everything else is left alone.
    static func shortenPath(_ arg: String) -> String {
        if arg.hasPrefix("file:///") { return basename(arg) }
        guard arg.hasPrefix("/"), arg.count > 1 else { return arg }
        return basename(arg)
    }

    private static func truncate(_ label: String) -> String {
        let flat = label.replacingOccurrences(of: "\n", with: " ")
        guard flat.count > maxLabel else { return flat }
        return String(flat.prefix(maxLabel - 1)) + "…"
    }

    // MARK: Process kinds

    /// Apple's own system processes (never offered for stopping).
    public static func isAppleSystem(path: String?) -> Bool {
        guard let path else { return false }
        return ["/System/", "/usr/libexec/", "/usr/sbin/", "/sbin/", "/Library/Apple/"].contains { path.hasPrefix($0) }
    }

    /// "Cursor" for anything inside /Applications/Cursor.app (helpers included).
    public static func appName(path: String?) -> String? {
        guard let path, let range = path.range(of: ".app/") else { return nil }
        let bundlePath = path[..<range.lowerBound]
        return bundlePath.split(separator: "/").last.map(String.init)
    }

    /// A GUI app or app helper, as opposed to a dev runtime that happens to live in a bundle (framework Python).
    public static func isGUIApp(_ record: ProcRecord) -> Bool {
        guard appName(path: record.path) != nil else { return false }
        return !runtime(of: record).isDevRuntime
    }

    /// Options whose next argument is a value, not a script to run.
    private static let shellOptionsWithValue: Set<String> = [
        "--rcfile", "--init-file", "-o", "+o", "-O", "+O", "--config", "--env-config", "--login-file", "-ConfigurationName",
        "-WorkingDirectory", "-wd", "-ExecutionPolicy", "-ex", "-SettingsFile", "--plugin-config",
    ]

    /// A shell a person types into, which is where "what I started" begins. Anything that is not clearly
    /// running a command or a script counts as interactive: erring this way keeps shells out of rows.
    public static func isInteractiveShell(_ record: ProcRecord) -> Bool {
        guard runtime(of: record) == .shell else { return false }
        if record.isLoginShell || record.isTerminalSessionLeader { return true }
        var args = Array(record.arguments.dropFirst())
        // xonsh runs as `python …/xonsh`: look at the shell's own arguments.
        if let shellIndex = args.firstIndex(where: { shells.contains(basename($0)) }) { args = Array(args[(shellIndex + 1)...]) }
        var i = 0
        while i < args.count {
            let arg = args[i]
            let lower = arg.lowercased()
            // -c (sh, zsh, bash, fish, nu), -Command / -File / -EncodedCommand (pwsh), --commands (nu).
            if ["-c", "-command", "--command", "--commands", "-encodedcommand", "-file"].contains(lower) { return false }
            // Combined short flags such as -lc or -ic run a command too.
            if arg.hasPrefix("-"), !arg.hasPrefix("--"), arg.count > 2, arg.dropFirst().contains("c") { return false }
            if shellOptionsWithValue.contains(arg) { i += 2; continue }
            if arg.hasPrefix("-") || arg.hasPrefix("+") { i += 1; continue }
            return false   // an operand: a script file
        }
        return true
    }

    /// Where a terminal tab begins: its session leader, an interactive shell, or a multiplexer.
    public static func isTerminalBoundary(_ record: ProcRecord) -> Bool {
        record.isTerminalSessionLeader || isInteractiveShell(record) || isMultiplexer(record)
    }

    /// Terminal multiplexers keep running after the tab closes; treat them like terminals.
    public static func isMultiplexer(_ record: ProcRecord) -> Bool {
        let name = record.launchName ?? record.executableName
        return name == "tmux" || name == "screen" || name == "zellij"
    }
}
