import AppKit
import Foundation
import Observation
import ServiceManagement
import StraysCore
import StraysSystem

/// Everything the panel shows, refreshed in the background.
@MainActor
@Observable
final class AppModel {
    enum Page { case list, settings }

    struct Banner: Equatable {
        var text: String
        var isError: Bool
    }

    /// A pending bulk stop waiting for its second click.
    struct BulkConfirm: Equatable {
        var label: String
        var strays: [Stray]
    }

    // Data
    var strays: [Stray] = []
    var containers: [DockerContainer] = []
    var dockerAvailable = false
    var processCount = 0
    var lastRefresh: Date?
    var isRefreshing = false
    var now = Date()

    // UI state
    var filter = ""
    var page: Page = .list
    var expanded: Set<ProcIdentity> = []
    var showSystem = false
    var stopping: Set<ProcIdentity> = []
    var stoppingContainers: Set<String> = []
    var rowErrors: [ProcIdentity: String] = [:]
    var banner: Banner?
    var bulkConfirm: BulkConfirm?
    var probes: [String: PortProtocol] = [:]
    var panelOpen = false { didSet { if panelOpen { refreshSoon() }; reschedule() } }

    var settings: Settings {
        didSet {
            guard settings != oldValue else { return }
            store?.settings = settings
            onSettingsChanged?(settings)
            reapplyStaleness()
        }
    }
    var launchAtLogin: Bool = false
    var notificationsDenied = false
    var onSettingsChanged: ((Settings) -> Void)?

    // Machinery (absent in snapshot mode)
    private let store: SettingsStore?
    private let scanner: StraysScanner?
    private var activity = ActivityTracker()
    private var records: [ProcRecord] = []
    private var timer: Timer?
    private var bannerTask: Task<Void, Never>?
    let isLive: Bool

    init() {
        let store = SettingsStore()
        self.store = store
        self.scanner = StraysScanner()
        self.settings = store.settings
        self.isLive = true
        self.launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    /// Canned data for snapshots and previews.
    init(preview strays: [Stray], containers: [DockerContainer] = [], now: Date, settings: Settings = Settings()) {
        self.store = nil
        self.scanner = nil
        self.settings = settings
        self.isLive = false
        self.strays = strays
        self.containers = containers
        self.dockerAvailable = !containers.isEmpty
        self.now = now
        self.lastRefresh = now.addingTimeInterval(-2)
        self.processCount = 874
    }

    // MARK: Derived

    var visible: [Stray] { Filter.apply(filter, to: strays) }
    var visibleContainers: [DockerContainer] {
        let query = filter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return containers }
        if let port = PortQuery.port(in: query) { return containers.filter { $0.publishedPorts.contains(port) } }
        return containers.filter { ($0.title + " " + $0.image + " " + $0.name).lowercased().contains(query) }
    }
    var serverCount: Int { strays.filter { $0.kind == .server }.count + containers.filter { !$0.publishedPorts.isEmpty }.count }
    var stale: [Stray] { strays.filter(\.isStale) }
    var filterPort: UInt16? { PortQuery.port(in: filter) }

    func section(_ kind: StrayKind) -> [Stray] { visible.filter { $0.kind == kind } }

    func probeKey(_ stray: Stray, _ port: UInt16) -> String { "\(stray.id):\(port)" }

    func httpURL(for stray: Stray) -> URL? {
        for socket in stray.sockets {
            switch probes[probeKey(stray, socket.port)] {
            case .http: return URL(string: "http://localhost:\(socket.port)")
            case .https: return URL(string: "https://localhost:\(socket.port)")
            default: continue
            }
        }
        return nil
    }

    // MARK: Refresh

    func start() {
        guard isLive else { return }
        refreshSoon()
        reschedule()
    }

    /// Every 3 s while the panel is open, every 30 s otherwise (enough for the badge and the nudge).
    private func reschedule() {
        guard isLive else { return }
        timer?.invalidate()
        let interval: TimeInterval = panelOpen ? 3 : 30
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshSoon() }
        }
        timer?.tolerance = interval / 5
    }

    func refreshSoon() {
        guard isLive else { return }
        Task { await refresh() }
    }

    func refresh() async {
        guard isLive, !isRefreshing, let scanner else { return }
        isRefreshing = true
        let settings = self.settings
        let activity = self.activity
        let result = await Task.detached(priority: .utility) { () -> (strays: [Stray], records: [ProcRecord], containers: [DockerContainer]?, now: Date) in
            let now = Date()
            let scan = scanner.scan(settings: settings, activity: activity, now: now)
            let containers = DockerClient.discover().flatMap { try? $0.containers() }
            return (scan.strays, scan.records, containers, now)
        }.value

        now = result.now
        strays = result.strays
        records = result.records
        processCount = result.records.count
        containers = result.containers ?? []
        dockerAvailable = result.containers != nil
        lastRefresh = result.now
        self.activity.record(result.strays, now: result.now, window: settings.idleWindow)
        self.activity.forget(except: Set(result.strays.map(\.id)))
        let alive = Set(result.strays.map(\.id))
        rowErrors = rowErrors.filter { alive.contains($0.key) }
        isRefreshing = false

        probeNewPorts()
        checkNudge()
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    private func reapplyStaleness() {
        strays = Staleness.apply(strays, now: now, settings: settings, activity: activity)
    }

    /// Asks each new server port once whether it speaks HTTP (for "Open in browser").
    private func probeNewPorts() {
        var jobs: [(String, UInt16, Bool)] = []
        for stray in strays where stray.kind == .server {
            for socket in stray.sockets where probes[probeKey(stray, socket.port)] == nil {
                let key = probeKey(stray, socket.port)
                probes[key] = .other   // claimed; replaced when the probe answers
                let v6Only = stray.sockets.filter { $0.port == socket.port }.allSatisfy { $0.family == .ipv6 }
                jobs.append((key, socket.port, v6Only && socket.address != "::"))
            }
        }
        guard !jobs.isEmpty else { return }
        Task.detached(priority: .utility) {
            var results: [String: PortProtocol] = [:]
            for (key, port, v6) in jobs { results[key] = PortProbe.probe(port: port, ipv6: v6) }
            await MainActor.run { [results] in
                for (key, value) in results { self.probes[key] = value }
            }
        }
    }

    // MARK: Stopping

    func stop(_ targets: [Stray], label: String) {
        let ids = targets.map(\.id)
        guard !ids.isEmpty else { return }
        ids.forEach { stopping.insert($0); rowErrors[$0] = nil }
        bulkConfirm = nil
        let grace = settings.stopGraceSeconds
        Task {
            let (plan, outcome) = await Task.detached(priority: .userInitiated) { () -> (StopPlan, StopOutcome) in
                // Plan from a fresh snapshot, so children started since the last refresh are included.
                let records = ProcessReader.snapshot()
                let plan = StopPlanner.plan(roots: ids, records: records, currentUID: getuid(), selfPID: getpid())
                return (plan, Stopper.execute(plan, grace: grace))
            }.value

            ids.forEach { stopping.remove($0) }
            for refusal in plan.refused { rowErrors[refusal.identity] = "Not stopped: \(refusal.reason.message)." }
            if !outcome.failed.isEmpty {
                let message = "\(outcome.failed.count) process\(outcome.failed.count == 1 ? "" : "es") still running."
                for id in ids where rowErrors[id] == nil { rowErrors[id] = message }
                show(Banner(text: "Couldn't stop everything in \(label).", isError: true))
            } else if !plan.targets.isEmpty {
                var text = "Stopped \(label) (\(plan.summary))"
                if !outcome.killed.isEmpty { text += ", \(outcome.killed.count) needed SIGKILL" }
                show(Banner(text: text + ".", isError: false))
            }
            await refresh()
        }
    }

    func stopContainer(_ container: DockerContainer) {
        stoppingContainers.insert(container.id)
        let grace = Int(settings.stopGraceSeconds)
        Task {
            let error = await Task.detached(priority: .userInitiated) { () -> String? in
                guard let client = DockerClient.discover() else { return "Docker isn't running." }
                do { try client.stop(containerID: container.id, graceSeconds: grace); return nil } catch { return "\(error)" }
            }.value
            stoppingContainers.remove(container.id)
            if let error {
                show(Banner(text: "Couldn't stop \(container.title): \(error)", isError: true))
            } else {
                show(Banner(text: "Stopped container \(container.title).", isError: false))
            }
            await refresh()
        }
    }

    func confirmBulk(_ label: String, _ targets: [Stray]) {
        bulkConfirm = targets.isEmpty ? nil : BulkConfirm(label: label, strays: targets)
    }

    private func show(_ banner: Banner) {
        self.banner = banner
        bannerTask?.cancel()
        bannerTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(banner.isError ? 8 : 5))
            guard !Task.isCancelled else { return }
            self?.banner = nil
        }
    }

    // MARK: Nudge

    private func checkNudge() {
        guard let store else { return }
        let stale = self.stale
        guard NudgePlanner.shouldNudge(now: now, staleCount: stale.count, lastNudgeDay: store.lastNudgeDay, settings: settings) else { return }
        store.lastNudgeDay = NudgePlanner.dayKey(now)
        Notifier.post(NudgePlanner.notice(for: stale, now: now))
    }

    // MARK: Settings actions

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            show(Banner(text: "macOS didn't allow that: \(error.localizedDescription)", isError: true))
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
        if on, SMAppService.mainApp.status == .requiresApproval {
            show(Banner(text: "Approve Strays in System Settings > General > Login Items.", isError: false))
            SMAppService.openSystemSettingsLoginItems()
        }
    }

    func refreshNotificationStatus() {
        Notifier.authorizationDenied { denied in
            Task { @MainActor in self.notificationsDenied = denied }
        }
    }
}
