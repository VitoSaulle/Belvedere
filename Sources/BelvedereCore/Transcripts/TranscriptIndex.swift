import Foundation

/// Cartella in cui una CLI scrive le trascrizioni di un profilo.
public struct TranscriptRoot: Sendable, Equatable {
    public let profileID: UUID
    public let agent: AgentKind
    public let url: URL

    public init(profileID: UUID, agent: AgentKind, url: URL) {
        self.profileID = profileID
        self.agent = agent
        self.url = url
    }
}

/// Le cartelle delle trascrizioni di tutti i profili.
public struct TranscriptRoots: Sendable, Equatable {
    public let roots: [TranscriptRoot]

    public init(_ roots: [TranscriptRoot]) {
        self.roots = roots
    }

    public static func from(_ set: ProfileSet) -> TranscriptRoots {
        TranscriptRoots(set.profiles.map { TranscriptRoot(profileID: $0.id, agent: $0.agent, url: $0.transcriptRoot) })
    }

    public static var `default`: TranscriptRoots { from(.initial(home: Belvedere.home)) }

    public var urls: [URL] { roots.map(\.url) }

    /// La radice che contiene il percorso, anche se la cartella del profilo è un link.
    public func root(containing path: String) -> TranscriptRoot? {
        let standard = URL(fileURLWithPath: path).standardizedFileURL.path
        return roots.first { Self.relative(standard, to: $0.url) != nil }
    }

    static func relative(_ path: String, to root: URL) -> String? {
        for base in [root.standardizedFileURL.path, root.resolvingSymlinksInPath().path] {
            let prefix = base.hasSuffix("/") ? base : base + "/"
            if path.hasPrefix(prefix) { return String(path.dropFirst(prefix.count)) }
        }
        return nil
    }
}

public struct IndexUpdate: Sendable {
    public let changed: [SessionSnapshot]
    public let newBuckets: [UsageBucket]

    public init(changed: [SessionSnapshot], newBuckets: [UsageBucket]) {
        self.changed = changed
        self.newBuckets = newBuckets
    }
}

/// Indice incrementale di tutte le trascrizioni, con cache su disco.
public actor TranscriptIndex {
    enum AnyReducer: Codable, Sendable {
        case claude(ClaudeReducer)
        case codex(CodexReducer)

        var snapshot: SessionSnapshot {
            switch self {
            case .claude(let r): r.snapshot
            case .codex(let r): r.snapshot
            }
        }

        mutating func consume(_ lines: [Data]) -> [UsageBucket] {
            switch self {
            case .claude(var r):
                for line in lines { r.consume(line) }
                defer { self = .claude(r) }
                return r.drainUsage()
            case .codex(var r):
                for line in lines { r.consume(line) }
                defer { self = .codex(r) }
                return r.drainUsage()
            }
        }
    }

    struct Entry: Codable, Sendable {
        var tailer: LineTailer
        var size: UInt64
        var mtime: Date
        var reducer: AnyReducer
        /// Per le trascrizioni dei subagenti: la sessione madre a cui imputare il consumo.
        var parentSessionID: String?
        /// Il file è sparito: l'entrata resta un giorno, così se ricompare (riscrittura atomica, spostamento)
        /// riprende da dove era invece di ricontare tutto.
        var goneAt: Date?
    }

    static let tombstoneLifetime: TimeInterval = 24 * 3600

    /// Da aumentare quando cambia il modo in cui i riduttori leggono i log: la cache vecchia si ricostruisce.
    static let cacheVersion = 8

    struct Cache: Codable {
        var version = TranscriptIndex.cacheVersion
        var entries: [String: Entry]
        var buckets: [String: UsageBucket]
    }

    private var roots: TranscriptRoots
    private let cacheURL: URL
    private var entries: [String: Entry] = [:]
    /// Origini di trasferimenti in corso: ignorate finché la conversazione non risponde nel nuovo profilo.
    private var ignored: Set<String> = []
    private var bucketTable: [String: UsageBucket] = [:]

    public init(roots: TranscriptRoots, cacheURL: URL) {
        self.roots = roots
        self.cacheURL = cacheURL
    }

    /// La cache (diversi MB) si legge al primo uso, dentro l'actor e non sul thread principale.
    private var loaded = false
    /// Cambiato dall'ultimo salvataggio: senza modifiche `save()` non riscrive il file.
    private var dirty = false

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        if let data = try? Data(contentsOf: cacheURL),
           let cache = try? JSONDecoder().decode(Cache.self, from: data), cache.version == Self.cacheVersion {
            entries = cache.entries
            bucketTable = cache.buckets
        }
    }

    /// Sessioni visibili (esclusi i subagenti), dalla più recente. Lo stesso id in più profili
    /// (cartella copiata a mano) compare una volta sola: vale il file modificato più di recente.
    public var sessions: [SessionSnapshot] {
        loadIfNeeded()
        return preferredPaths().compactMap { path in entries[path].map { output(path, $0) } }
            .sorted { ($0.lastActivity ?? .distantPast) > ($1.lastActivity ?? .distantPast) }
    }

    /// Id di sessione presenti in più di un file.
    public var duplicateCount: Int {
        loadIfNeeded()
        return Dictionary(grouping: liveTopLevel(), by: { $0.value.reducer.snapshot.id }).values.filter { $0.count > 1 }.count
    }

    private func liveTopLevel() -> [(key: String, value: Entry)] {
        entries.filter { $0.value.parentSessionID == nil && $0.value.goneAt == nil }.map { ($0.key, $0.value) }
    }

    /// Per ogni id, il percorso del file più recente.
    private func preferredPaths() -> [String] {
        Dictionary(grouping: liveTopLevel(), by: { $0.value.reducer.snapshot.id }).values.compactMap { group in
            group.max { a, b in a.value.mtime == b.value.mtime ? a.key > b.key : a.value.mtime < b.value.mtime }?.key
        }
    }

    private func isPreferred(_ path: String, id: String) -> Bool {
        let rivals = liveTopLevel().filter { $0.key != path && $0.value.reducer.snapshot.id == id }
        guard let mine = entries[path] else { return false }
        return rivals.allSatisfy { mine.mtime > $0.value.mtime || (mine.mtime == $0.value.mtime && path < $0.key) }
    }

    /// Lo snapshot con il profilo della radice che contiene il file.
    private func output(_ path: String, _ entry: Entry) -> SessionSnapshot {
        var snapshot = entry.reducer.snapshot
        snapshot.profileID = roots.root(containing: path)?.profileID
        return snapshot
    }

    public var buckets: [UsageBucket] {
        loadIfNeeded()
        return Array(bucketTable.values)
    }

    /// Gli ultimi limiti del piano Codex visti nei file di un profilo.
    public func latestCodexLimits(profile: UUID) -> PlanLimits? {
        loadIfNeeded()
        guard let root = roots.roots.first(where: { $0.profileID == profile && $0.agent == .codex }) else { return nil }
        return entries.compactMap { path, entry -> PlanLimits? in
            guard case .codex(let r) = entry.reducer, TranscriptRoots.relative(path, to: root.url) != nil else { return nil }
            return r.planLimits
        }.max { $0.observedAt < $1.observedAt }
    }

    /// Cambia i profili osservati: le sessioni delle radici tolte escono (il consumo resta),
    /// quelle delle radici nuove entrano.
    public func setRoots(_ newRoots: TranscriptRoots) async -> IndexUpdate {
        loadIfNeeded()
        roots = newRoots
        return await refreshAll(progress: nil)
    }

    func offset(for path: String) -> UInt64? {
        loadIfNeeded()
        return entries[path]?.tailer.offset
    }

    public func refreshAll(progress: (@Sendable (Double) -> Void)?) async -> IndexUpdate {
        loadIfNeeded()
        let found = discover()
        let foundPaths = Set(found.map(\.path))
        var changed: [SessionSnapshot] = []
        var newBuckets: [UsageBucket] = []
        for path in entries.keys where !foundPaths.contains(path) {
            if let ended = endSession(path) { changed.append(ended) }
        }
        let now = Date()
        let expired = entries.filter { $0.value.goneAt.map { now.timeIntervalSince($0) > Self.tombstoneLifetime } ?? false }
        for path in expired.keys { entries.removeValue(forKey: path) }
        var visible: [(path: String, snapshot: SessionSnapshot)] = []
        for (i, file) in found.enumerated() {
            if let result = process(file) {
                if result.visible { visible.append((file.path, result.snapshot)) }
                newBuckets += result.buckets
            }
            if i % 16 == 0 { await Task.yield() }
            progress?(Double(i + 1) / Double(found.count))
        }
        // Con lo stesso id in più profili esce solo la copia preferita, calcolata una volta per tutte.
        let preferred = Set(preferredPaths())
        changed += visible.filter { preferred.contains($0.path) }.map(\.snapshot)
        if found.isEmpty { progress?(1) }
        return IndexUpdate(changed: changed, newBuckets: newBuckets)
    }

    public func refresh(paths: [String]) async -> IndexUpdate {
        loadIfNeeded()
        var changed: [SessionSnapshot] = []
        var newBuckets: [UsageBucket] = []
        for path in Set(paths) {
            let url = URL(fileURLWithPath: path)
            guard let kind = classify(url) else { continue }
            guard let file = stat(url, kind: kind) else {
                if let ended = endSession(path) { changed.append(ended) }
                continue
            }
            if let result = process(file) {
                if result.visible, isPreferred(file.path, id: result.snapshot.id) { changed.append(result.snapshot) }
                newBuckets += result.buckets
            }
        }
        return IndexUpdate(changed: changed, newBuckets: newBuckets)
    }

    /// Codex tiene aperto il file di sessione e FSEvents non ne segnala le scritture finché non lo chiude:
    /// si ricontrollano i file di oggi e di ieri e quelli modificati nelle ultime 48 ore.
    /// I file invariati costano solo uno `stat`.
    public func pollCodex(now: Date, calendar: Calendar = .current) async -> IndexUpdate {
        loadIfNeeded()
        var paths: Set<String> = []
        for root in roots.roots where root.agent == .codex {
          for offset in [0, -1] {
            guard let date = calendar.date(byAdding: .day, value: offset, to: now) else { continue }
            let d = calendar.dateComponents([.year, .month, .day], from: date)
            let dir = root.url.appendingPathComponent(String(format: "%04d/%02d/%02d", d.year ?? 0, d.month ?? 0, d.day ?? 0))
            let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
            for name in names where name.hasPrefix("rollout-") && name.hasSuffix(".jsonl") {
                paths.insert(dir.appendingPathComponent(name).standardizedFileURL.path)
            }
          }
        }
        for (path, entry) in entries {
            if case .codex = entry.reducer, now.timeIntervalSince(entry.mtime) < 48 * 3600 { paths.insert(path) }
        }
        return await refresh(paths: Array(paths))
    }

    /// Elimina dal disco le trascrizioni delle sessioni, subagenti compresi, e le toglie dall'indice
    /// senza lasciare l'entrata in sospeso. Il consumo già contato resta nelle statistiche.
    /// Restituisce gli id delle sessioni i cui file non ci sono più.
    public func delete(sessionIDs ids: Set<String>) -> [String] {
        loadIfNeeded()
        var deleted: [String] = []
        let fm = FileManager.default
        for (path, entry) in entries where entry.parentSessionID == nil && ids.contains(entry.reducer.snapshot.id) {
            let url = URL(fileURLWithPath: path)
            guard classify(url) != nil else { continue }
            var targets = [url]
            if case .claude = entry.reducer {
                // Accanto a <id>.jsonl, Claude tiene la cartella <id>/ con subagenti e risultati degli strumenti.
                targets.append(url.deletingPathExtension())
            }
            for target in targets where fm.fileExists(atPath: target.path) {
                try? fm.removeItem(at: target)
            }
            guard !fm.fileExists(atPath: path) else { continue }
            let folder = url.deletingPathExtension().path + "/"
            for (other, e) in entries where other == path || (e.parentSessionID != nil && other.hasPrefix(folder)) {
                entries.removeValue(forKey: other)
            }
            dirty = true
            deleted.append(entry.reducer.snapshot.id)
        }
        return deleted
    }

    // MARK: - Trasferimenti

    /// La conversazione passa al profilo di destinazione: le voci (offset e riduttore) si spostano
    /// sui file copiati, così niente viene riletto o contato due volte, e l'origine si ignora.
    public func beginTransfer(_ t: PendingTransfer) -> IndexUpdate {
        loadIfNeeded()
        ignored.formUnion(t.sourcePaths)
        move(from: t.sourcePaths, to: t.copiedPaths)
        return update(for: t.copiedPaths[0])
    }

    /// Chiude il trasferimento. Confermato: le voci dell'origine non servono più. Annullato: tornano all'origine.
    public func endTransfer(_ t: PendingTransfer, confirmed: Bool) -> IndexUpdate {
        loadIfNeeded()
        ignored.subtract(t.sourcePaths)
        if confirmed {
            for path in Array(entries.keys) where Self.isUnder(path, any: t.sourcePaths) { entries.removeValue(forKey: path) }
            dirty = true
            return update(for: t.copiedPaths[0])
        }
        move(from: t.copiedPaths, to: t.sourcePaths)
        return update(for: t.sourcePaths[0])
    }

    private func move(from sources: [String], to targets: [String]) {
        for (src, dst) in zip(sources, targets) {
            for path in Array(entries.keys) where path == src || path.hasPrefix(src + "/") {
                guard let entry = entries.removeValue(forKey: path) else { continue }
                entries[dst + path.dropFirst(src.count)] = entry
            }
        }
        dirty = true
    }

    private func update(for path: String) -> IndexUpdate {
        guard let entry = entries[path] else { return IndexUpdate(changed: [], newBuckets: []) }
        return IndexUpdate(changed: [output(path, entry)], newBuckets: [])
    }

    private static func isUnder(_ path: String, any roots: [String]) -> Bool {
        roots.contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    public func save() async throws {
        guard dirty else { return }
        try FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(Cache(entries: entries, buckets: bucketTable))
        try data.write(to: cacheURL, options: .atomic)
        dirty = false
    }

    // MARK: - File

    enum Kind { case claude(parent: String?), codex }

    struct FoundFile {
        let path: String
        let url: URL
        let kind: Kind
        let size: UInt64
        let mtime: Date
    }

    /// Riconosce una trascrizione dal suo percorso relativo alla radice.
    private func classify(_ url: URL) -> Kind? {
        guard url.pathExtension == "jsonl" else { return nil }
        let path = url.standardizedFileURL.path
        if !ignored.isEmpty, Self.isUnder(path, any: Array(ignored)) { return nil }
        for root in roots.roots {
            guard let rel = TranscriptRoots.relative(path, to: root.url) else { continue }
            switch root.agent {
            case .claude:
                let parts = rel.split(separator: "/")
                if parts.count == 2 { return .claude(parent: nil) }
                if parts.count == 4, parts[2] == "subagents" { return .claude(parent: String(parts[1])) }
                return nil
            case .codex:
                return url.lastPathComponent.hasPrefix("rollout-") ? .codex : nil
            }
        }
        return nil
    }

    private func stat(_ url: URL, kind: Kind) -> FoundFile? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]),
              values.isRegularFile == true else { return nil }
        return FoundFile(path: url.standardizedFileURL.path, url: url, kind: kind,
                         size: UInt64(values.fileSize ?? 0), mtime: values.contentModificationDate ?? .distantPast)
    }

    /// Tutte le trascrizioni, dalla modificata più di recente.
    private func discover() -> [FoundFile] {
        var found: [FoundFile] = []
        for root in roots.urls {
            // L'enumeratore non entra in una radice che è un link (`~/.claude-lavoro` → altro disco).
            guard let walker = FileManager.default.enumerator(
                at: root.resolvingSymlinksInPath(), includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let url as URL in walker {
                if let kind = classify(url), let file = stat(url, kind: kind) { found.append(file) }
            }
        }
        return found.sorted { $0.mtime > $1.mtime }
    }

    private func process(_ file: FoundFile) -> (snapshot: SessionSnapshot, buckets: [UsageBucket], visible: Bool)? {
        var entry: Entry
        let isNew = entries[file.path] == nil
        if let existing = entries[file.path] {
            if existing.size == file.size && existing.mtime == file.mtime && existing.goneAt == nil { return nil }
            entry = existing
            entry.goneAt = nil
        } else {
            let reducer: AnyReducer
            var parent: String?
            switch file.kind {
            case .claude(let p):
                reducer = .claude(ClaudeReducer(transcriptPath: file.path))
                parent = p
            case .codex:
                reducer = .codex(CodexReducer(transcriptPath: file.path))
            }
            entry = Entry(tailer: LineTailer(), size: 0, mtime: .distantPast, reducer: reducer, parentSessionID: parent)
        }
        let before = entry.tailer.offset
        let lines = (try? entry.tailer.readNewLines(from: file.url)) ?? []
        if entry.tailer.offset < before {
            // File troncato o riscritto: si ricomincia da capo.
            entry.reducer = Self.freshReducer(like: entry.reducer, path: file.path)
        }
        var buckets = entry.reducer.consume(lines)
        // Copia di una conversazione già indicizzata in un altro profilo: il suo consumo è già contato.
        if isNew, isDuplicate(file.path, entry) { buckets = [] }
        if let parent = entry.parentSessionID {
            buckets = buckets.map {
                UsageBucket(day: $0.day, sessionID: parent, agent: $0.agent, project: $0.project, model: $0.model,
                            isLocal: $0.isLocal, tokens: $0.tokens, toolCounts: $0.toolCounts)
            }
        }
        entry.size = file.size
        entry.mtime = file.mtime
        entries[file.path] = entry
        dirty = true
        for bucket in buckets { merge(bucket) }
        return (output(file.path, entry), buckets, entry.parentSessionID == nil)
    }

    /// Un altro file vivo con la stessa sessione (o lo stesso subagente della stessa sessione).
    private func isDuplicate(_ path: String, _ entry: Entry) -> Bool {
        let name = (path as NSString).lastPathComponent
        return entries.contains { other, e in
            guard other != path, e.goneAt == nil, e.parentSessionID == entry.parentSessionID else { return false }
            if entry.parentSessionID != nil { return (other as NSString).lastPathComponent == name }
            return e.reducer.snapshot.id == entry.reducer.snapshot.id
        }
    }

    private static func freshReducer(like reducer: AnyReducer, path: String) -> AnyReducer {
        switch reducer {
        case .claude: .claude(ClaudeReducer(transcriptPath: path))
        case .codex: .codex(CodexReducer(transcriptPath: path))
        }
    }

    private func merge(_ bucket: UsageBucket) {
        let key = [bucket.day, bucket.sessionID, bucket.agent.rawValue, bucket.model].joined(separator: "|")
        dirty = true
        guard var existing = bucketTable[key] else { bucketTable[key] = bucket; return }
        existing.tokens += bucket.tokens
        existing.toolCounts.merge(bucket.toolCounts, uniquingKeysWith: +)
        bucketTable[key] = existing
    }

    /// Il file è sparito: la sessione esce dall'indice, il consumo resta nelle statistiche.
    private func endSession(_ path: String) -> SessionSnapshot? {
        guard var entry = entries[path], entry.goneAt == nil else { return nil }
        entry.goneAt = Date()
        entries[path] = entry
        dirty = true
        guard entry.parentSessionID == nil else { return nil }
        // Resta un'altra copia della stessa sessione (altro profilo): quella prende il posto di questa.
        let id = entry.reducer.snapshot.id
        if let other = liveTopLevel().filter({ $0.value.reducer.snapshot.id == id }).max(by: { $0.value.mtime < $1.value.mtime }) {
            return output(other.key, other.value)
        }
        var snapshot = output(path, entry)
        snapshot.status = .ended
        return snapshot
    }
}
