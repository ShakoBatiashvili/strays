import Darwin
import Foundation
import StraysCore

/// launchd job labels by PID, from `/bin/launchctl list` (your user's jobs; no privileges).
/// This is the only subprocess Strays starts, with a fixed path and fixed arguments.
public enum LaunchdReader {
    public static func labels() -> [Int32: String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["list"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return [:] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return LaunchctlList.parse(String(decoding: data, as: UTF8.self))
    }
}

/// Reads Claude Code's session status files and transcript titles (read-only).
/// Only `<pid>.json` status files are opened; the `.key` files next to them hold tokens and are never read.
public final class ClaudeSessionReader: @unchecked Sendable {
    private let claudeDirectory: URL
    private var titleCache: [String: (size: UInt64, modified: Date, readAt: Date, title: String?)] = [:]
    /// A busy session's transcript changes constantly; its title is re-read at most this often.
    static let titleRefresh: TimeInterval = 60
    private let lock = NSLock()
    static let headBytes = 256 * 1024
    static let tailBytes = 512 * 1024

    public init(claudeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")) {
        self.claudeDirectory = claudeDirectory
    }

    /// Sessions keyed by PID, for PIDs in `alive` whose process started no later than the session.
    public func sessions(alive: [Int32: ProcRecord]) -> [Int32: AgentSessionInfo] {
        let folder = claudeDirectory.appendingPathComponent("sessions")
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return [:] }
        var out: [Int32: AgentSessionInfo] = [:]
        for name in names {
            guard name.hasSuffix(".json"), let pid = Int32(name.dropLast(5)), let record = alive[pid] else { continue }
            guard let data = readLimited(folder.appendingPathComponent(name), max: 64 * 1024),
                  var info = ClaudeSessions.parseStatus(data), info.pid == pid else { continue }
            // A leftover file for a PID that now belongs to another process is ignored.
            if let started = startedAt(data), started.addingTimeInterval(5) < record.startDate { continue }
            info.title = title(sessionID: info.sessionID, cwd: info.cwd)
            out[pid] = info
        }
        return out
    }

    private func startedAt(_ data: Data) -> Date? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ms = object["startedAt"] as? NSNumber else { return nil }
        return Date(timeIntervalSince1970: ms.doubleValue / 1000)
    }

    func title(sessionID: String, cwd: String?) -> String? {
        guard sessionID.allSatisfy({ $0.isHexDigit || $0 == "-" }), !sessionID.isEmpty else { return nil }
        guard let url = transcriptURL(sessionID: sessionID, cwd: cwd),
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attributes[.size] as? NSNumber)?.uint64Value,
              let modified = attributes[.modificationDate] as? Date
        else { return nil }

        lock.lock()
        if let cached = titleCache[url.path],
           (cached.size == size && cached.modified == modified) || Date().timeIntervalSince(cached.readAt) < Self.titleRefresh {
            lock.unlock()
            return cached.title
        }
        lock.unlock()

        let title = readTitle(url, size: size)
        lock.lock()
        titleCache[url.path] = (size, modified, Date(), title)
        lock.unlock()
        return title
    }

    private func transcriptURL(sessionID: String, cwd: String?) -> URL? {
        let projects = claudeDirectory.appendingPathComponent("projects")
        let file = sessionID + ".jsonl"
        if let cwd {
            let direct = projects.appendingPathComponent(ClaudeSessions.projectFolderName(for: cwd)).appendingPathComponent(file)
            if FileManager.default.fileExists(atPath: direct.path) { return direct }
        }
        guard let folders = try? FileManager.default.contentsOfDirectory(atPath: projects.path) else { return nil }
        for folder in folders {
            let candidate = projects.appendingPathComponent(folder).appendingPathComponent(file)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    /// Reads only the head and tail of the transcript: titles repeat through the file.
    private func readTitle(_ url: URL, size: UInt64) -> String? {
        guard Self.isRegularFile(url), let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: Self.headBytes)) ?? Data()
        var tail = Data()
        if size > UInt64(Self.headBytes) {
            let offset = size > UInt64(Self.tailBytes) ? size - UInt64(Self.tailBytes) : 0
            try? handle.seek(toOffset: max(offset, UInt64(Self.headBytes)))
            tail = (try? handle.readToEnd()) ?? Data()
        }
        let text = String(decoding: head, as: UTF8.self) + "\n" + String(decoding: tail, as: UTF8.self)
        return ClaudeSessions.title(in: text)
    }

    /// Only plain files are opened: a FIFO or device planted in ~/.claude would block a read forever.
    static func isRegularFile(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFREG
    }

    private func readLimited(_ url: URL, max: Int) -> Data? {
        guard Self.isRegularFile(url), let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        return try? handle.read(upToCount: max)
    }
}

/// Reads one complete picture of the machine.
public enum WorldReader {
    public static func read(claude: ClaudeSessionReader, launchdLabels: [Int32: String]) -> World {
        let uid = getuid()
        let records = ProcessReader.snapshot(detailFor: uid)
        var byPID: [Int32: ProcRecord] = [:]
        for r in records where r.uid == uid && Recognizer.runtime(of: r) == .claude { byPID[r.pid] = r }
        return World(
            records: records, currentUID: uid, selfPID: getpid(),
            home: FileManager.default.homeDirectoryForCurrentUser.path,
            launchdLabels: launchdLabels,
            agentSessions: claude.sessions(alive: byPID)
        )
    }
}

/// Project lookups, cached by folder (folders rarely change identity while a process runs).
public final class ProjectCache: @unchecked Sendable {
    private var cache: [String: ProjectRef?] = [:]
    private let lock = NSLock()
    private let home = FileManager.default.homeDirectoryForCurrentUser.path

    public init() {}

    public func resolve(_ cwd: String?) -> ProjectRef? {
        guard let cwd else { return nil }
        lock.lock(); defer { lock.unlock() }
        if let hit = cache[cwd] { return hit }
        let ref = ProjectResolver.resolve(cwd: cwd, home: home, exists: { FileManager.default.fileExists(atPath: $0) })
        cache[cwd] = ref
        return ref
    }
}
