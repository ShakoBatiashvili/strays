import Darwin
import Foundation
import StraysCore
import StraysSystem

// The `strays` command line tool: a thin wrapper over StraysCore and StraysSystem.

let useColor = isatty(STDOUT_FILENO) == 1 && ProcessInfo.processInfo.environment["NO_COLOR"] == nil

func bold(_ s: String) -> String { useColor ? "\u{1B}[1m\(s)\u{1B}[0m" : s }
func warn(_ s: String) -> String { useColor ? "\u{1B}[33m\(s)\u{1B}[0m" : s }

func printError(_ message: String) {
    FileHandle.standardError.write(Data("strays: \(message)\n".utf8))
}

/// Colours section headers and the stale marker; the text itself comes from TextReport.
func colorize(_ report: String) -> String {
    report.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
        let l = String(line)
        if !l.hasPrefix(" "), !l.isEmpty, l == l.uppercased() { return bold(l) }
        if let range = l.range(of: "⚠") { return String(l[..<range.lowerBound]) + warn(String(l[range.lowerBound...])) }
        return l
    }.joined(separator: "\n")
}

func confirm(_ question: String) -> Bool {
    print(question + " [y/N] ", terminator: "")
    fflush(stdout)
    guard let answer = readLine()?.trimmingCharacters(in: .whitespaces).lowercased() else { return false }
    return answer == "y" || answer == "yes"
}

let store = SettingsStore()
let settings = store.settings
let scanner = StraysScanner()
let now = Date()

func dockerContainers() -> [DockerContainer] {
    guard let client = DockerClient.discover() else { return [] }
    return (try? client.containers()) ?? []
}

func stop(_ rows: [Stray], among all: [Stray], records: [ProcRecord], yes: Bool) -> Int32 {
    let spare = StopPlanner.spare(selected: rows, among: all)
    let roots = rows.map(\.id)
    let preview = StopPreview(plan: StopPlanner.plan(roots: roots, records: records, currentUID: getuid(), selfPID: getpid(),
                                                     spare: spare), rows: all)
    for refusal in preview.plan.refused {
        let name = rows.first { $0.id == refusal.identity }?.title ?? "pid \(refusal.identity.pid)"
        printError("won't stop \(name): \(refusal.reason.message)")
    }
    guard !preview.plan.targets.isEmpty else { return 1 }

    let names = rows.filter { row in preview.plan.targets.contains { $0.pid == row.root.pid } }
        .map { row in row.ports.isEmpty ? row.title : "\(row.title) \(Formatting.ports(row.ports))" }
    print("Will stop \(names.joined(separator: ", ")): \(preview.plan.summary)")
    for target in preview.plan.targets { print("  \(target.pid)  \(Recognizer.commandLabel(of: target))") }
    if !preview.leftRunning.isEmpty { print("Leaves running: " + preview.leftRunning.joined(separator: ", ")) }
    if !preview.plan.skipped.isEmpty { print("Leaves alone \(preview.plan.skipped.count) process(es) owned by other users.") }

    if !yes {
        guard isatty(STDIN_FILENO) == 1 else {
            printError("not a terminal, so not asking: add -y to stop without confirmation")
            return 1
        }
        guard confirm("Stop \(preview.plan.summary)?") else { print("Nothing stopped."); return 1 }
    }

    // Plan again from a fresh snapshot: the tree may have changed while you read the list.
    let plan = StopPlanner.plan(roots: roots, records: ProcessReader.treeSnapshot(), currentUID: getuid(), selfPID: getpid(),
                                spare: spare)
    let outcome = Stopper.execute(plan, grace: settings.stopGraceSeconds, spare: spare)
    var message = "Stopped \(outcome.stoppedCount) of \(plan.targets.count + outcome.lateArrivals.count)."
    if !outcome.killed.isEmpty { message += " \(outcome.killed.count) ignored SIGTERM and were killed." }
    if !outcome.lateArrivals.isEmpty { message += " \(outcome.lateArrivals.count) appeared during the stop and were stopped too." }
    print(message)
    if !outcome.failed.isEmpty {
        printError("still running: " + outcome.failed.map(String.init).joined(separator: ", "))
        return 1
    }
    return 0
}

func run() -> Int32 {
    let command: CLICommand
    do {
        command = try CLI.parse(Array(CommandLine.arguments.dropFirst()))
    } catch {
        printError("\(error)")
        return 2
    }

    // Under sudo, "your processes" would mean root's: Strays is only meant to stop what you started.
    if getuid() == 0 {
        switch command {
        case .stop, .stale(stop: true, _, _):
            printError("run strays as yourself, not with sudo: it only stops your own processes")
            return 2
        default: break
        }
    }

    switch command {
    case .help:
        print(CLI.usage)
        return 0

    case .version:
        print("strays \(CLI.version)")
        return 0

    case .list(let all, let json):
        let containers = dockerContainers()
        let scanned = scanner.scan(settings: settings, activity: ActivityTracker(), now: now).strays
        let rows = DockerDedup.hidePublished(scanned, containers: containers).filter { all || $0.kind != .system }
        if json {
            print(StrayJSON.encode(rows, now: now))
        } else {
            print(colorize(TextReport.render(rows, now: now, containers: containers)))
        }
        return 0

    case .who(let port, let json):
        let rows = scanner.scan(settings: settings, activity: ActivityTracker(), now: now).strays.filter { $0.ports.contains(port) }
        if json {
            print(StrayJSON.encode(rows, now: now))
            return rows.isEmpty ? 1 : 0
        }
        if !rows.isEmpty {
            print(rows.map { TextReport.detail($0, now: now) }.joined(separator: "\n\n"))
            if let hint = PortHints.hint(port: port, holder: rows[0]) {
                print("\n" + hint)
            } else if rows[0].origin != .macOS {
                print("\nStop it: strays stop :\(port)")
            }
            return 0
        }
        if let container = dockerContainers().first(where: { $0.publishedPorts.contains(port) }) {
            print(":\(port) is published by Docker container \(container.title) (\(container.image), \(container.status)).")
            return 0
        }
        if PortAvailability.isFree(port) {
            print(":\(port) is free.")
            return 1
        }
        print(":\(port) is in use by a process Strays can't see (another user's, or macOS's).")
        if let hint = PortHints.hint(port: port, holder: nil) { print(hint) }
        return 0

    case .stop(let targets, let yes):
        let scan = scanner.scan(settings: settings, activity: ActivityTracker(), now: now)
        var rows: [Stray] = []
        for target in targets {
            switch CLI.resolve(target, in: scan.strays) {
            case .found(let row): if !rows.contains(where: { $0.id == row.id }) { rows.append(row) }
            case .notFound(let message), .ambiguous(let message):
                printError(message)
                return 1
            }
        }
        return stop(rows, among: scan.strays, records: scan.records, yes: yes)

    case .stale(let stopThem, let yes, let json):
        let scan = scanner.scan(settings: settings, activity: ActivityTracker(), now: now)
        let rows = scan.strays.filter(\.isStale)
        if json { print(StrayJSON.encode(rows, now: now)); return 0 }
        guard !rows.isEmpty else { print("Nothing stale."); return 0 }
        print(colorize(TextReport.render(rows, now: now)))
        guard stopThem else { return 0 }
        print("")
        return stop(rows, among: scan.strays, records: scan.records, yes: yes)
    }
}

exit(run())
