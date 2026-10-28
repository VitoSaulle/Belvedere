import Foundation

/// Cartelle in cui Claude Code e Codex scrivono le trascrizioni.
public struct TranscriptRoots: Sendable {
    public let claude: URL
    public let codex: URL

    public init(claude: URL, codex: URL) {
        self.claude = claude
        self.codex = codex
    }

    public static let `default` = TranscriptRoots(
        claude: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects", isDirectory: true),
        codex: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions", isDirectory: true))
}

public struct IndexUpdate: Sendable {
    public let changed: [SessionSnapshot]
    public let newBuckets: [UsageBucket]
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
    }

    struct Cache: Codable {
        var version = 1
        var entries: [String: Entry]
        var buckets: [String: UsageBucket]
    }

    private let roots: TranscriptRoots
    private let cacheURL: URL
    private var entries: [String: Entry] = [:]
    private var bucketTable: [String: UsageBucket] = [:]

    public init(roots: TranscriptRoots, cacheURL: URL) {
        self.roots = roots
        self.cacheURL = cacheURL
        if let data = try? Data(contentsOf: cacheURL),
           let cache = try? JSONDecoder().decode(Cache.self, from: data), cache.version == 1 {
            entries = cache.entries
            bucketTable = cache.buckets
        }
    }

    /// Sessioni visibili (esclusi i subagenti), dalla più recente.
    public var sessions: [SessionSnapshot] {
        entries.values.filter { $0.parentSessionID == nil }.map(\.reducer.snapshot)
            .sorted { ($0.lastActivity ?? .distantPast) > ($1.lastActivity ?? .distantPast) }
    }

    public var buckets: [UsageBucket] { Array(bucketTable.values) }

    public var latestCodexLimits: PlanLimits? {
        entries.values.compactMap { entry -> PlanLimits? in
            if case .codex(let r) = entry.reducer { return r.planLimits }
            return nil
        }.max { $0.observedAt < $1.observedAt }
    }

    func offset(for path: String) -> UInt64? { entries[path]?.tailer.offset }

    public func refreshAll(progress: (@Sendable (Double) -> Void)?) async -> IndexUpdate {
        let found = discover()
        let foundPaths = Set(found.map(\.path))
        var changed: [SessionSnapshot] = []
        var newBuckets: [UsageBucket] = []
        for path in entries.keys where !foundPaths.contains(path) {
            if let ended = endSession(path) { changed.append(ended) }
        }
        for (i, file) in found.enumerated() {
            if let result = process(file) {
                if result.visible { changed.append(result.snapshot) }
                newBuckets += result.buckets
            }
            if i % 16 == 0 { await Task.yield() }
            progress?(Double(i + 1) / Double(found.count))
        }
        if found.isEmpty { progress?(1) }
        return IndexUpdate(changed: changed, newBuckets: newBuckets)
    }

    public func refresh(paths: [String]) async -> IndexUpdate {
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
                if result.visible { changed.append(result.snapshot) }
                newBuckets += result.buckets
            }
        }
        return IndexUpdate(changed: changed, newBuckets: newBuckets)
    }

    public func save() async throws {
        try FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(Cache(entries: entries, buckets: bucketTable))
        try data.write(to: cacheURL, options: .atomic)
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
        if let rel = Self.relative(path, to: roots.claude) {
            let parts = rel.split(separator: "/")
            if parts.count == 2 { return .claude(parent: nil) }
            if parts.count == 4, parts[2] == "subagents" { return .claude(parent: String(parts[1])) }
            return nil
        }
        if Self.relative(path, to: roots.codex) != nil, url.lastPathComponent.hasPrefix("rollout-") { return .codex }
        return nil
    }

    private static func relative(_ path: String, to root: URL) -> String? {
        for base in [root.standardizedFileURL.path, root.resolvingSymlinksInPath().path] {
            let prefix = base.hasSuffix("/") ? base : base + "/"
            if path.hasPrefix(prefix) { return String(path.dropFirst(prefix.count)) }
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
        for root in [roots.claude, roots.codex] {
            guard let walker = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let url as URL in walker {
                if let kind = classify(url), let file = stat(url, kind: kind) { found.append(file) }
            }
        }
        return found.sorted { $0.mtime > $1.mtime }
    }

    private func process(_ file: FoundFile) -> (snapshot: SessionSnapshot, buckets: [UsageBucket], visible: Bool)? {
        var entry: Entry
        if let existing = entries[file.path] {
            if existing.size == file.size && existing.mtime == file.mtime { return nil }
            entry = existing
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
        if let parent = entry.parentSessionID {
            buckets = buckets.map {
                UsageBucket(day: $0.day, sessionID: parent, agent: $0.agent, project: $0.project, model: $0.model,
                            isLocal: $0.isLocal, tokens: $0.tokens, toolCounts: $0.toolCounts)
            }
        }
        entry.size = file.size
        entry.mtime = file.mtime
        entries[file.path] = entry
        for bucket in buckets { merge(bucket) }
        return (entry.reducer.snapshot, buckets, entry.parentSessionID == nil)
    }

    private static func freshReducer(like reducer: AnyReducer, path: String) -> AnyReducer {
        switch reducer {
        case .claude: .claude(ClaudeReducer(transcriptPath: path))
        case .codex: .codex(CodexReducer(transcriptPath: path))
        }
    }

    private func merge(_ bucket: UsageBucket) {
        let key = [bucket.day, bucket.sessionID, bucket.agent.rawValue, bucket.model].joined(separator: "|")
        guard var existing = bucketTable[key] else { bucketTable[key] = bucket; return }
        existing.tokens += bucket.tokens
        existing.toolCounts.merge(bucket.toolCounts, uniquingKeysWith: +)
        bucketTable[key] = existing
    }

    /// Il file è sparito: la sessione esce dall'indice, il consumo resta nelle statistiche.
    private func endSession(_ path: String) -> SessionSnapshot? {
        guard let entry = entries.removeValue(forKey: path), entry.parentSessionID == nil else { return nil }
        var snapshot = entry.reducer.snapshot
        snapshot.status = .ended
        return snapshot
    }
}
