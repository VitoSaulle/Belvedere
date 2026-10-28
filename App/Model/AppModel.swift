import AppKit
import BelvedereCore
import Observation

/// Stato dell'app: unisce indice dei log, hook e status line e li espone all'interfaccia.
@MainActor @Observable
final class AppModel {
    /// Sessioni visibili: tutte meno quelle nascoste. Plancia, sidebar, menu bar e notch usano queste.
    var sessions: [SessionSnapshot] = []
    /// Tutte le sessioni, nascoste comprese: statistiche e apertura per id.
    private(set) var allSessions: [SessionSnapshot] = []
    private(set) var hidden = HiddenSessions()
    var planLimits: PlanLimits?
    var lmStudio: LMStudioStatus?
    var feed: [ActivityEvent] = []
    var indexingProgress: Double?
    var hooksInstalled = false
    var serverError: String?
    private(set) var buckets: [UsageBucket] = []
    private(set) var policy: PermissionPolicy
    /// Backup di `~/.claude/settings.json` scritto dall'ultimo collegamento o scollegamento.
    private(set) var lastBackup: String? = UserDefaults.standard.string(forKey: "lastSettingsBackup")
    /// Foglio di benvenuto (primo avvio, o «Collega…» dalla Plancia).
    var showWelcome = false

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

    /// Sessioni lanciate da Belvedere in questa esecuzione, comprese quelle ferme.
    private(set) var hostedSessions: [HostedSession] = []
    /// Id delle sessioni nate in Belvedere, anche in esecuzioni precedenti: etichetta «Belvedere» e «Riprendi».
    private(set) var launchedIDs: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "launchedSessions") ?? [])
    private(set) var presets: [LaunchPreset] = {
        guard let data = UserDefaults.standard.data(forKey: "launchPresets") else { return [] }
        return (try? JSONDecoder().decode([LaunchPreset].self, from: data)) ?? []
    }()
    /// Foglio «Nuova sessione», con la cartella proposta.
    var showNewSession = false
    var newSessionFolder: String?
    /// Sessioni passate al terminale da questa esecuzione: osservate, così la vista si aggiorna subito.
    private(set) var handedOff: Set<String> = []
    /// Cartelle con un `claude` vivo che non è di Belvedere (terminale, IntelliJ…), aggiornate ogni 5 s;
    /// `nil` finché non sono state lette.
    private(set) var busyFolders: Set<String>?

    static let policyKey = "permissionPolicy"
    static let welcomeKey = "welcomeShown"
    static let limitsKey = "lastClaudeLimits"

    init(roots: TranscriptRoots = .default,
         policy: PermissionPolicy = PermissionPolicy(storageValue: UserDefaults.standard.string(forKey: AppModel.policyKey))) {
        self.roots = roots
        self.policy = policy
        index = TranscriptIndex(roots: roots, cacheURL: Belvedere.supportDirectory.appendingPathComponent("index.json"))
        broker = PermissionBroker(policy: policy)
    }

    var waitingCount: Int { sessions.filter { $0.status == .waiting }.count }
    var workingCount: Int { sessions.filter { $0.status == .working }.count }

    func session(_ id: String) -> SessionSnapshot? { allSessions.first { $0.id == id } }

    var hiddenSessions: [SessionSnapshot] { allSessions.filter { hidden.isHidden($0) } }

    /// Sessioni concluse da più di una settimana che si possono nascondere in blocco.
    var staleSessionIDs: [String] { HiddenSessions.staleIDs(sessions, olderThanDays: 7, now: Date()) }

    // MARK: - Sessioni nascoste

    func hide(_ ids: [String]) {
        let now = Date()
        for id in ids { hidden.hide(id, at: max(now, session(id)?.lastActivity ?? now)) }
        saveHidden()
        publish()
    }

    func unhide(_ id: String) {
        hidden.unhide(id)
        saveHidden()
        publish()
    }

    private static var hiddenURL: URL { Belvedere.supportDirectory.appendingPathComponent("hidden.json") }

    private func loadHidden() {
        guard let data = try? Data(contentsOf: Self.hiddenURL),
              let saved = try? JSONDecoder().decode(HiddenSessions.self, from: data) else { return }
        hidden = saved
    }

    private func saveHidden() {
        try? FileManager.default.createDirectory(at: Belvedere.supportDirectory, withIntermediateDirectories: true)
        try? JSONEncoder().encode(hidden).write(to: Self.hiddenURL, options: .atomic)
    }

    // MARK: - Avvio

    func start() async {
        guard !started else { return }
        started = true
        refreshBusyFolders()
        refreshHooksInstalled()
        loadHidden()
        if let data = UserDefaults.standard.data(forKey: Self.limitsKey),
           let saved = try? JSONDecoder().decode(PlanLimits.self, from: data) {
            store.apply(claudeLimits: saved)
            store.tick(now: Date())
        }
        startServer()
        if !hooksInstalled && !UserDefaults.standard.bool(forKey: Self.welcomeKey) { showWelcome = true }

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
        // `open Belvedere.app --args -BelvedereOpenSession <id>` apre direttamente una sessione.
        if let id = UserDefaults.standard.string(forKey: "BelvedereOpenSession") { route = .session(id) }
        if UserDefaults.standard.bool(forKey: "BelvedereOpenStats") { route = .stats }
        if UserDefaults.standard.bool(forKey: "BelvedereNewSession") {
            newSessionFolder = UserDefaults.standard.string(forKey: "BelvedereNewSessionFolder")
            showNewSession = true
        }
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
        await stopAllHosted()
        loops.forEach { $0.cancel() }
        watcher?.stop()
        server?.stop()
        await broker.cancelAll()
        await saveIndex()
    }

    func refreshHooksInstalled() {
        hooksInstalled = (try? ClaudeSettingsInstaller.isInstalled(SettingsFile().read(), port: Belvedere.defaultPort)) ?? false
    }

    // MARK: - Collegamento a Claude Code

    var watchedFolders: [URL] { [roots.claude, roots.codex] }

    /// Copia gli eseguibili e aggiunge hook e status line a `~/.claude/settings.json`, con backup.
    func connectClaude() throws {
        let helpers = try ClaudeSettingsInstaller.installHelpers(from: .main)
        let file = SettingsFile()
        var timeout: Double?
        if case .hold(let seconds) = PermissionPolicy.default { timeout = seconds }
        let updated = ClaudeSettingsInstaller.install(into: try file.read(), helpers: helpers,
                                                      port: Belvedere.defaultPort, permissionTimeout: timeout)
        remember(backup: try file.writeWithBackup(updated))
        refreshHooksInstalled()
    }

    /// Toglie solo le voci di Belvedere, con backup.
    func disconnectClaude() throws {
        let file = SettingsFile()
        let restored = ClaudeSettingsInstaller.uninstall(from: try file.read(), port: Belvedere.defaultPort)
        remember(backup: try file.writeWithBackup(restored))
        refreshHooksInstalled()
    }

    func setPolicy(_ newPolicy: PermissionPolicy) {
        policy = newPolicy
        UserDefaults.standard.set(newPolicy.storageValue, forKey: Self.policyKey)
        let broker = self.broker
        Task { await broker.setPolicy(newPolicy) }
    }

    func dismissWelcome() {
        showWelcome = false
        UserDefaults.standard.set(true, forKey: Self.welcomeKey)
    }

    private func remember(backup: URL?) {
        guard let backup else { return }
        lastBackup = backup.path
        UserDefaults.standard.set(backup.path, forKey: "lastSettingsBackup")
    }

    // MARK: - Azioni

    /// Risponde alla richiesta mostrata, identificata dal suo id: se nel frattempo ne è arrivata
    /// un'altra, la risposta non le passa.
    func respond(to request: PendingRequest, with decision: PermissionDecision) {
        for host in hostedSessions {
            guard let ask = host.state.asks.first(where: { $0.id == request.id }) else { continue }
            host.answer(ask, allow: decision == .allow)
            return
        }
        guard request.kind == .permission else { return }
        let broker = self.broker
        Task { await broker.resolve(requestID: request.id, with: decision) }
        store.clearPending(requestID: request.id)
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
        UsageStats.summarize(buckets: buckets, sessions: allSessions, range: range, project: project,
                             now: Date(), calendar: .current)
    }

    // MARK: - Sessioni lanciate da Belvedere

    /// Prefisso dell'id provvisorio usato nella navigazione finché Claude non comunica il `session_id`.
    static let provisionalPrefix = "belvedere:"

    func host(for routeID: String) -> HostedSession? {
        if routeID.hasPrefix(Self.provisionalPrefix) {
            let uuid = String(routeID.dropFirst(Self.provisionalPrefix.count))
            return hostedSessions.first { $0.id.uuidString == uuid }
        }
        return hostedSessions.last { $0.state.sessionID == routeID }
    }

    func isHosted(_ sessionID: String) -> Bool {
        hostedSessions.contains { $0.isRunning && $0.state.sessionID == sessionID }
    }

    var workingHostedCount: Int {
        hostedSessions.filter { $0.isRunning && ($0.state.status == .working || $0.state.status == .waiting) }.count
    }

    @discardableResult
    func launch(_ options: LaunchOptions, history: [TranscriptItem] = []) -> HostedSession {
        let host = HostedSession(options: options, history: history)
        host.onChange = { [weak self, weak host] in
            guard let self, let host else { return }
            self.hostChanged(host)
        }
        host.resumeBlocker = { [weak self, weak host] in
            guard let self, let host else { return nil }
            let folder = host.state.cwd ?? host.options.folder
            guard self.claudeFolders().contains(RunningProcesses.canonical(folder)) else { return nil }
            return "Claude Code è già aperto in questa cartella, ad esempio in un terminale: chiudilo per continuare qui."
        }
        hostedSessions.append(host)
        host.start()
        route = .session(host.state.sessionID ?? Self.provisionalPrefix + host.id.uuidString)
        return host
    }

    /// Riprende in Belvedere una sessione vista nei log, con la sua conversazione.
    func resume(_ sessionID: String) {
        guard let s = session(sessionID) else { return }
        if let existing = host(for: sessionID) {
            existing.restart()
            route = .session(sessionID)
            return
        }
        let history = (try? TranscriptMessages.load(path: s.transcriptPath, agent: .claude)) ?? []
        launch(LaunchOptions.resuming(s), history: history)
    }

    /// «Riprendi in Belvedere» solo se la sessione non è viva altrove: mai due processi sulla stessa sessione.
    func canResumeHere(_ s: SessionSnapshot) -> Bool {
        guard s.agent == .claude, !s.cwd.isEmpty, !isHosted(s.id) else { return false }
        // Se nessun `claude` di altri lavora in quella cartella, la sessione non è viva altrove:
        // vale anche dopo un crash (log fermo su «al lavoro») e per le sessioni nate prima di Belvedere.
        guard let busyFolders, !busyFolders.contains(RunningProcesses.canonical(s.cwd)) else { return false }
        // Passata al terminale: finché quel processo vive, anche prima dei suoi hook, la sessione è sua.
        let pidFile = Self.handoffPID(s.id)
        // Appena passata il PID può non essere ancora scritto: intanto vale come occupata.
        if handedOff.contains(s.id), !FileManager.default.fileExists(atPath: pidFile.path) { return false }
        return !TerminalHandoff.isRunning(pidFile: pidFile)
    }

    /// Cartelle dei `claude` vivi, esclusi quelli lanciati da Belvedere.
    private func claudeFolders() -> Set<String> {
        RunningProcesses.folders(named: "claude", excluding: Set(hostedSessions.compactMap(\.pid)))
    }

    private func refreshBusyFolders() {
        let folders = claudeFolders()
        if folders != busyFolders { busyFolders = folders }
    }

    private static func handoffPID(_ id: String) -> URL {
        Belvedere.supportDirectory.appendingPathComponent("handoff/\(id).pid")
    }

    /// Ferma il processo di Belvedere e apre la sessione nel terminale con `claude --resume`.
    func openInTerminal(_ sessionID: String) async {
        let host = host(for: sessionID)
        // Senza id (nessun messaggio ancora inviato) non c'è niente da riprendere nel terminale.
        guard let s = host?.state.snapshot(launchedAt: host?.launchedAt) ?? session(sessionID),
              let binary = host?.binary ?? HostedSession(options: LaunchOptions(folder: "/")).binary else { return }
        await host?.stop()
        // Da qui la sessione è del terminale: Belvedere la osserva soltanto.
        if let host {
            hostedSessions.removeAll { $0 === host }
            route = .session(s.id)
        }
        let folder = Belvedere.supportDirectory.appendingPathComponent("handoff")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("\(s.id).command")
        // Una sessione locale resta su LM Studio anche nel terminale.
        let options = host.map { $0.options.resuming(s.id, cwd: s.cwd) } ?? LaunchOptions.resuming(s)
        let local = options.local == nil ? [:] : ClaudeCommand.environment(options, base: [:])
        let script = TerminalHandoff.script(cwd: s.cwd, sessionID: s.id, binary: binary,
                                            pidFile: Self.handoffPID(s.id).path, environment: local)
        try? FileManager.default.removeItem(at: Self.handoffPID(s.id))
        handedOff.insert(s.id)
        do {
            try script.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            NSWorkspace.shared.open(url)
            refreshBusyFolders()
        } catch {
            serverError = "Non riesco ad aprire il terminale: \(error.localizedDescription)"
        }
        syncHosted()
    }

    func stopAllHosted() async {
        for host in hostedSessions where host.isRunning { await host.stop() }
        syncHosted()
    }

    func savePreset(name: String, options: LaunchOptions) {
        presets.append(LaunchPreset(name: name, options: options))
        storePresets()
    }

    func deletePreset(_ id: UUID) {
        presets.removeAll { $0.id == id }
        storePresets()
    }

    private func storePresets() {
        if let data = try? JSONEncoder().encode(presets) { UserDefaults.standard.set(data, forKey: "launchPresets") }
    }

    private func hostChanged(_ host: HostedSession) {
        if let id = host.state.sessionID {
            if !launchedIDs.contains(id) {
                launchedIDs.insert(id)
                UserDefaults.standard.set(Array(launchedIDs), forKey: "launchedSessions")
            }
            // La navigazione passa dall'id provvisorio a quello vero appena Claude lo comunica.
            if route == .session(Self.provisionalPrefix + host.id.uuidString) { route = .session(id) }
        } else if let old = host.clearedFrom, route == .session(old) {
            // Dopo /clear la chat resta questa, in attesa del nuovo id.
            route = .session(Self.provisionalPrefix + host.id.uuidString)
        }
        if let limits = host.state.limits, limits != store.claudeLimits {
            store.apply(claudeLimits: limits)
            if let data = try? JSONEncoder().encode(limits) { UserDefaults.standard.set(data, forKey: Self.limitsKey) }
        }
        syncHosted()
    }

    private func syncHosted() {
        let live = hostedSessions.filter(\.isRunning)
        let exited = hostedSessions.filter { !$0.isRunning }
        store.setHosted(Set(live.compactMap(\.state.sessionID)), exited: Set(exited.compactMap(\.state.sessionID)))
        for host in hostedSessions {
            if let snapshot = host.state.snapshot(launchedAt: host.launchedAt) { store.apply(hosted: snapshot) }
        }
        store.tick(now: Date())
        publish()
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
                // Le sessioni di Belvedere chiedono il permesso nella chat: il hook globale non deve duplicarlo.
                if await self?.isHosted(event.sessionID) == true { return (200, Data()) }
                let holding = await broker.isHolding
                let decision = await broker.decision(for: event.requestID)
                // Finita l'attesa (risposta, scadenza o hook chiuso dal terminale) la richiesta
                // non si può più servire da qui. In sola osservazione resta finché i hook la chiudono.
                if holding { await self?.requestClosed(event.requestID) }
                return (200, HookResponse.body(for: decision))
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

    private func requestClosed(_ requestID: String) {
        store.clearPending(requestID: requestID)
        publish()
    }

    private func ingest(_ event: HookEvent, origin: SessionOrigin?) {
        let closed = store.apply(event, origin: origin)
        if !closed.isEmpty {
            let broker = self.broker
            Task { for id in closed { await broker.cancel(requestID: id) } }
        }
        if event.name == "PreCompact" || event.name == "PostCompact" {
            let name = session(event.sessionID)?.displayName ?? event.sessionID
            let text = event.name == "PreCompact" ? "compatta il contesto" : "contesto compattato"
            addToFeed([ActivityEvent(date: Date(), sessionID: event.sessionID, text: "\(name) · \(text)")])
        }
        publish()
    }

    private func ingest(_ payload: StatusLinePayload) {
        store.apply(payload)
        if let limits = payload.limits, let data = try? JSONEncoder().encode(limits) {
            UserDefaults.standard.set(data, forKey: Self.limitsKey)
        }
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
        refreshBusyFolders()
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
        if feedReady { addToFeed(ActivityFeed.events(from: allSessions, to: next, now: Date())) }
        if next != allSessions { allSessions = next }
        let visible = next.filter { !hidden.isHidden($0) }
        if visible != sessions { sessions = visible }
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
