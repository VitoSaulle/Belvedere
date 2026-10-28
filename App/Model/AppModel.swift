import AppKit
import BelvedereCore
import Observation

/// Stato dell'app: unisce indice dei log, hook e status line e li espone all'interfaccia.
@MainActor @Observable
final class AppModel {
    var sessions: [SessionSnapshot] = []
    var planLimits: PlanLimits?
    var lmStudio: LMStudioStatus?
    var feed: [ActivityEvent] = []
    var indexingProgress: Double?
    var hooksInstalled = false
    var serverError: String?
    private(set) var buckets: [UsageBucket] = []
    let policy: PermissionPolicy

    /// Navigazione condivisa tra finestra, menu bar e scorciatoie.
    var route: Route = .plancia
    /// Cartella su cui è filtrata la Plancia, scelta dalla sezione «Progetti».
    var projectFilter: String?

    @ObservationIgnored private var store = LiveSessionStore()
    @ObservationIgnored private let roots: TranscriptRoots
    @ObservationIgnored private let index: TranscriptIndex
    @ObservationIgnored private let broker: PermissionBroker
    @ObservationIgnored private let lmMonitor = LMStudioMonitor()
    @ObservationIgnored private var server: LocalHTTPServer?
    @ObservationIgnored private var watcher: DirectoryWatcher?
    @ObservationIgnored private var loops: [Task<Void, Never>] = []
    @ObservationIgnored private var started = false
    /// Il primo giro dell'indice non genera eventi: sarebbero centinaia di «nuova sessione».
    @ObservationIgnored private var feedReady = false

    init(roots: TranscriptRoots = .default, policy: PermissionPolicy = .default) {
        self.roots = roots
        self.policy = policy
        index = TranscriptIndex(roots: roots, cacheURL: Belvedere.supportDirectory.appendingPathComponent("index.json"))
        broker = PermissionBroker(policy: policy)
    }

    var waitingCount: Int { sessions.filter { $0.status == .waiting }.count }
    var workingCount: Int { sessions.filter { $0.status == .working }.count }

    func session(_ id: String) -> SessionSnapshot? { sessions.first { $0.id == id } }

    // MARK: - Avvio

    func start() async {
        guard !started else { return }
        started = true
        refreshHooksInstalled()
        startServer()

        let watcher = DirectoryWatcher(paths: [roots.claude, roots.codex]) { [weak self] paths in
            let relevant = paths.filter { $0.hasSuffix(".jsonl") }
            guard !relevant.isEmpty else { return }
            Task { @MainActor in await self?.refresh(paths: relevant) }
        }
        watcher.start()
        self.watcher = watcher

        // La cache dell'indice contiene già le sessioni note: si mostrano subito,
        // poi refreshAll porta solo ciò che è cambiato da allora.
        await absorb(IndexUpdate(changed: await index.sessions, newBuckets: []))
        indexingProgress = 0
        let update = await index.refreshAll { [weak self] progress in
            Task { @MainActor in self?.indexingProgress = progress }
        }
        await absorb(update)
        indexingProgress = nil
        feedReady = true

        loops.append(repeating(every: .seconds(5)) { model in model.tick() })
        loops.append(repeating(every: .seconds(10)) { model in await model.pollLMStudio() })
        loops.append(repeating(every: .seconds(60)) { model in await model.saveIndex() })
        await pollLMStudio()
    }

    /// Ferma server e sorveglianza e salva l'indice: chiamato prima di uscire.
    func shutdown() async {
        loops.forEach { $0.cancel() }
        watcher?.stop()
        server?.stop()
        await broker.cancelAll()
        await saveIndex()
    }

    func refreshHooksInstalled() {
        hooksInstalled = (try? ClaudeSettingsInstaller.isInstalled(SettingsFile().read(), port: Belvedere.defaultPort)) ?? false
    }

    // MARK: - Azioni

    func respond(to sessionID: String, with decision: PermissionDecision) {
        guard let pending = session(sessionID)?.pending, pending.kind == .permission else { return }
        let broker = self.broker
        Task { await broker.resolve(requestID: pending.id, with: decision) }
        store.clearPending(sessionID: sessionID)
        publish()
    }

    func activateOrigin(of sessionID: String) {
        guard let origin = session(sessionID)?.origin else { return }
        if let pid = origin.pid, let app = NSRunningApplication(processIdentifier: pid) {
            app.activate()
        } else if let bundleID = origin.bundleID,
                  let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    func stats(range: StatsRange, project: String?) -> StatsSummary {
        UsageStats.summarize(buckets: buckets, sessions: sessions, range: range, project: project,
                             now: Date(), calendar: .current)
    }

    // MARK: - Canali

    private func startServer() {
        let broker = self.broker
        let server = LocalHTTPServer(port: Belvedere.defaultPort) { [weak self] method, path, body in
            guard method == "POST" else { return (404, Data()) }
            if path.hasPrefix("/hooks/") {
                let name = String(path.dropFirst("/hooks/".count))
                guard let event = try? HookEvent.decode(name: name, body: body) else { return (400, Data()) }
                let origin = event.callerPID.flatMap { OriginResolver.resolve(pid: $0) }
                await self?.ingest(event, origin: origin)
                guard name == "PermissionRequest" else { return (200, Data()) }
                return (200, HookResponse.body(for: await broker.decision(for: event.requestID)))
            }
            if path == "/statusline" {
                guard let payload = try? StatusLinePayload.decode(body, now: Date()) else { return (400, Data()) }
                await self?.ingest(payload)
                return (200, Data())
            }
            return (404, Data())
        }
        do {
            try server.start()
            self.server = server
            serverError = nil
        } catch {
            serverError = "Il server locale non parte sulla porta \(Belvedere.defaultPort): \(error.localizedDescription)"
        }
    }

    private func ingest(_ event: HookEvent, origin: SessionOrigin?) {
        store.apply(event, origin: origin)
        if event.name == "PreCompact" || event.name == "PostCompact" {
            let name = session(event.sessionID)?.displayName ?? event.sessionID
            let text = event.name == "PreCompact" ? "compatta il contesto" : "contesto compattato"
            addToFeed([ActivityEvent(date: Date(), sessionID: event.sessionID, text: "\(name) · \(text)")])
        }
        publish()
    }

    private func ingest(_ payload: StatusLinePayload) {
        store.apply(payload)
        publish()
    }

    private func refresh(paths: [String]) async {
        await absorb(await index.refresh(paths: paths))
    }

    private func absorb(_ update: IndexUpdate) async {
        store.apply(update)
        store.apply(codexLimits: await index.latestCodexLimits)
        if !update.newBuckets.isEmpty || buckets.isEmpty { buckets = await index.buckets }
        publish()
    }

    private func tick() {
        store.tick(now: Date())
        publish()
    }

    private func pollLMStudio() async {
        lmStudio = await lmMonitor.poll()
    }

    private func saveIndex() async {
        try? await index.save()
    }

    private func publish() {
        let next = store.sessions
        if feedReady { addToFeed(ActivityFeed.events(from: sessions, to: next, now: Date())) }
        if next != sessions { sessions = next }
        let limits = store.planLimits
        if limits != planLimits { planLimits = limits }
    }

    private func addToFeed(_ events: [ActivityEvent]) {
        guard !events.isEmpty else { return }
        feed.insert(contentsOf: events, at: 0)
        if feed.count > ActivityFeed.limit { feed.removeLast(feed.count - ActivityFeed.limit) }
    }

    private func repeating(every interval: Duration, _ body: @escaping @MainActor (AppModel) async -> Void) -> Task<Void, Never> {
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard let self else { return }
                await body(self)
            }
        }
    }
}
