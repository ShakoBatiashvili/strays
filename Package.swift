// swift-tools-version: 5.9
import PackageDescription

// `#file` expands to "Module/File.swift" instead of an absolute path, so built binaries never
// embed the build machine's directory layout (or its username) in assertion messages.
let shortPaths: [SwiftSetting] = [.enableUpcomingFeature("ConciseMagicFile")]

let package = Package(
    name: "Strays",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "strays", targets: ["strays"]),
        .executable(name: "StraysApp", targets: ["StraysApp"]),
    ],
    targets: [
        // Pure logic: no libproc, no AppKit, no I/O. Everything here is unit-tested.
        .target(name: "StraysCore", path: "Sources/StraysCore", swiftSettings: shortPaths),
        // Thin adapters over macOS APIs (libproc, signals, local sockets). No internet access.
        .target(name: "StraysSystem", dependencies: ["StraysCore"], path: "Sources/StraysSystem", swiftSettings: shortPaths),
        // The command-line tool: a thin wrapper over the two libraries above.
        .executableTarget(name: "strays", dependencies: ["StraysCore", "StraysSystem"], path: "Sources/strays", swiftSettings: shortPaths),
        // The menu-bar app (AppKit status item + SwiftUI). Wrapped into Strays.app by scripts/build-app.sh.
        .executableTarget(name: "StraysApp", dependencies: ["StraysCore", "StraysSystem"], path: "Sources/StraysApp", swiftSettings: shortPaths),
        .testTarget(name: "StraysCoreTests", dependencies: ["StraysCore"], path: "Tests/StraysCoreTests"),
        .testTarget(name: "StraysSystemTests", dependencies: ["StraysSystem", "StraysCore"], path: "Tests/StraysSystemTests"),
    ]
)
