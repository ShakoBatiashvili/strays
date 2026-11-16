import AppKit
import SwiftUI
import StraysCore

/// Renders the panel to PNGs from canned, made-up data, so the UI can be reviewed without a
/// live Mac state (and without a person clicking the menu bar).
@MainActor
enum Snapshot {
    static func run(outputDirectory: String) {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.activate(ignoringOtherApps: true)

        let directory = URL(fileURLWithPath: outputDirectory, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let jobs: [(String, (AppModel) -> Void, NSAppearance.Name)] = [
            ("list-light", { _ in }, .aqua),
            ("list-dark", { _ in }, .darkAqua),
            ("expanded-light", { m in m.expanded = [m.strays.first { $0.kind == .agent }!.id] }, .aqua),
            ("bulk-dark", { m in m.confirmBulk("\(m.stale.count) stale", m.stale) }, .darkAqua),
            ("filter-port-free-light", { m in m.filter = ":3999" }, .aqua),
            ("filter-port-dark", { m in m.filter = ":5317" }, .darkAqua),
            ("empty-light", { m in m.strays = []; m.containers = [] }, .aqua),
            ("settings-light", { m in m.page = .settings }, .aqua),
            ("settings-dark", { m in m.page = .settings }, .darkAqua),
            // Last: everything, including what scrolls below the fold.
            ("full-light", { m in
                Theme.maxListHeight = 2_000
                m.showSystem = true
                m.banner = .init(text: "Stopped docs-site (2 processes).", isError: false)
            }, .aqua),
        ]
        for (name, configure, appearance) in jobs {
            let model = Sample.model()
            configure(model)
            render(name: name, model: model, appearance: appearance, into: directory)
        }
        renderMenuBarIcon(into: directory)
        print("Wrote \(jobs.count + 1) screenshots to \(directory.path)")
        exit(0)
    }

    /// The status-item icon at 4x, on a dark and a light strip, with and without the stale dot.
    private static func renderMenuBarIcon(into directory: URL) {
        let scale: CGFloat = 4
        let size = NSSize(width: 4 * 30 * scale, height: 24 * scale)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let cells: [(NSColor, Bool)] = [(.init(white: 0.12, alpha: 1), false), (.init(white: 0.12, alpha: 1), true),
                                        (.init(white: 0.92, alpha: 1), false), (.init(white: 0.92, alpha: 1), true)]
        for (i, cell) in cells.enumerated() {
            let frame = NSRect(x: CGFloat(i) * 30 * scale, y: 0, width: 30 * scale, height: size.height)
            cell.0.setFill()
            frame.fill()
            let icon = StatusItemController.menuBarImage(stale: cell.1)
            icon.draw(in: NSRect(x: frame.minX + 5 * scale, y: 4 * scale, width: icon.size.width * scale, height: icon.size.height * scale))
        }
        NSGraphicsContext.restoreGraphicsState()
        try? rep.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("menubar-icon.png"))
    }

    private static func render(name: String, model: AppModel, appearance: NSAppearance.Name, into directory: URL) {
        let root = PanelView(model: model).background(Color(nsColor: .windowBackgroundColor))
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(origin: .zero, size: NSSize(width: Theme.width, height: 400))
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -6_000, y: -6_000))   // rendered, never on screen
        window.orderFront(nil)
        // Let SwiftUI measure the list, then size to fit.
        for _ in 0..<3 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.15))
            host.frame.size = host.fittingSize
            window.setContentSize(host.fittingSize)
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))

        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        if let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: directory.appendingPathComponent("\(name).png"))
        }
        window.orderOut(nil)
    }
}

/// Invented processes and projects (nothing from the machine that renders them).
@MainActor
enum Sample {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    static func model() -> AppModel {
        var settings = Settings()
        settings.hotKey = .controlOptionP
        let strays = Staleness.apply(StrayBuilder.build(world(), project: project), now: now, settings: settings, activity: ActivityTracker())
        let model = AppModel(preview: strays, containers: containers, now: now, settings: settings)
        for s in strays where s.kind == .server {
            for p in s.ports { model.probes[model.probeKey(s, p)] = p == 5432 ? .other : .http }
        }
        return model
    }

    private static func started(_ hoursAgo: Double) -> Int64 { Int64((now.timeIntervalSince1970 - hoursAgo * 3600) * 1_000_000) }

    private static func p(_ pid: Int32, _ ppid: Int32, _ path: String, _ args: [String], cwd: String? = nil, tty: String? = nil,
                          hours: Double, cpu: Double = 1, mb: UInt64 = 60, uid: UInt32 = 501, listen: [UInt16] = [], name: String? = nil) -> ProcRecord {
        ProcRecord(pid: pid, ppid: ppid, uid: uid, name: name ?? String(path.split(separator: "/").last ?? ""), path: path, arguments: args,
                   cwd: cwd, tty: tty, startMicros: started(hours), cpuSeconds: cpu, residentBytes: mb * 1_048_576,
                   listening: listen.map { ListeningSocket(port: $0, address: $0 == 3001 ? "*" : "127.0.0.1", family: .ipv4) })
    }

    private static let node = "/opt/homebrew/bin/node"
    private static let shop = "/Users/demo/code/shop"
    private static let api = "/Users/demo/code/billing-api"
    private static let docs = "/Users/demo/code/docs-site"

    static func world() -> World {
        let records: [ProcRecord] = [
            p(1, 0, "/sbin/launchd", [], hours: 300, uid: 0),
            p(300, 1, "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal", ["Terminal"], hours: 100),
            p(310, 300, "/usr/bin/login", ["login"], tty: "ttys001", hours: 90, uid: 0),
            p(311, 310, "/bin/zsh", ["-zsh"], tty: "ttys001", hours: 90),
            p(312, 311, node, ["npm run dev"], cwd: shop, tty: "ttys001", hours: 5, cpu: 900, mb: 80, name: "node"),
            p(313, 312, node, ["node", "/Users/demo/code/shop/node_modules/.bin/next", "dev"], cwd: shop, tty: "ttys001", hours: 5, cpu: 1200, mb: 420, listen: [3000]),
            p(320, 300, "/usr/bin/login", ["login"], tty: "ttys002", hours: 80, uid: 0),
            p(321, 320, "/bin/zsh", ["-zsh"], tty: "ttys002", hours: 80),
            p(322, 321, "/Users/demo/.local/share/claude/versions/2.1.319", ["claude"], cwd: api, tty: "ttys002", hours: 52, cpu: 800, mb: 390, name: "2.1.319"),
            p(323, 322, node, ["node", "/opt/homebrew/lib/node_modules/chrome-devtools-mcp/build/src/index.js"], cwd: api, hours: 52),
            p(324, 322, "/Users/demo/.local/share/uv/tools/sqlite-mcp/bin/python", ["python", "/Users/demo/.local/share/uv/tools/sqlite-mcp/bin/sqlite-mcp"], cwd: api, hours: 52, mb: 30),
            p(325, 322, "/bin/zsh", ["/bin/zsh", "-c", "eval 'uvicorn app.main:app --reload --port 8000' < /dev/null"], cwd: api, hours: 1.5),
            p(326, 325, "/opt/homebrew/bin/python3.12", ["python3", "-m", "uvicorn", "app.main:app", "--reload", "--port", "8000"], cwd: api, hours: 1.5, cpu: 40, mb: 75, listen: [8000]),
            p(330, 300, "/usr/bin/login", ["login"], tty: "ttys003", hours: 3, uid: 0),
            p(331, 330, "/bin/zsh", ["-zsh"], tty: "ttys003", hours: 3),
            p(332, 331, "/Users/demo/.local/share/claude/versions/2.1.319", ["claude"], cwd: shop, tty: "ttys003", hours: 2.5, cpu: 300, mb: 350, name: "2.1.319"),
            p(340, 1, node, ["npm start"], cwd: docs, hours: 26, cpu: 3, mb: 25, name: "node"),
            p(341, 340, node, ["node", "/Users/demo/code/docs-site/node_modules/.bin/astro", "dev", "--port", "4321"], cwd: docs, hours: 26, cpu: 5, mb: 140, listen: [4321]),
            p(350, 311, "/opt/homebrew/bin/python3.12", ["python3", "scripts/sync_prices.py", "--watch"], cwd: shop, tty: "ttys001", hours: 30, cpu: 2, mb: 40),
            p(360, 1, "/opt/homebrew/opt/postgresql@16/bin/postgres", ["postgres", "-D", "/opt/homebrew/var/postgresql@16"], cwd: "/", hours: 200, cpu: 400, mb: 35, listen: [5432]),
            p(370, 1, "/System/Library/CoreServices/ControlCenter.app/Contents/MacOS/ControlCenter", ["ControlCenter"], cwd: "/", hours: 300, mb: 55, listen: [5000, 7000]),
        ]
        let sessions: [Int32: AgentSessionInfo] = [
            322: AgentSessionInfo(pid: 322, sessionID: "a", cwd: api, name: "billing-api-4f", status: .idle,
                                  updatedAt: now.addingTimeInterval(-28 * 3600), title: "Refund webhook retries"),
            332: AgentSessionInfo(pid: 332, sessionID: "b", cwd: shop, name: "shop-9c", status: .busy,
                                  updatedAt: now.addingTimeInterval(-20), title: "Checkout page redesign"),
        ]
        return World(records: records, currentUID: 501, selfPID: 99_999, home: "/Users/demo",
                     launchdLabels: [360: "homebrew.mxcl.postgresql@16"], agentSessions: sessions)
    }

    static func project(_ cwd: String?) -> ProjectRef? {
        ProjectResolver.resolve(cwd: cwd, home: "/Users/demo", exists: { [shop, api, docs].map { $0 + "/.git" }.contains($0) })
    }

    static let containers = [
        DockerContainer(id: "8dfafdbc3a40", name: "shop-redis-1", image: "redis:7", state: "running", status: "Up 5 hours",
                        created: now.addingTimeInterval(-5 * 3600), publishedPorts: [6379], project: "shop", service: "redis"),
    ]
}
