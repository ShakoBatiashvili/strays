import Darwin
import Foundation
import StraysCore

/// What answers on a local port.
public enum PortProtocol: String, Codable, Sendable {
    case http, https, other
}

/// Asks a port on this Mac (loopback only) whether it speaks HTTP, so "Open in browser" is
/// only offered where it works. Sends one `HEAD /` request and reads a few bytes.
public enum PortProbe {
    public static func probe(port: UInt16, ipv6: Bool = false, timeout: TimeInterval = 0.4) -> PortProtocol {
        let fd = socket(ipv6 ? AF_INET6 : AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return .other }
        defer { close(fd) }
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        setTimeouts(fd, timeout)

        let connected: Bool
        if ipv6 {
            var addr = sockaddr_in6()
            addr.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            addr.sin6_family = sa_family_t(AF_INET6)
            addr.sin6_port = port.bigEndian
            addr.sin6_addr = in6addr_loopback
            connected = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) == 0 }
            }
        } else {
            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = port.bigEndian
            addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
            connected = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 }
            }
        }
        guard connected else { return .other }

        let request = "HEAD / HTTP/1.0\r\nHost: localhost:\(port)\r\nUser-Agent: Strays\r\n\r\n"
        let sent = request.withCString { send(fd, $0, strlen($0), 0) }
        guard sent > 0 else { return .other }

        var buffer = [UInt8](repeating: 0, count: 8)
        let got = recv(fd, &buffer, buffer.count, 0)
        guard got > 0 else { return .other }
        if got >= 5, String(decoding: buffer[0..<5], as: UTF8.self) == "HTTP/" { return .http }
        // A TLS server answers a plain-text request with a TLS alert record (0x15 0x03 ...).
        if got >= 2, buffer[0] == 0x15, buffer[1] == 0x03 { return .https }
        return .other
    }

    static func setTimeouts(_ fd: Int32, _ seconds: TimeInterval) {
        var tv = timeval(tv_sec: Int(seconds), tv_usec: Int32((seconds - floor(seconds)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }
}

/// Talks to a local Docker engine over its unix socket. Never over TCP.
public struct DockerClient: Sendable {
    public let socketPath: String

    public init(socketPath: String) {
        self.socketPath = socketPath
    }

    /// The first engine socket that exists: Docker Desktop, OrbStack, Colima, or the classic path.
    public static func discover(home: String = FileManager.default.homeDirectoryForCurrentUser.path,
                                environment: [String: String] = ProcessInfo.processInfo.environment) -> DockerClient? {
        var candidates: [String] = []
        if let host = environment["DOCKER_HOST"], host.hasPrefix("unix://") { candidates.append(String(host.dropFirst(7))) }
        candidates += [
            home + "/.docker/run/docker.sock",
            home + "/.orbstack/run/docker.sock",
            home + "/.colima/default/docker.sock",
            "/var/run/docker.sock",
        ]
        for path in candidates {
            var info = stat()
            if stat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFSOCK { return DockerClient(socketPath: path) }
        }
        return nil
    }

    public func containers() throws -> [DockerContainer] {
        let response = try request(method: "GET", path: "/containers/json")
        guard response.status == 200 else { throw DockerError.status(response.status) }
        return try DockerAPI.parseContainers(response.body)
    }

    public func stop(containerID: String, graceSeconds: Int = 5) throws {
        guard DockerAPI.isValidContainerID(containerID) else { throw DockerError.badID }
        let response = try request(method: "POST", path: "/containers/\(containerID)/stop?t=\(max(0, graceSeconds))",
                                   timeout: TimeInterval(graceSeconds) + 10)
        // 204: stopped. 304: already stopped.
        guard response.status == 204 || response.status == 304 else { throw DockerError.status(response.status) }
    }

    public enum DockerError: Error, Equatable {
        case unreachable, badID, badResponse, status(Int)
    }

    func request(method: String, path: String, timeout: TimeInterval = 2) throws -> DockerAPI.Response {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw DockerError.unreachable }
        defer { close(fd) }
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        PortProbe.setTimeouts(fd, timeout)

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { throw DockerError.unreachable }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, byte) in pathBytes.enumerated() { raw[i] = byte }
            raw[pathBytes.count] = 0
        }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0 }
        }
        guard connected else { throw DockerError.unreachable }

        let text = "\(method) \(path) HTTP/1.0\r\nHost: docker\r\nContent-Length: 0\r\n\r\n"
        let sent = text.withCString { send(fd, $0, strlen($0), 0) }
        guard sent == text.utf8.count else { throw DockerError.unreachable }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while data.count < 8 * 1024 * 1024 {
            let got = recv(fd, &buffer, buffer.count, 0)
            if got <= 0 { break }
            data.append(contentsOf: buffer[0..<got])
        }
        guard let response = DockerAPI.parseResponse(data) else { throw DockerError.badResponse }
        return response
    }
}
