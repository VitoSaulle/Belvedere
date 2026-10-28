import Foundation

public struct ActivityEvent: Sendable, Identifiable, Equatable {
    public let id = UUID()
    public let date: Date
    public let sessionID: String
    public let text: String

    public init(date: Date, sessionID: String, text: String) {
        self.date = date
        self.sessionID = sessionID
        self.text = text
    }

    public static func == (lhs: ActivityEvent, rhs: ActivityEvent) -> Bool {
        lhs.date == rhs.date && lhs.sessionID == rhs.sessionID && lhs.text == rhs.text
    }
}

/// Ricava gli eventi del flusso attività dai cambi di stato tra due istantanee.
public enum ActivityFeed {
    public static let limit = 200

    public static func events(from old: [SessionSnapshot], to new: [SessionSnapshot], now: Date) -> [ActivityEvent] {
        let before = Dictionary(old.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return new.compactMap { s in
            let text: String
            if let previous = before[s.id] {
                guard previous.status != s.status || previous.pending?.id != s.pending?.id else { return nil }
                switch s.status {
                case .waiting:
                    guard let pending = s.pending else { text = "aspetta te"; break }
                    text = pending.kind == .permission ? "chiede il permesso: \(pending.toolName ?? pending.summary)"
                                                       : "ha una domanda"
                case .done: text = "completata"
                case .ended: text = "chiusa"
                default: return nil
                }
            } else {
                guard s.status != .ended else { return nil }
                text = "nuova sessione"
            }
            return ActivityEvent(date: now, sessionID: s.id, text: "\(s.displayName) · \(text)")
        }
    }
}
