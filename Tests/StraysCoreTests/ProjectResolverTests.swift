import Testing
@testable import StraysCore

struct ProjectResolverTests {
    private func resolver(_ existing: Set<String>) -> (String?) -> ProjectRef? {
        { cwd in ProjectResolver.resolve(cwd: cwd, home: "/Users/dev", exists: { existing.contains($0) }) }
    }

    @Test func gitRootNamesTheProject() {
        let resolve = resolver(["/Users/dev/code/acme/.git"])
        #expect(resolve("/Users/dev/code/acme") == ProjectRef(name: "acme", path: "/Users/dev/code/acme"))
        #expect(resolve("/Users/dev/code/acme/src/server") == ProjectRef(name: "acme", path: "/Users/dev/code/acme"))
    }

    @Test func monorepoPackageIsShownInsideTheRepo() {
        let resolve = resolver(["/Users/dev/code/mono/.git", "/Users/dev/code/mono/apps/web/package.json", "/Users/dev/code/mono/package.json"])
        #expect(resolve("/Users/dev/code/mono/apps/web") == ProjectRef(name: "mono › web", path: "/Users/dev/code/mono"))
        #expect(resolve("/Users/dev/code/mono") == ProjectRef(name: "mono", path: "/Users/dev/code/mono"))
    }

    @Test func manifestWithoutGit() {
        let resolve = resolver(["/Users/dev/play/api/pyproject.toml"])
        #expect(resolve("/Users/dev/play/api/app") == ProjectRef(name: "api", path: "/Users/dev/play/api"))
    }

    @Test func plainFolderFallsBackToItsName() {
        let resolve = resolver([])
        #expect(resolve("/Users/dev/scripts") == ProjectRef(name: "scripts", path: "/Users/dev/scripts"))
    }

    @Test func homeRootAndUnknownHaveNoProject() {
        let resolve = resolver(["/Users/dev/.git"])
        #expect(resolve("/Users/dev") == nil)
        #expect(resolve("/") == nil)
        #expect(resolve(nil) == nil)
        #expect(resolve("/private/var/folders/xy") == ProjectRef(name: "xy", path: "/private/var/folders/xy"))
    }

    @Test func doesNotClimbAboveHome() {
        // A stray .git in the home folder must not swallow every project.
        let resolve = resolver(["/Users/dev/.git"])
        #expect(resolve("/Users/dev/code/acme") == ProjectRef(name: "acme", path: "/Users/dev/code/acme"))
    }
}
