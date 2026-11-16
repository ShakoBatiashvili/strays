import Darwin
import Foundation
import Testing
@testable import StraysCore
@testable import StraysSystem

/// Starts a real helper process for a test and makes sure it is gone afterwards.
final class Spawned {
    let process = Process()
    private let output = Pipe()

    init(_ executable: String, _ arguments: [String]) throws {
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    var pid: Int32 { process.processIdentifier }

    /// First line the helper prints (the port it bound).
    func firstLine(timeout: TimeInterval = 10) -> String? {
        let handle = output.fileHandleForReading
        var data = Data()
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            data.append(chunk)
            if let text = String(data: data, encoding: .utf8), let line = text.split(separator: "\n").first, text.contains("\n") {
                return String(line)
            }
        }
        return nil
    }

    deinit {
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }
}

private let python = "/usr/bin/python3"

/// A TCP listener that never answers.
private let silentListener = """
import socket, time
s = socket.socket(); s.bind(("127.0.0.1", 0)); s.listen()
print(s.getsockname()[1], flush=True)
time.sleep(120)
"""

/// A tiny HTTP server.
private let httpServer = """
import http.server, socketserver
class Quiet(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *a): pass
with socketserver.TCPServer(("127.0.0.1", 0), Quiet) as httpd:
    print(httpd.server_address[1], flush=True)
    httpd.serve_forever()
"""

@Suite(.serialized)
struct ProcessReaderTests {
    @Test func readsItsOwnProcess() throws {
        let me = try #require(ProcessReader.record(pid: getpid()))
        #expect(me.uid == getuid())
        #expect(me.ppid == getppid())
        #expect(me.arguments.isEmpty == false)
        #expect(me.cwd == FileManager.default.currentDirectoryPath)
        #expect(me.residentBytes > 1_000_000)
        #expect(me.startDate < Date() && me.startDate > Date().addingTimeInterval(-3600))
    }

    @Test func findsAListeningSocketAndItsArguments() throws {
        let helper = try Spawned(python, ["-c", silentListener])
        let port = try #require(helper.firstLine().flatMap { UInt16($0) })
        let record = try #require(ProcessReader.record(pid: helper.pid))
        #expect(record.listening.contains(ListeningSocket(port: port, address: "127.0.0.1", family: .ipv4)))
        #expect(record.arguments.contains("-c"))
        #expect(Recognizer.runtime(of: record) == .python)
    }

    @Test func snapshotSeesOtherUsersOnlyAsOutlines() throws {
        let all = ProcessReader.snapshot()
        #expect(all.count > 50)
        let launchd = try #require(all.first { $0.pid == 1 })
        #expect(launchd.uid == 0)
        #expect(launchd.arguments.isEmpty)     // not ours: no detail
        #expect(all.contains { $0.pid == getpid() && !$0.arguments.isEmpty })
    }

    @Test func identityChangesWithTheProcess() throws {
        let helper = try Spawned("/bin/sleep", ["30"])
        let first = try #require(ProcessReader.identity(of: helper.pid))
        #expect(first.uid == getuid())
        kill(helper.pid, SIGKILL)
        helper.process.waitUntilExit()
        #expect(ProcessReader.identity(of: helper.pid)?.identity != first.identity)
    }
}

@Suite(.serialized)
struct PortProbeTests {
    @Test func recognisesHTTP() throws {
        let helper = try Spawned(python, ["-c", httpServer])
        let port = try #require(helper.firstLine().flatMap { UInt16($0) })
        #expect(PortProbe.probe(port: port) == .http)
    }

    @Test func silentPortIsNotHTTP() throws {
        let helper = try Spawned(python, ["-c", silentListener])
        let port = try #require(helper.firstLine().flatMap { UInt16($0) })
        #expect(PortProbe.probe(port: port, timeout: 0.3) == .other)
    }

    @Test func closedPortIsNotHTTP() {
        #expect(PortProbe.probe(port: 1, timeout: 0.2) == .other)
    }
}

@Suite(.serialized)
struct StopperTests {
    @Test func stopsAWholeTree() throws {
        let helper = try Spawned("/bin/sh", ["-c", "/bin/sleep 300 & /bin/sleep 300 & wait"])
        Thread.sleep(forTimeInterval: 0.3)
        let records = ProcessReader.snapshot()
        let root = try #require(records.first { $0.pid == helper.pid })
        let plan = StopPlanner.plan(roots: [root.identity], records: records, currentUID: getuid(), selfPID: getpid())
        #expect(plan.targets.count == 3)

        let outcome = Stopper.execute(plan, grace: 3)
        #expect(outcome.succeeded)
        #expect(outcome.stoppedCount == 3)
        for target in plan.targets { #expect(ProcessReader.identity(of: target.pid)?.identity != target.identity) }
    }

    @Test func escalatesToKillWhenTermIsIgnored() throws {
        let stubborn = "import signal, time\nsignal.signal(signal.SIGTERM, signal.SIG_IGN)\nprint('ready', flush=True)\ntime.sleep(120)"
        let helper = try Spawned(python, ["-c", stubborn])
        #expect(helper.firstLine() == "ready")
        let records = ProcessReader.snapshot()
        let root = try #require(records.first { $0.pid == helper.pid })
        let plan = StopPlanner.plan(roots: [root.identity], records: records, currentUID: getuid(), selfPID: getpid())

        let outcome = Stopper.execute(plan, grace: 0.5)
        #expect(outcome.killed == [helper.pid])
        #expect(outcome.succeeded)
    }

    @Test func catchesAChildRespawnedDuringTheStop() throws {
        // A supervisor that ignores SIGTERM and restarts its worker whenever it exits.
        let marker = String(Int.random(in: 100_000...999_999))
        let supervisor = """
        import signal, subprocess, sys, time
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        print('ready', flush=True)
        while True:
            child = subprocess.Popen(['/bin/sleep', '\(marker)'])
            child.wait()
            time.sleep(0.05)
        """
        let helper = try Spawned(python, ["-c", supervisor])
        #expect(helper.firstLine() == "ready")
        Thread.sleep(forTimeInterval: 0.3)
        let records = ProcessReader.snapshot()
        let root = try #require(records.first { $0.pid == helper.pid })
        let plan = StopPlanner.plan(roots: [root.identity], records: records, currentUID: getuid(), selfPID: getpid())
        #expect(plan.targets.count == 2)

        let outcome = Stopper.execute(plan, grace: 1)
        #expect(outcome.succeeded)
        Thread.sleep(forTimeInterval: 0.3)
        let leftovers = ProcessReader.snapshot().filter { $0.arguments.contains(marker) }
        #expect(leftovers.isEmpty, "respawned workers left running: \(leftovers.map(\.pid))")
    }

    @Test func neverSignalsARecycledPID() throws {
        let helper = try Spawned("/bin/sleep", ["30"])
        var record = try #require(ProcessReader.record(pid: helper.pid))
        record.startMicros -= 1_000_000        // pretend it is a different, older process with this PID
        let plan = StopPlan(targets: [record])
        let outcome = Stopper.execute(plan, grace: 0.2)
        #expect(outcome.vanished == [helper.pid])
        #expect(helper.process.isRunning)       // untouched
    }
}

@Suite(.serialized)
struct ClaudeSessionReaderTests {
    @Test func readsStatusAndTitleButNeverKeyFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("strays-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let sessions = root.appendingPathComponent("sessions")
        let project = root.appendingPathComponent("projects").appendingPathComponent("-Users-dev-code-acme")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)

        let pid = getpid()
        let me = try #require(ProcessReader.record(pid: pid))
        let startedMs = Int64(me.startDate.timeIntervalSince1970 * 1000) + 1000
        let status = #"{"pid":\#(pid),"sessionId":"abc-123","cwd":"/Users/dev/code/acme","name":"acme-1","status":"idle","updatedAt":1794252910869,"startedAt":\#(startedMs)}"#
        try Data(status.utf8).write(to: sessions.appendingPathComponent("\(pid).json"))
        // A .key file with the same PID prefix must be ignored (it is not JSON status).
        try Data("secret".utf8).write(to: sessions.appendingPathComponent("\(pid).deadbeef.key"))
        let filler = String(repeating: #"{"type":"assistant","message":"x"}"# + "\n", count: 20_000)   // > head + tail
        let transcript = #"{"type":"ai-title","aiTitle":"Early","sessionId":"abc-123"}"# + "\n" + filler
            + #"{"type":"ai-title","aiTitle":"Fix checkout bug","sessionId":"abc-123"}"# + "\n"
        try Data(transcript.utf8).write(to: project.appendingPathComponent("abc-123.jsonl"))

        let reader = ClaudeSessionReader(claudeDirectory: root)
        let found = reader.sessions(alive: [pid: me])
        let info = try #require(found[pid])
        #expect(info.name == "acme-1")
        #expect(info.status == .idle)
        #expect(info.title == "Fix checkout bug")
        #expect(found.count == 1)

        // A status file older than the process that now has this PID is ignored.
        let old = #"{"pid":\#(pid),"sessionId":"old","status":"idle","startedAt":1000}"#
        try Data(old.utf8).write(to: sessions.appendingPathComponent("\(pid).json"))
        #expect(reader.sessions(alive: [pid: me]).isEmpty)
    }
}

/// A fake Docker engine on a temporary unix socket.
final class FakeDocker {
    let path: String
    private let fd: Int32
    private let thread: Thread

    init(responses: [String: String]) throws {
        let socketPath = "/tmp/strays-docker-\(getpid())-\(Int.random(in: 0..<1_000_000)).sock"
        unlink(socketPath)
        let sock = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(socketPath.utf8)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, b) in bytes.enumerated() { raw[i] = b }
            raw[bytes.count] = 0
        }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(sock, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, listen(sock, 4) == 0 else { close(sock); throw DockerClient.DockerError.unreachable }
        path = socketPath
        fd = sock
        let listener = sock
        thread = Thread {
            while true {
                let client = accept(listener, nil, nil)
                if client < 0 { return }
                var buffer = [UInt8](repeating: 0, count: 4096)
                let got = recv(client, &buffer, buffer.count, 0)
                let request = got > 0 ? String(decoding: buffer[0..<got], as: UTF8.self) : ""
                let line = request.split(separator: "\r\n").first.map(String.init) ?? ""
                let reply = responses.first { line.hasPrefix($0.key) }?.value ?? "HTTP/1.0 404 Not Found\r\n\r\n"
                _ = reply.withCString { send(client, $0, strlen($0), 0) }
                close(client)
            }
        }
        thread.start()
    }

    deinit {
        close(fd)
        unlink(path)
    }
}

@Suite(.serialized)
struct DockerClientTests {
    @Test func listsAndStopsContainers() throws {
        let list = #"[{"Id":"abc123","Names":["/web"],"Image":"nginx","State":"running","Status":"Up 5 minutes","Created":1799992800,"Ports":[{"IP":"0.0.0.0","PrivatePort":80,"PublicPort":8080,"Type":"tcp"}],"Labels":{}}]"#
        let fake = try FakeDocker(responses: [
            "GET /containers/json": "HTTP/1.0 200 OK\r\nContent-Type: application/json\r\n\r\n" + list,
            "POST /containers/abc123/stop": "HTTP/1.0 204 No Content\r\n\r\n",
        ])
        let client = DockerClient(socketPath: fake.path)
        let containers = try client.containers()
        #expect(containers.map(\.name) == ["web"])
        #expect(containers.first?.publishedPorts == [8080])
        try client.stop(containerID: "abc123", graceSeconds: 1)
        #expect(throws: DockerClient.DockerError.badID) { try client.stop(containerID: "../x") }
    }

    @Test func missingEngineIsUnreachable() {
        let client = DockerClient(socketPath: "/tmp/strays-no-such-socket.sock")
        #expect(throws: DockerClient.DockerError.unreachable) { try client.containers() }
    }

    @Test func discoveryOnlyAcceptsSockets() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("strays-home-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".docker/run"), withIntermediateDirectories: true)
        try Data().write(to: home.appendingPathComponent(".docker/run/docker.sock"))   // a plain file, not a socket
        let found = DockerClient.discover(home: home.path, environment: [:])
        #expect(found?.socketPath != home.path + "/.docker/run/docker.sock")
    }
}

struct LaunchdTests {
    @Test func parsesLaunchctlList() {
        let text = "PID\tStatus\tLabel\n-\t0\tcom.apple.idle\n700\t0\thomebrew.mxcl.postgresql@16\n1380\t0\tapplication.com.github.1\n"
        #expect(LaunchctlList.parse(text) == [700: "homebrew.mxcl.postgresql@16", 1380: "application.com.github.1"])
    }

    @Test func readsRealLaunchdLabels() {
        // Every logged-in user has some running launchd jobs.
        #expect(LaunchdReader.labels().isEmpty == false)
    }
}

struct UntrustedFilesTests {
    @Test func aFIFOInTheSessionsFolderIsSkippedNotRead() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("strays-fifo-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let sessions = root.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let pid = getpid()
        #expect(mkfifo(sessions.appendingPathComponent("\(pid).json").path, 0o600) == 0)
        let me = try #require(ProcessReader.record(pid: pid))
        let started = Date()
        #expect(ClaudeSessionReader(claudeDirectory: root).sessions(alive: [pid: me]).isEmpty)
        #expect(Date().timeIntervalSince(started) < 2)   // returned instead of blocking on the pipe
    }
}
