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
    /// Limiti del piano Claude del profilo attivo; quelli di Codex sono di un altro piano e restano a parte.
    var planLimits: PlanLimits?
    var codexLimits: PlanLimits?
    /// Account di Claude Code e Codex, con il profilo attivo di ciascuna CLI.
    private(set) var profiles: ProfileSet
    /// Plancia e sidebar mostrano solo le sessioni dei profili attivi.
    var showOnlyActiveProfile = UserDefaults.standard.bool(forKey: AppModel.onlyActiveKey) {
        didSet { UserDefaults.standard.set(showOnlyActiveProfile, forKey: Self.onlyActiveKey) }
    }
    /// Profili Claude senza hook e status line di Belvedere.
    private(set) var unconnectedProfiles: [Profile] = []
    /// Conversazioni presenti in più profili (cartella copiata a mano): se ne mostra una sola.
    private(set) var duplicateSessionCount = 0
    /// Una conversazione che non è passata a un altro profilo: la chat propone una sessione nuova.
    var transferFailure: TransferFailure?
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
    @ObservationIgnored private var roots: TranscriptRoots
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
    var showPlugins = false
    let plugins = PluginManager()
    var newSessionFolder: String?
    /// Sessioni passate al terminale da questa esecuzione: osservate, così la vista si aggiorna subito.
    private(set) var handedOff: Set<String> = []
    /// Cartelle con un `claude` o un `codex` vivo che non è di Belvedere (terminale, IntelliJ…),
    /// aggiornate ogni 5 s; `nil` finché non sono state lette.
    private(set) var busyFolders: [AgentKind: Set<String>]?
    /// Sessioni passate al terminale il cui processo è ancora vivo; aggiornato col tick, non a ogni ridisegno.
    private(set) var terminalOwned: Set<String> = []
    @ObservationIgnored private var savedWindows: [String: Int] = [:]
    @ObservationIgnored private var hookDuplicates = HookDeduplicator()
    /// Trasferimenti aperti (salvati su disco) e la chat che li conferma, con i turni già fatti all'inizio.
    @ObservationIgnored private var openTransfers: [PendingTransfer] = []
    @ObservationIgnored private var transferHosts: [UUID: (transfer: PendingTransfer, baseline: Int)] = [:]

    static let policyKey = "permissionPolicy"
    static let welcomeKey = "welcomeShown"
    static let limitsKey = "lastClaudeLimits"
    static let limitsByProfileKey = "lastClaudeLimitsByProfile"
    static let onlyActiveKey = "showOnlyActiveProfile"
    static let windowsKey = "knownContextWindows"

    init(policy: PermissionPolicy = PermissionPolicy(storageValue: UserDefaults.standard.string(forKey: AppModel.policyKey))) {
        let profiles = Self.loadProfiles()
        let roots = TranscriptRoots.from(profiles)
        self.profiles = profiles
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

    // MARK: - Eliminazione

    /// Si elimina solo una sessione ferma: non al lavoro, non in attesa, non aperta in Belvedere.
    func canDelete(_ s: SessionSnapshot) -> Bool {
        [.done, .idle, .ended].contains(s.status) && !isHosted(s.id)
    }

    /// Sessioni concluse da più di una settimana, nascoste comprese, che si possono eliminare in blocco.
    var staleDeletableIDs: [String] {
        HiddenSessions.staleIDs(allSessions, olderThanDays: 7, now: Date()).filter { id in session(id).map(canDelete) ?? false }
    }

    /// Cancella dal disco i file delle sessioni, senza passare dal Cestino. Le statistiche restano.
    func delete(_ ids: [String]) async {
        let ids = Set(ids.filter { id in session(id).map(canDelete) ?? false })
        guard !ids.isEmpty else { return }
        let deleted = Set(await index.delete(sessionIDs: ids))
        guard !deleted.isEmpty else { return }
        hostedSessions.removeAll { !$0.isRunning && deleted.contains($0.state.sessionID ?? "") }
        if case .session(let id) = route, deleted.contains(id) { route = .plancia }
        for id in deleted { hidden.unhide(id) }
        saveHidden()
        store.forget(deleted)
        syncHosted()
        await saveIndex()
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
        store.setRoots(roots)
        store.setDefaults(defaultProfileIDs)
        plugins.profile = profiles.active(.claude)
        restoreLimits()
        if let windows = UserDefaults.standard.dictionary(forKey: Self.windowsKey) as? [String: Int] {
            store.restore(knownWindows: windows)
            savedWindows = windows
        }
        // In dimostrazione niente server: i hook delle sessioni vere non devono comparire.
        if Belvedere.demoHome == nil { startServer() }
        if !hooksInstalled && !UserDefaults.standard.bool(forKey: Self.welcomeKey) { showWelcome = true }

        startWatcher()
        // Trasferimenti rimasti aperti da un'esecuzione precedente: la copia sparisce, l'origine resta.
        // Se l'origine non c'è più la conferma si era fermata a metà: la copia è l'unica rimasta e vale come confermata.
        for transfer in ProfileTransfer.load() {
            let sourceExists = FileManager.default.fileExists(atPath: transfer.sourcePaths[0])
            ProfileTransfer.rollback(transfer)
            _ = await index.endTransfer(transfer, confirmed: !sourceExists)
        }
        try? ProfileTransfer.save([])

        // La cache dell'indice contiene già le sessioni note: si mostrano subito,
        // poi refreshAll porta solo ciò che è cambiato da allora.
        await absorb(IndexUpdate(changed: await index.sessions, newBuckets: []))
        // `open Belvedere.app --args -BelvedereOpenSession <id>` apre direttamente una sessione.
        if let id = UserDefaults.standard.string(forKey: "BelvedereOpenSession") { route = .session(id) }
        if UserDefaults.standard.bool(forKey: "BelvedereOpenStats") { route = .stats }
        if UserDefaults.standard.bool(forKey: "BelvedereShowPlugins") { showPlugins = true }
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
        loops.append(repeating(every: .seconds(5)) { model in await model.pollCodex() })
        loops.append(repeating(every: .seconds(10)) { model in await model.pollLMStudio() })
        loops.append(repeating(every: .seconds(60)) { model in await model.saveIndex() })
        await pollLMStudio()
    }

    /// Ferma server e sorveglianza e salva l'indice: chiamato prima di uscire.
    func shutdown() async {
        await stopAllHosted()
        for hostID in Array(transferHosts.keys) { await finishTransfer(hostID, confirmed: false) }
        loops.forEach { $0.cancel() }
        watcher?.stop()
        server?.stop()
        await broker.cancelAll()
        await saveIndex()
    }

    /// Collegato = tutti i profili Claude (con la cartella sul disco) hanno hook e status line.
    func refreshHooksInstalled() {
        // Il predefinito conta anche senza cartella: senza `~/.claude` Belvedere non è collegato.
        unconnectedProfiles = profiles.profiles(.claude).filter { p in
            (p.isDefault || !profileFolderMissing(p))
                && !((try? ClaudeSettingsInstaller.isInstalled(SettingsFile(profile: p).read(), port: Belvedere.defaultPort)) ?? false)
        }
        hooksInstalled = unconnectedProfiles.isEmpty
    }

    // MARK: - Collegamento a Claude Code

    var watchedFolders: [URL] { roots.urls }

    /// Copia gli eseguibili e aggiunge hook e status line al `settings.json` di ogni profilo Claude, con backup.
    /// Un profilo che non si riesce a collegare non ferma gli altri.
    func connectClaude() throws {
        let helpers = try ClaudeSettingsInstaller.installHelpers(from: .main)
        var failure: Error?
        for p in profiles.profiles(.claude) where p.isDefault || !profileFolderMissing(p) {
            do { try connect(p, helpers: helpers) } catch { failure = failure ?? error }
        }
        refreshHooksInstalled()
        if let failure { throw failure }
    }

    private func connect(_ profile: Profile, helpers: URL) throws {
        let file = SettingsFile(profile: profile)
        var timeout: Double?
        if case .hold(let seconds) = PermissionPolicy.default { timeout = seconds }
        let updated = ClaudeSettingsInstaller.install(into: try file.read(), helpers: helpers,
                                                      port: Belvedere.defaultPort, permissionTimeout: timeout)
        let backup = try file.writeWithBackup(updated)
        if profile.isDefault { remember(backup: backup) }
    }

    /// Toglie solo le voci di Belvedere da ogni profilo Claude, con backup.
    func disconnectClaude() throws {
        var failure: Error?
        for p in profiles.profiles(.claude) where !profileFolderMissing(p) {
            do {
                let file = SettingsFile(profile: p)
                let restored = ClaudeSettingsInstaller.uninstall(from: try file.read(), port: Belvedere.defaultPort)
                let backup = try file.writeWithBackup(restored)
                if p.isDefault { remember(backup: backup) }
            } catch { failure = failure ?? error }
        }
        refreshHooksInstalled()
        if let failure { throw failure }
    }

    // MARK: - Profili

    private static func loadProfiles() -> ProfileSet {
        // In dimostrazione i profili puntano sempre dentro la home dimostrativa.
        if Belvedere.demoHome != nil { return .initial(home: Belvedere.home) }
        if let data = UserDefaults.standard.data(forKey: ProfileSet.storageKey),
           let saved = try? JSONDecoder().decode(ProfileSet.self, from: data) { return saved }
        let initial = ProfileSet.initial(home: Belvedere.home)
        if let data = try? JSONEncoder().encode(initial) { UserDefaults.standard.set(data, forKey: ProfileSet.storageKey) }
        return initial
    }

    private func saveProfiles() {
        guard Belvedere.demoHome == nil, let data = try? JSONEncoder().encode(profiles) else { return }
        UserDefaults.standard.set(data, forKey: ProfileSet.storageKey)
    }

    private var defaultProfileIDs: [AgentKind: UUID] {
        Dictionary(uniqueKeysWithValues: AgentKind.allCases.map { ($0, profiles.defaultProfile($0).id) })
    }

    /// Il profilo di una sessione; quelle senza (cache di versioni precedenti) sono del predefinito.
    func profile(of s: SessionSnapshot) -> Profile {
        profiles.profile(s.profileID) ?? profiles.defaultProfile(s.agent)
    }

    func isActiveProfile(_ s: SessionSnapshot) -> Bool {
        profile(of: s).id == profiles.active(s.agent).id
    }

    func profileFolderMissing(_ p: Profile) -> Bool {
        !FileManager.default.fileExists(atPath: p.configDir)
    }

    func limits(for profile: UUID) -> PlanLimits? { store.planLimits(profile: profile) }

    func setActiveProfile(_ id: UUID) {
        guard let p = profiles.profile(id), !profileFolderMissing(p) else { return }
        profiles.setActive(id)
        saveProfiles()
        plugins.profile = profiles.active(.claude)
        publish()
    }

    /// Crea il profilo (con le impostazioni del predefinito, se richiesto) e lo collega se gli altri lo sono.
    @discardableResult
    func addProfile(name: String, agent: AgentKind, folder: String, seedSettings: Bool) async throws -> Profile {
        let path = URL(fileURLWithPath: (folder as NSString).expandingTildeInPath).standardizedFileURL.path
        guard !profiles.profiles.contains(where: { URL(fileURLWithPath: $0.configDir).standardizedFileURL.path == path }) else {
            throw ProfileError.folderInUse
        }
        let profile = Profile(name: name, agent: agent, configDir: path)
        if seedSettings {
            try ProfileSettings.seed(from: profiles.defaultProfile(agent), to: profile, port: Belvedere.defaultPort)
        } else {
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        }
        let wasConnected = hooksInstalled
        profiles.add(profile)
        saveProfiles()
        if agent == .claude, wasConnected {
            try? connect(profile, helpers: try ClaudeSettingsInstaller.installHelpers(from: .main))
        }
        refreshHooksInstalled()
        await profilesChanged()
        return profile
    }

    func renameProfile(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        profiles.rename(id, to: trimmed)
        saveProfiles()
        plugins.profile = profiles.active(.claude)
    }

    /// Il profilo esce da Belvedere con le sue sessioni; la cartella resta sul disco, le statistiche pure.
    func removeProfile(_ id: UUID) async {
        guard let p = profiles.profile(id), !p.isDefault else { return }
        let gone = Set(allSessions.filter { $0.profileID == id }.map(\.id))
        profiles.remove(id)
        saveProfiles()
        plugins.profile = profiles.active(.claude)
        refreshHooksInstalled()
        await profilesChanged()
        store.forget(gone)
        publish()
    }

    /// Apre il Terminale con il login della CLI nella cartella del profilo: il login lo fa la CLI.
    func login(_ profile: Profile) {
        guard let binary = HostedSession(options: LaunchOptions(folder: "/", agent: profile.agent)).binary else {
            serverError = "\(profile.agent.productName) non trovato: installa la CLI o aggiungila al PATH."
            return
        }
        let folder = Belvedere.supportDirectory.appendingPathComponent("handoff")
        let url = folder.appendingPathComponent("login-\(profile.id.uuidString).command")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try TerminalHandoff.loginScript(profile: profile, binary: binary).write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            NSWorkspace.shared.open(url)
        } catch {
            serverError = "Non riesco ad aprire il terminale: \(error.localizedDescription)"
        }
    }

    private func profilesChanged() async {
        let newRoots = TranscriptRoots.from(profiles)
        guard newRoots != roots else { publish(); return }
        roots = newRoots
        store.setRoots(newRoots)
        store.setDefaults(defaultProfileIDs)
        startWatcher()
        await absorb(await index.setRoots(newRoots))
    }

    private func startWatcher() {
        watcher?.stop()
        let watcher = DirectoryWatcher(paths: roots.urls) { [weak self] paths in
            let relevant = paths.filter { $0.hasSuffix(".jsonl") }
            guard !relevant.isEmpty else { return }
            Task { @MainActor in await self?.refresh(paths: relevant) }
        }
        watcher.start()
        self.watcher = watcher
    }

    private func restoreLimits() {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: Self.limitsByProfileKey),
           let saved = try? JSONDecoder().decode([String: PlanLimits].self, from: data) {
            store.restore(claudeLimits: Dictionary(uniqueKeysWithValues: saved.compactMap { key, value in
                UUID(uuidString: key).map { ($0, value) }
            }))
        } else if let data = defaults.data(forKey: Self.limitsKey),
                  let saved = try? JSONDecoder().decode(PlanLimits.self, from: data) {
            // Prima dei profili c'era un solo account: i suoi limiti vanno al predefinito.
            store.restore(claudeLimits: [profiles.defaultProfile(.claude).id: saved])
            saveLimits()
        }
        store.tick(now: Date())
    }

    private func saveLimits() {
        let byProfile = Dictionary(uniqueKeysWithValues: store.claudeLimits.map { ($0.key.uuidString, $0.value) })
        if let data = try? JSONEncoder().encode(byProfile) { UserDefaults.standard.set(data, forKey: Self.limitsByProfileKey) }
    }

    /// Sessioni della Plancia e della sidebar: con «Solo profilo attivo» quelle degli altri profili escono.
    /// Menu bar e notch usano `sessions`: le richieste arrivano da tutti i profili.
    var boardSessions: [SessionSnapshot] {
        guard showOnlyActiveProfile, AgentKind.allCases.contains(where: profiles.hasChoice) else { return sessions }
        return sessions.filter(isActiveProfile)
    }

    // MARK: - Continuare in un altro profilo

    /// Gli altri profili della stessa CLI, con la cartella sul disco.
    func continueTargets(_ s: SessionSnapshot) -> [Profile] {
        let current = profile(of: s).id
        return profiles.profiles(s.agent).filter { $0.id != current && !profileFolderMissing($0) }
    }

    /// Il profilo con più margine nella finestra di 5 ore; uno senza limiti noti vale come libero.
    func bestTarget(_ s: SessionSnapshot) -> Profile? {
        continueTargets(s).min { (limits(for: $0.id)?.fiveHour?.usedPercent ?? 0) < (limits(for: $1.id)?.fiveHour?.usedPercent ?? 0) }
    }

    /// La sessione si è fermata per il limite del piano: errore della chat o finestra di 5 ore piena.
    func hitPlanLimit(_ s: SessionSnapshot) -> Bool {
        if let error = host(for: s.id)?.state.lastError, error.localizedCaseInsensitiveContains("limit") { return true }
        return (limits(for: profile(of: s).id)?.fiveHour?.usedPercent ?? 0) >= 100
    }

    /// Una conversazione ferma, non aperta altrove, con un file da spostare.
    func canContinueElsewhere(_ s: SessionSnapshot) -> Bool {
        guard ![.working, .waiting].contains(s.status), !s.cwd.isEmpty, !s.transcriptPath.isEmpty,
              profiles.hasChoice(s.agent), !openTransfers.contains(where: { $0.sessionID == s.id }) else { return false }
        guard let busy = busyFolders?[s.agent], !busy.contains(RunningProcesses.canonical(s.cwd)) else { return false }
        return !terminalOwned.contains(s.id)
    }

    /// Sposta la conversazione nel profilo e la riprende lì. L'originale si cancella alla prima risposta riuscita;
    /// se la ripresa fallisce o la chat si chiude prima, la copia sparisce e l'originale resta.
    func continueIn(_ sessionID: String, profile targetID: UUID) async {
        guard let s = session(sessionID), canContinueElsewhere(s),
              let target = profiles.profile(targetID), target.agent == s.agent else { return }
        let source = profile(of: s)
        guard source.id != target.id else { return }
        transferFailure = nil
        if let host = host(for: sessionID) {
            await host.stop()
            hostedSessions.removeAll { $0 === host }
            syncHosted()
        }
        let transfer: PendingTransfer
        do {
            transfer = try ProfileTransfer.begin(transcriptPath: s.transcriptPath, sessionID: s.id, agent: s.agent,
                                                 from: source, to: target)
        } catch {
            transferFailure = TransferFailure(sessionID: s.id, folder: s.cwd, profile: targetID)
            return
        }
        openTransfers.append(transfer)
        try? ProfileTransfer.save(openTransfers)
        await absorb(await index.beginTransfer(transfer))
        guard let host = resume(sessionID) else {
            await abandon(transfer)
            return
        }
        transferHosts[host.id] = (transfer, host.state.completedTurns)
        checkTransfer(host)
    }

    /// Apre una sessione nuova nella cartella, con il profilo scelto: il ripiego di un trasferimento non riuscito.
    func startFresh(folder: String, profile: UUID) {
        guard let p = profiles.profile(profile) else { return }
        transferFailure = nil
        launch(LaunchOptions(folder: folder, agent: p.agent, profileID: p.id))
    }

    private func checkTransfer(_ host: HostedSession) {
        guard let pending = transferHosts[host.id] else { return }
        let state = host.state
        if state.completedTurns > pending.baseline {
            Task { await finishTransfer(host.id, confirmed: true) }
        } else if !host.isRunning || (state.lastError != nil && state.status != .working && state.status != .waiting) {
            // Errore prima della prima risposta (login, limite, processo uscito) o chat chiusa.
            let failed = state.lastError != nil
            Task {
                await host.stop()
                await finishTransfer(host.id, confirmed: false, failed: failed)
            }
        }
    }

    private func finishTransfer(_ hostID: UUID, confirmed: Bool, failed: Bool = false) async {
        guard let (transfer, _) = transferHosts.removeValue(forKey: hostID) else { return }
        if confirmed {
            try? ProfileTransfer.confirm(transfer)
            openTransfers.removeAll { $0 == transfer }
            try? ProfileTransfer.save(openTransfers)
            await absorb(await index.endTransfer(transfer, confirmed: true))
            return
        }
        // La chat ferma resterebbe sul profilo di destinazione: «Riprendi» ripartirebbe da lì.
        hostedSessions.removeAll { $0.id == hostID && !$0.isRunning }
        syncHosted()
        await abandon(transfer)
        if failed, let target = profiles.profile(transfer.to) {
            transferFailure = TransferFailure(sessionID: transfer.sessionID, folder: session(transfer.sessionID)?.cwd ?? "",
                                              profile: target.id)
        }
    }

    private func abandon(_ transfer: PendingTransfer) async {
        ProfileTransfer.rollback(transfer)
        openTransfers.removeAll { $0 == transfer }
        try? ProfileTransfer.save(openTransfers)
        await absorb(await index.endTransfer(transfer, confirmed: false))
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
        hookDuplicates.forget(requestID: request.id)
        store.clearPending(requestID: request.id)
        publish()
    }

    /// Le card di permesso si possono rispondere da qui: sempre per le sessioni lanciate da Belvedere,
    /// per quelle del terminale solo se non si è scelto «Solo osservare».
    func answersHere(_ sessionID: String) -> Bool {
        policy != .observeOnly || host(for: sessionID) != nil
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
        var options = options
        // Senza profilo (o con uno sparito) la sessione parte con il profilo attivo della CLI.
        if profiles.profile(options.profileID)?.agent != options.agent { options.profileID = profiles.active(options.agent).id }
        let host = HostedSession(options: options, profile: profiles.profile(options.profileID), history: history)
        host.onChange = { [weak self, weak host] in
            guard let self, let host else { return }
            self.hostChanged(host)
        }
        host.resumeBlocker = { [weak self, weak host] in
            guard let self, let host else { return nil }
            let folder = host.state.cwd ?? host.options.folder
            guard self.agentFolders(host.agent).contains(RunningProcesses.canonical(folder)) else { return nil }
            return "\(host.agent.productName) è già aperto in questa cartella, ad esempio in un terminale: chiudilo per continuare qui."
        }
        hostedSessions.append(host)
        host.start()
        route = .session(host.state.sessionID ?? Self.provisionalPrefix + host.id.uuidString)
        return host
    }

    /// Riprende in Belvedere una sessione vista nei log, con la sua conversazione.
    @discardableResult
    func resume(_ sessionID: String) -> HostedSession? {
        guard let s = session(sessionID) else { return nil }
        if let existing = host(for: sessionID) {
            existing.restart()
            route = .session(sessionID)
            return existing
        }
        let history = (try? TranscriptMessages.load(path: s.transcriptPath, agent: s.agent)) ?? []
        var options = LaunchOptions.resuming(s)
        // Il log riporta la finestra dichiarata dall'agente; per un modello locale vale quella caricata in LM Studio.
        if let local = options.local, let loaded = lmStudio?.models.first(where: { $0.id == local.id && $0.loaded }) {
            options.local = LocalModelChoice(id: local.id, contextLength: loaded.contextLength ?? local.contextLength)
        }
        return launch(options, history: history)
    }

    /// «Riprendi in Belvedere» solo se la sessione non è viva altrove: mai due processi sulla stessa sessione.
    func canResumeHere(_ s: SessionSnapshot) -> Bool {
        guard !s.cwd.isEmpty, !isHosted(s.id) else { return false }
        // Se nessun `claude` (o `codex`) di altri lavora in quella cartella, la sessione non è viva altrove:
        // vale anche dopo un crash (log fermo su «al lavoro») e per le sessioni nate prima di Belvedere.
        guard let busy = busyFolders?[s.agent], !busy.contains(RunningProcesses.canonical(s.cwd)) else { return false }
        // Passata al terminale: finché quel processo vive, anche prima dei suoi hook, la sessione è sua.
        return !terminalOwned.contains(s.id)
    }

    /// Cartelle dei `claude` o `codex` vivi, esclusi quelli lanciati da Belvedere.
    private func agentFolders(_ agent: AgentKind) -> Set<String> {
        RunningProcesses.folders(named: agent.rawValue, excluding: Set(hostedSessions.compactMap(\.pid)))
    }

    private func refreshBusyFolders() {
        let folders = Dictionary(uniqueKeysWithValues: AgentKind.allCases.map { ($0, agentFolders($0)) })
        if folders != busyFolders { busyFolders = folders }
        let owned = Set(Self.handoffIDs().union(handedOff).filter { id in
            let pidFile = Self.handoffPID(id)
            // Appena passata il PID può non essere ancora scritto: intanto vale come occupata.
            if handedOff.contains(id), !FileManager.default.fileExists(atPath: pidFile.path) { return true }
            return TerminalHandoff.isRunning(pidFile: pidFile)
        })
        if owned != terminalOwned { terminalOwned = owned }
    }

    /// Le sessioni passate al terminale in questa esecuzione e quelle con un file PID rimasto da prima.
    private static func handoffIDs() -> Set<String> {
        let dir = Belvedere.supportDirectory.appendingPathComponent("handoff")
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return Set(files.filter { $0.hasSuffix(".pid") }.map { String($0.dropLast(4)) })
    }

    private static func handoffPID(_ id: String) -> URL {
        Belvedere.supportDirectory.appendingPathComponent("handoff/\(id).pid")
    }

    /// Una conversazione che sta passando a un altro profilo: finché non risponde, resta in Belvedere.
    func isTransferring(_ sessionID: String) -> Bool {
        openTransfers.contains { $0.sessionID == sessionID }
    }

    /// Ferma il processo di Belvedere e apre la sessione nel terminale con `claude --resume` o `codex resume`.
    func openInTerminal(_ sessionID: String) async {
        // Fermare la chat annullerebbe il trasferimento e cancellerebbe la copia che il terminale sta per riprendere.
        guard !isTransferring(sessionID) else { return }
        let host = host(for: sessionID)
        // Senza id (nessun messaggio ancora inviato) non c'è niente da riprendere nel terminale.
        guard let s = host?.state.snapshot(launchedAt: host?.launchedAt) ?? session(sessionID),
              let binary = host?.binary ?? HostedSession(options: LaunchOptions(folder: "/", agent: s.agent)).binary else { return }
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
        let script: String
        // Nel terminale con lo stesso account: la cartella del profilo, se non è il predefinito.
        let profile = profiles.profile(options.profileID) ?? self.profile(of: s)
        let account = profile.isDefault ? [:] : [profile.environmentKey: profile.configDir]
        if s.agent == .codex {
            script = TerminalHandoff.script(cwd: s.cwd, arguments: [binary] + CodexCommand.terminalArguments(options),
                                            pidFile: Self.handoffPID(s.id).path, environment: account)
        } else {
            let local = options.local == nil ? [:] : ClaudeCommand.environment(options, base: [:])
            script = TerminalHandoff.script(cwd: s.cwd, sessionID: s.id, binary: binary,
                                            pidFile: Self.handoffPID(s.id).path, environment: local.merging(account) { $1 })
        }
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

    /// «Belvedere» come origine quando i hook non l'hanno ancora detta: solo se la sessione è ospitata adesso
    /// o è ferma. Una sessione lanciata qui una volta e ora al lavoro altrove gira nel terminale.
    func launchedHere(_ s: SessionSnapshot) -> Bool {
        guard launchedIDs.contains(s.id) else { return false }
        return host(for: s.id) != nil || (s.status != .working && s.status != .waiting)
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
        // I limiti di Codex arrivano già dai file di sessione: qui solo quelli del piano Claude.
        if host.agent == .claude, let limits = host.state.limits, let profile = host.options.profileID,
           limits != store.claudeLimits[profile] {
            store.apply(claudeLimits: limits, profile: profile)
            saveLimits()
        }
        checkTransfer(host)
        syncHosted()
        saveKnownWindows()
    }

    private func saveKnownWindows() {
        guard store.knownWindows != savedWindows else { return }
        savedWindows = store.knownWindows
        UserDefaults.standard.set(savedWindows, forKey: Self.windowsKey)
    }

    private func syncHosted() {
        let live = hostedSessions.filter(\.isRunning)
        let exited = hostedSessions.filter { !$0.isRunning }
        store.setHosted(Set(live.compactMap(\.state.sessionID)), exited: Set(exited.compactMap(\.state.sessionID)))
        for host in hostedSessions {
            guard var snapshot = host.state.snapshot(launchedAt: host.launchedAt) else { continue }
            snapshot.profileID = host.options.profileID
            store.apply(hosted: snapshot)
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
                guard let decoded = try? HookEvent.decode(name: name, body: body) else { return (400, Data()) }
                // Il doppione (hook globale + di progetto) aspetta la stessa risposta ma non si registra due volte.
                guard let (event, isNew) = await self?.deduplicated(decoded) else { return (200, Data()) }
                if isNew {
                    let origin = event.callerPID.flatMap { OriginResolver.resolve(pid: $0) }
                    await self?.ingest(event, origin: origin)
                }
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

    private func deduplicated(_ event: HookEvent) -> (HookEvent, isNew: Bool) {
        guard let original = hookDuplicates.duplicate(of: event, now: Date()) else { return (event, true) }
        return (event.with(requestID: original), false)
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
        if payload.limits != nil { saveLimits() }
        saveKnownWindows()
        publish()
    }

    private func refresh(paths: [String]) async {
        await absorb(await index.refresh(paths: paths))
    }

    /// Le sessioni Codex aperte non arrivano da FSEvents: vedi `TranscriptIndex.pollCodex`.
    private func pollCodex() async {
        let update = await index.pollCodex(now: Date())
        guard !update.changed.isEmpty || !update.newBuckets.isEmpty else { return }
        await absorb(update)
    }

    private func absorb(_ update: IndexUpdate) async {
        store.apply(update)
        var codex: [UUID: PlanLimits] = [:]
        for p in profiles.profiles(.codex) { codex[p.id] = await index.latestCodexLimits(profile: p.id) }
        store.apply(codexLimits: codex)
        duplicateSessionCount = await index.duplicateCount
        if !update.newBuckets.isEmpty || buckets.isEmpty { buckets = await index.buckets }
        publish()
    }

    private func tick() {
        refreshBusyFolders()
        store.tick(now: Date())
        publish()
    }

    private func pollLMStudio() async {
        let status = await lmMonitor.poll()
        guard status != lmStudio else { return }
        lmStudio = status
        publish()
    }

    private func saveIndex() async {
        try? await index.save()
    }

    private func publish() {
        let next = LMStudioModel.applyLoadedContext(to: store.sessions, models: lmStudio?.models ?? [])
        if feedReady { addToFeed(ActivityFeed.events(from: allSessions, to: next, now: Date())) }
        if next != allSessions { allSessions = next }
        let visible = next.filter { !hidden.isHidden($0) }
        if visible != sessions { sessions = visible }
        let limits = store.planLimits(profile: profiles.active(.claude).id)
        if limits != planLimits { planLimits = limits }
        let codex = store.planLimits(profile: profiles.active(.codex).id)
        if codex != codexLimits { codexLimits = codex }
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

/// Una conversazione rimasta nel profilo di origine: si può aprire una sessione nuova nella sua cartella.
struct TransferFailure: Equatable {
    let sessionID: String
    let folder: String
    let profile: UUID
}

enum ProfileError: LocalizedError {
    case folderInUse

    var errorDescription: String? {
        switch self {
        case .folderInUse: "Questa cartella è già di un altro profilo."
        }
    }
}
