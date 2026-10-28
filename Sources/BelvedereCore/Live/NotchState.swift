import Foundation

/// Cosa mostra il notch.
public enum NotchState: Equatable, Sendable {
    case hidden
    case resting(active: Int)
    case working(sessionID: String, project: String, since: Date)
    case needsYou(sessionID: String, request: PendingRequest)
    case finished(sessionID: String, project: String, summary: String, at: Date)
}

public enum NotchStateMachine {
    /// Per quanto resta visibile l'avviso «completata».
    public static let finishedDuration: TimeInterval = 6

    /// Priorità: richiesta in attesa > completata da poco > al lavoro > riposo > nascosto.
    public static func next(sessions: [SessionSnapshot], previous: NotchState, now: Date) -> NotchState {
        if let (session, request) = sessions.compactMap({ s in s.pending.map { (s, $0) } })
            .min(by: { $0.1.receivedAt < $1.1.receivedAt }) {
            return .needsYou(sessionID: session.id, request: request)
        }
        if case .finished(_, _, _, let at) = previous, now.timeIntervalSince(at) < finishedDuration {
            return previous
        }
        if let done = sessions.filter({ $0.status == .done })
            .filter({ now.timeIntervalSince($0.lastActivity ?? .distantPast) < finishedDuration })
            .max(by: { ($0.lastActivity ?? .distantPast) < ($1.lastActivity ?? .distantPast) }) {
            return .finished(sessionID: done.id, project: project(done), summary: done.lastText ?? "",
                             at: done.lastActivity ?? now)
        }
        if let working = sessions.filter({ $0.status == .working })
            .max(by: { ($0.lastActivity ?? .distantPast) < ($1.lastActivity ?? .distantPast) }) {
            return .working(sessionID: working.id, project: project(working),
                            since: working.startedAt ?? working.lastActivity ?? now)
        }
        let active = sessions.filter { [.working, .waiting, .done].contains($0.status) }.count
        return active > 0 ? .resting(active: active) : .hidden
    }

    private static func project(_ s: SessionSnapshot) -> String {
        let folder = (s.cwd as NSString).lastPathComponent
        return folder.isEmpty ? s.displayName : folder
    }
}
