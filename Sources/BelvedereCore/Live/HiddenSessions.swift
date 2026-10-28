import Foundation

/// Sessioni che l'utente ha tolto dalla vista. Non si cancella nulla: i file di Claude e Codex
/// restano, e una sessione ricompare da sola se torna attiva dopo essere stata nascosta.
public struct HiddenSessions: Codable, Equatable, Sendable {
    public private(set) var hiddenAt: [String: Date] = [:]

    public init() {}

    public mutating func hide(_ id: String, at date: Date) {
        hiddenAt[id] = date
    }

    public mutating func unhide(_ id: String) {
        hiddenAt.removeValue(forKey: id)
    }

    public func isHidden(_ session: SessionSnapshot) -> Bool {
        guard let date = hiddenAt[session.id] else { return false }
        return (session.lastActivity ?? .distantPast) <= date
    }

    /// Sessioni ferme da più di `days` giorni: concluse, inattive o chiuse.
    public static func staleIDs(_ sessions: [SessionSnapshot], olderThanDays days: Int, now: Date) -> [String] {
        let limit = now.addingTimeInterval(-Double(days) * 86_400)
        return sessions.filter { s in
            [.done, .idle, .ended].contains(s.status) && (s.lastActivity ?? .distantPast) < limit
        }.map(\.id)
    }
}
