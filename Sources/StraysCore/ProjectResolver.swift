import Foundation

public struct ProjectRef: Hashable, Codable, Sendable {
    /// What the UI shows: "acme", or "mono › web" for a package inside a monorepo.
    public var name: String
    /// Folder to open in an editor: the git root when there is one.
    public var path: String

    public init(name: String, path: String) {
        self.name = name
        self.path = path
    }
}

/// Names the project a process works in from its current directory.
public enum ProjectResolver {
    static let manifests = [
        "package.json", "pyproject.toml", "Cargo.toml", "go.mod", "Gemfile", "pom.xml", "build.gradle",
        "build.gradle.kts", "deno.json", "composer.json", "mix.exs", "Package.swift", "requirements.txt",
    ]

    /// - Parameters:
    ///   - exists: file-existence check, injected so this stays pure and testable.
    public static func resolve(cwd: String?, home: String, exists: (String) -> Bool) -> ProjectRef? {
        guard var dir = cwd.map(normalize), dir != "/", dir != normalize(home) else { return nil }
        let homeDir = normalize(home)
        let start = dir

        var nearestManifest: String?
        var gitRoot: String?
        while true {
            if nearestManifest == nil, manifests.contains(where: { exists(dir + "/" + $0) }) {
                nearestManifest = dir
            }
            if exists(dir + "/.git") {
                gitRoot = dir
                break
            }
            let parent = (dir as NSString).deletingLastPathComponent
            if parent == dir || parent == "/" || parent == homeDir || dir == homeDir { break }
            dir = parent
        }

        if let gitRoot {
            let rootName = lastComponent(gitRoot)
            if let nearestManifest, nearestManifest != gitRoot {
                return ProjectRef(name: "\(rootName) › \(lastComponent(nearestManifest))", path: gitRoot)
            }
            return ProjectRef(name: rootName, path: gitRoot)
        }
        if let nearestManifest { return ProjectRef(name: lastComponent(nearestManifest), path: nearestManifest) }
        return ProjectRef(name: lastComponent(start), path: start)
    }

    private static func normalize(_ path: String) -> String {
        var p = path
        while p.count > 1, p.hasSuffix("/") { p.removeLast() }
        return p
    }

    private static func lastComponent(_ path: String) -> String {
        (path as NSString).lastPathComponent
    }
}
