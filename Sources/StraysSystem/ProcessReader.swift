import Darwin
import Foundation
import StraysCore

/// Read-only process inspection through libproc and sysctl (public APIs, no privileges).
/// Full detail (arguments, folder, sockets) is only readable for your own processes;
/// for everyone else's, Strays sees just enough to draw the process tree.
public enum ProcessReader {
    private static let pathBufferSize = 4 * Int(MAXPATHLEN)   // PROC_PIDPATHINFO_MAXSIZE

    /// Mach time units -> seconds (task CPU times are reported in mach ticks on Apple silicon).
    private static let ticksToSeconds: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom) / 1_000_000_000
    }()

    public static func allPIDs() -> [pid_t] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let got = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.stride))
        guard got > 0 else { return [] }
        return pids.prefix(Int(got)).filter { $0 > 0 }
    }

    /// Every process, with full detail for those owned by `detailFor` (your user).
    public static func snapshot(detailFor uid: uid_t = getuid()) -> [ProcRecord] {
        allPIDs().compactMap { record(pid: $0, detailed: { $0 == uid }) }
    }

    public static func record(pid: pid_t, detailed: (uid_t) -> Bool = { $0 == getuid() }) -> ProcRecord? {
        var bsd = proc_bsdinfo()
        let bsdSize = Int32(MemoryLayout<proc_bsdinfo>.size)
        let hasBSD = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, bsdSize) == bsdSize

        let ppid: Int32, uid: UInt32, startMicros: Int64, tdev: UInt32
        var name: String
        if hasBSD {
            ppid = Int32(bsd.pbi_ppid)
            uid = bsd.pbi_uid
            startMicros = Int64(bsd.pbi_start_tvsec) * 1_000_000 + Int64(bsd.pbi_start_tvusec)
            tdev = bsd.e_tdev
            name = withUnsafeBytes(of: bsd.pbi_name) { cString($0) }
            if name.isEmpty { name = withUnsafeBytes(of: bsd.pbi_comm) { cString($0) } }
        } else {
            var short = proc_bsdshortinfo()
            let shortSize = Int32(MemoryLayout<proc_bsdshortinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &short, shortSize) == shortSize else { return nil }
            ppid = Int32(short.pbsi_ppid)
            uid = short.pbsi_uid
            startMicros = 0
            tdev = UInt32.max
            name = withUnsafeBytes(of: short.pbsi_comm) { cString($0) }
        }

        var record = ProcRecord(pid: pid, ppid: ppid, uid: uid, name: name, path: executablePath(pid: pid),
                                startMicros: startMicros)
        guard detailed(uid) else { return record }

        record.arguments = arguments(pid: pid)
        record.cwd = currentDirectory(pid: pid)
        record.tty = ttyName(tdev)
        var task = proc_taskinfo()
        let taskSize = Int32(MemoryLayout<proc_taskinfo>.size)
        if proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &task, taskSize) == taskSize {
            record.cpuSeconds = Double(task.pti_total_user + task.pti_total_system) * ticksToSeconds
            record.residentBytes = task.pti_resident_size
        }
        record.listening = listeningSockets(pid: pid)
        return record
    }

    /// Live identity check: is this PID still the same process (same start time)?
    public static func identity(of pid: pid_t) -> (identity: ProcIdentity, uid: UInt32)? {
        var bsd = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, size) == size else { return nil }
        // A zombie keeps its PID until reaped but is already gone for our purposes.
        if bsd.pbi_status == UInt32(SZOMB) { return nil }
        let start = Int64(bsd.pbi_start_tvsec) * 1_000_000 + Int64(bsd.pbi_start_tvusec)
        return (ProcIdentity(pid: pid, startMicros: start), bsd.pbi_uid)
    }

    public static func executablePath(pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: pathBufferSize)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        return length > 0 ? String(cString: buffer) : nil
    }

    /// argv through the public KERN_PROCARGS2 sysctl (readable for your own processes).
    public static func arguments(pid: pid_t) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [] }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [] }

        // Layout: int argc, exec path (NUL-terminated), NUL padding, argv[0], argv[1], ..., envp...
        let argc = buffer.withUnsafeBytes { $0.load(as: Int32.self) }
        var i = MemoryLayout<Int32>.size
        while i < size, buffer[i] != 0 { i += 1 }   // exec path
        while i < size, buffer[i] == 0 { i += 1 }   // padding
        var args: [String] = []
        while args.count < Int(argc), i < size {
            let start = i
            while i < size, buffer[i] != 0 { i += 1 }
            args.append(String(decoding: buffer[start..<i], as: UTF8.self))
            i += 1
        }
        // A rewritten title (node's process.title) leaves trailing empty arguments behind.
        while let last = args.last, last.isEmpty { args.removeLast() }
        return args
    }

    public static func currentDirectory(pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: info.pvi_cdir.vip_path) { cString($0) }
        return path.isEmpty ? nil : path
    }

    /// devname() scans /dev on every call, so names are cached by device number (they never change).
    private static var ttyCache: [UInt32: String] = [:]
    private static let ttyLock = NSLock()

    private static func ttyName(_ dev: UInt32) -> String? {
        guard dev != UInt32.max, dev != 0 else { return nil }
        ttyLock.lock()
        if let cached = ttyCache[dev] { ttyLock.unlock(); return cached.isEmpty ? nil : cached }
        ttyLock.unlock()
        var name = ""
        if let raw = devname(dev_t(bitPattern: dev), S_IFCHR) {
            let s = String(cString: raw)
            if s != "??" { name = s }
        }
        ttyLock.lock()
        ttyCache[dev] = name
        ttyLock.unlock()
        return name.isEmpty ? nil : name
    }

    /// TCP sockets in LISTEN state, read from the process's own file table.
    public static func listeningSockets(pid: pid_t) -> [ListeningSocket] {
        let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bytes > 0 else { return [] }
        let stride = MemoryLayout<proc_fdinfo>.stride
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bytes) / stride + 16)
        let got = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, Int32(fds.count * stride))
        guard got > 0 else { return [] }

        var out: [ListeningSocket] = []
        for fd in fds.prefix(Int(got) / stride) where fd.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var info = socket_fdinfo()
            let size = Int32(MemoryLayout<socket_fdinfo>.size)
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &info, size) == size else { continue }
            let psi = info.psi
            guard psi.soi_kind == Int32(SOCKINFO_TCP) else { continue }
            let tcp = psi.soi_proto.pri_tcp
            guard tcp.tcpsi_state == Int32(TSI_S_LISTEN) else { continue }
            let ini = tcp.tcpsi_ini
            let port = UInt16(bigEndian: UInt16(truncatingIfNeeded: ini.insi_lport))
            guard port > 0 else { continue }

            if psi.soi_family == AF_INET6 {
                var addr = ini.insi_laddr.ina_6
                let text = addressString(family: AF_INET6, &addr)
                out.append(ListeningSocket(port: port, address: text == "::" ? "::" : text, family: .ipv6))
            } else {
                var addr = ini.insi_laddr.ina_46.i46a_addr4
                let text = addressString(family: AF_INET, &addr)
                out.append(ListeningSocket(port: port, address: text == "0.0.0.0" ? "*" : text, family: .ipv4))
            }
        }
        return out
    }

    private static func addressString<T>(family: Int32, _ addr: inout T) -> String {
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        guard inet_ntop(family, &addr, &buffer, socklen_t(buffer.count)) != nil else { return "?" }
        return String(cString: buffer)
    }

    private static func cString(_ raw: UnsafeRawBufferPointer) -> String {
        let bytes = raw.prefix { $0 != 0 }
        return String(decoding: bytes, as: UTF8.self)
    }
}
