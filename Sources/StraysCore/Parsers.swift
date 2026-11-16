import Foundation

/// Reads what Claude Code publishes about its own sessions. Pure parsing; file access lives in StraysSystem.
public enum ClaudeSessions {
    /// `~/.claude/sessions/<pid>.json`.
    public static func parseStatus(_ data: Data) -> AgentSessionInfo? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pid = (object["pid"] as? NSNumber)?.int32Value,
              let sessionID = object["sessionId"] as? String
        else { return nil }
        let status = AgentSessionInfo.Status(rawValue: (object["status"] as? String) ?? "") ?? .unknown
        let updated = (object["updatedAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
        return AgentSessionInfo(pid: pid, sessionID: sessionID, cwd: object["cwd"] as? String,
                                name: object["name"] as? String, status: status, updatedAt: updated)
    }

    /// The conversation's title from transcript text (usually the file's head and tail).
    /// A title the user set with /rename wins over Claude's AI title; the latest of each wins.
    public static func title(in text: String) -> String? {
        var custom: String?
        var ai: String?
        var summary: String?
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            // Cheap check first: transcripts are large and almost every line is something else.
            guard line.contains("-title\"") || line.contains("\"summary\"") else { continue }
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let type = object["type"] as? String else { continue }
            switch type {
            case "custom-title": custom = (object["customTitle"] as? String).flatMap(nonEmpty) ?? custom
            case "ai-title": ai = (object["aiTitle"] as? String).flatMap(nonEmpty) ?? ai
            case "summary": summary = (object["summary"] as? String).flatMap(nonEmpty) ?? summary
            default: break
            }
        }
        return custom ?? ai ?? summary
    }

    /// Claude stores transcripts under ~/.claude/projects/<cwd with every non-alphanumeric as "-">.
    public static func projectFolderName(for cwd: String) -> String {
        String(cwd.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
    }

    private static func nonEmpty(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}

public struct DockerContainer: Hashable, Codable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var image: String
    public var state: String
    public var status: String
    public var created: Date
    public var publishedPorts: [UInt16]
    public var project: String?
    public var service: String?

    public init(id: String, name: String, image: String, state: String, status: String, created: Date,
                publishedPorts: [UInt16], project: String? = nil, service: String? = nil) {
        self.id = id
        self.name = name
        self.image = image
        self.state = state
        self.status = status
        self.created = created
        self.publishedPorts = publishedPorts
        self.project = project
        self.service = service
    }

    public var title: String {
        if let project, let service { return "\(project) › \(service)" }
        return name
    }

    public var shortID: String { String(id.prefix(12)) }
}

/// The few bits of the Docker Engine API Strays uses, over the local unix socket only.
public enum DockerAPI {
    public struct Response: Equatable {
        public var status: Int
        public var body: Data
    }

    public enum ParseError: Error { case notAList }

    public static func parseContainers(_ data: Data) throws -> [DockerContainer] {
        guard let list = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw ParseError.notAList }
        return list.compactMap { item in
            guard let id = item["Id"] as? String else { return nil }
            let names = (item["Names"] as? [String]) ?? []
            let name = names.first.map { $0.hasPrefix("/") ? String($0.dropFirst()) : $0 } ?? String(id.prefix(12))
            let labels = (item["Labels"] as? [String: String]) ?? [:]
            var ports: [UInt16] = []
            for port in (item["Ports"] as? [[String: Any]]) ?? [] {
                if let published = (port["PublicPort"] as? NSNumber)?.uint16Value, !ports.contains(published) {
                    ports.append(published)
                }
            }
            return DockerContainer(
                id: id, name: name, image: (item["Image"] as? String) ?? "?",
                state: (item["State"] as? String) ?? "?", status: (item["Status"] as? String) ?? "",
                created: Date(timeIntervalSince1970: (item["Created"] as? NSNumber)?.doubleValue ?? 0),
                publishedPorts: ports.sorted(),
                project: labels["com.docker.compose.project"], service: labels["com.docker.compose.service"]
            )
        }
    }

    /// Container ids go into a request path: only hex is accepted.
    public static func isValidContainerID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 64 && id.allSatisfy(\.isHexDigit)
    }

    /// Minimal HTTP/1.0 response parsing (the daemon closes the connection after replying).
    public static func parseResponse(_ data: Data) -> Response? {
        let separator = Data("\r\n\r\n".utf8)
        guard let headerEnd = data.range(of: separator) else { return nil }
        let head = String(decoding: data[..<headerEnd.lowerBound], as: UTF8.self)
        let statusLine = head.split(separator: "\r\n").first ?? ""
        let parts = statusLine.split(separator: " ")
        guard parts.count >= 2, parts[0].hasPrefix("HTTP/"), let status = Int(parts[1]) else { return nil }
        return Response(status: status, body: Data(data[headerEnd.upperBound...]))
    }
}
