import Foundation
import Testing
@testable import StraysCore

struct ClaudeSessionParserTests {
    @Test func parsesStatusFile() throws {
        let json = """
        {"pid":4242,"sessionId":"33f98a2a-0000","cwd":"/Users/dev/code/acme","startedAt":1794232473411,
         "version":"2.1.319","kind":"interactive","entrypoint":"cli","name":"acme-2b","nameSource":"derived",
         "status":"idle","updatedAt":1794252910869,"statusUpdatedAt":1794252910869}
        """
        let info = try #require(ClaudeSessions.parseStatus(Data(json.utf8)))
        #expect(info.pid == 4242)
        #expect(info.sessionID == "33f98a2a-0000")
        #expect(info.cwd == "/Users/dev/code/acme")
        #expect(info.name == "acme-2b")
        #expect(info.status == .idle)
        #expect(info.updatedAt == Date(timeIntervalSince1970: 1_794_252_910.869))
    }

    @Test func unknownStatusAndMissingFields() throws {
        let info = try #require(ClaudeSessions.parseStatus(Data(#"{"pid":7,"sessionId":"x","status":"waiting"}"#.utf8)))
        #expect(info.status == .unknown)
        #expect(info.updatedAt == nil)
        #expect(ClaudeSessions.parseStatus(Data("not json".utf8)) == nil)
        #expect(ClaudeSessions.parseStatus(Data(#"{"sessionId":"x"}"#.utf8)) == nil)
    }

    @Test func busyStatus() throws {
        let info = try #require(ClaudeSessions.parseStatus(Data(#"{"pid":7,"sessionId":"x","status":"busy"}"#.utf8)))
        #expect(info.status == .busy)
    }

    @Test func titlePrefersTheUsersRenameThenTheLatestAITitle() {
        let lines = [
            #"{"type":"user","message":{"content":"hi"}}"#,
            #"{"type":"ai-title","aiTitle":"Old title","sessionId":"s"}"#,
            #"{"type":"assistant","message":{"content":"…"}}"#,
            #"{"type":"ai-title","aiTitle":"Fix checkout bug","sessionId":"s"}"#,
            "{broken json",
        ]
        #expect(ClaudeSessions.title(in: lines.joined(separator: "\n")) == "Fix checkout bug")
        let renamed = lines + [#"{"type":"custom-title","customTitle":"Checkout v2","sessionId":"s"}"#]
        #expect(ClaudeSessions.title(in: renamed.joined(separator: "\n")) == "Checkout v2")
        #expect(ClaudeSessions.title(in: #"{"type":"summary","summary":"Old style summary"}"#) == "Old style summary")
        #expect(ClaudeSessions.title(in: #"{"type":"user"}"#) == nil)
    }

    @Test func titleIgnoresAPartialFirstLine() {
        // Reading the tail of a file usually starts mid-line.
        let chunk = #"le":"cut off"}"# + "\n" + #"{"type":"ai-title","aiTitle":"Whole","sessionId":"s"}"#
        #expect(ClaudeSessions.title(in: chunk) == "Whole")
    }

    @Test func projectFolderEncoding() {
        #expect(ClaudeSessions.projectFolderName(for: "/Users/dev/code/acme") == "-Users-dev-code-acme")
        #expect(ClaudeSessions.projectFolderName(for: "/Users/dev/my.app/x_y") == "-Users-dev-my-app-x-y")
    }
}

struct DockerParserTests {
    let json = """
    [{"Id":"8dfafdbc3a40","Names":["/acme-db-1"],"Image":"postgres:16","State":"running","Status":"Up 2 hours",
      "Created":1799992800,
      "Ports":[{"IP":"0.0.0.0","PrivatePort":5432,"PublicPort":5433,"Type":"tcp"},
               {"IP":"::","PrivatePort":5432,"PublicPort":5433,"Type":"tcp"},
               {"PrivatePort":9000,"Type":"tcp"}],
      "Labels":{"com.docker.compose.project":"acme","com.docker.compose.service":"db"}},
     {"Id":"1234567890abcdef","Names":["/redis"],"Image":"redis:7","State":"running","Status":"Up 3 days",
      "Created":1799700000,"Ports":[{"IP":"127.0.0.1","PrivatePort":6379,"PublicPort":6379,"Type":"tcp"}],"Labels":{}}]
    """

    @Test func parsesContainers() throws {
        let containers = try DockerAPI.parseContainers(Data(json.utf8))
        #expect(containers.count == 2)
        let db = containers[0]
        #expect(db.id == "8dfafdbc3a40")
        #expect(db.name == "acme-db-1")
        #expect(db.image == "postgres:16")
        #expect(db.project == "acme")
        #expect(db.service == "db")
        #expect(db.status == "Up 2 hours")
        #expect(db.publishedPorts == [5433])                   // de-duplicated, unpublished ports left out
        #expect(db.created == Date(timeIntervalSince1970: 1_799_992_800))
        #expect(containers[1].project == nil)
        #expect(containers[1].title == "redis")
        #expect(db.title == "acme › db")
    }

    @Test func rejectsGarbage() {
        #expect(throws: (any Error).self) { try DockerAPI.parseContainers(Data("{}".utf8)) }
    }

    @Test func containerIDsAreValidated() {
        #expect(DockerAPI.isValidContainerID("8dfafdbc3a40"))
        #expect(!DockerAPI.isValidContainerID("../../etc"))
        #expect(!DockerAPI.isValidContainerID(""))
    }

    @Test func httpResponseParsing() throws {
        let raw = "HTTP/1.0 200 OK\r\nContent-Type: application/json\r\n\r\n[]"
        let response = try #require(DockerAPI.parseResponse(Data(raw.utf8)))
        #expect(response.status == 200)
        #expect(String(decoding: response.body, as: UTF8.self) == "[]")
        let chunked = "HTTP/1.1 204 No Content\r\n\r\n"
        #expect(DockerAPI.parseResponse(Data(chunked.utf8))?.status == 204)
        #expect(DockerAPI.parseResponse(Data("garbage".utf8)) == nil)
    }
}
