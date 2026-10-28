import Foundation

/// Una conversazione copiata in un altro profilo, in attesa della prima risposta riuscita.
public struct PendingTransfer: Codable, Equatable, Sendable {
    public let sessionID: String
    public let agent: AgentKind
    public let from: UUID
    public let to: UUID
    /// Percorsi assoluti nel profilo di origine: il `.jsonl` e, per Claude, la cartella `<id>/` se c'è.
    public let sourcePaths: [String]
    /// I percorsi corrispondenti nel profilo di destinazione, nello stesso ordine.
    public let copiedPaths: [String]

    public init(sessionID: String, agent: AgentKind, from: UUID, to: UUID, sourcePaths: [String], copiedPaths: [String]) {
        self.sessionID = sessionID
        self.agent = agent
        self.from = from
        self.to = to
        self.sourcePaths = sourcePaths
        self.copiedPaths = copiedPaths
    }
}

/// Sposta una conversazione da un profilo all'altro: copia, poi cancella l'origine solo a conferma.
/// Si appoggia al fatto che le CLI riprendono una conversazione leggendo il suo file dalla propria cartella.
public enum ProfileTransfer {
    public enum Failure: Error, Equatable {
        case outsideProfile, destinationExists
    }

    /// Lo stesso percorso relativo sotto la radice della destinazione.
    public static func destination(for transcriptPath: String, from: Profile, to: Profile) -> String? {
        let path = URL(fileURLWithPath: transcriptPath).standardizedFileURL.path
        guard let rel = TranscriptRoots.relative(path, to: from.transcriptRoot) else { return nil }
        return to.transcriptRoot.appendingPathComponent(rel).standardizedFileURL.path
    }

    public static func begin(transcriptPath: String, sessionID: String, agent: AgentKind, from: Profile, to: Profile,
                             fileManager fm: FileManager = .default) throws -> PendingTransfer {
        guard let target = destination(for: transcriptPath, from: from, to: to) else { throw Failure.outsideProfile }
        var sources = [URL(fileURLWithPath: transcriptPath).standardizedFileURL.path]
        var copies = [target]
        // Accanto a <id>.jsonl, Claude tiene la cartella <id>/ con subagenti e risultati degli strumenti.
        let sidecar = (sources[0] as NSString).deletingPathExtension
        if agent == .claude, fm.fileExists(atPath: sidecar) {
            sources.append(sidecar)
            copies.append((target as NSString).deletingPathExtension)
        }
        guard !copies.contains(where: fm.fileExists(atPath:)) else { throw Failure.destinationExists }
        var done: [String] = []
        do {
            for (src, dst) in zip(sources, copies) {
                try fm.createDirectory(at: URL(fileURLWithPath: dst).deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.copyItem(atPath: src, toPath: dst)
                done.append(dst)
            }
        } catch {
            for path in done { try? fm.removeItem(atPath: path) }
            throw error
        }
        return PendingTransfer(sessionID: sessionID, agent: agent, from: from.id, to: to.id,
                               sourcePaths: sources, copiedPaths: copies)
    }

    /// La conversazione ha risposto nel nuovo profilo: l'origine si cancella.
    public static func confirm(_ t: PendingTransfer, fileManager fm: FileManager = .default) throws {
        for path in t.sourcePaths where fm.fileExists(atPath: path) { try fm.removeItem(atPath: path) }
    }

    /// Fallito o abbandonato: via la copia, l'origine non è mai stata toccata.
    public static func rollback(_ t: PendingTransfer, fileManager fm: FileManager = .default) {
        for path in t.copiedPaths { try? fm.removeItem(atPath: path) }
    }

    public static var storageURL: URL { Belvedere.supportDirectory.appendingPathComponent("transfers.json") }

    public static func load(from url: URL = storageURL) -> [PendingTransfer] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([PendingTransfer].self, from: data)) ?? []
    }

    public static func save(_ transfers: [PendingTransfer], to url: URL = storageURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(transfers).write(to: url, options: .atomic)
    }
}
