import Foundation

/// Consumo aggregato di una sessione in un giorno, per un modello.
public struct UsageBucket: Codable, Equatable, Sendable {
    public let day: String
    public let sessionID: String
    public let agent: AgentKind
    public let project: String
    public let model: String
    public let isLocal: Bool
    public var tokens: TokenTotals
    public var toolCounts: [String: Int]

    public init(day: String, sessionID: String, agent: AgentKind, project: String, model: String,
                isLocal: Bool, tokens: TokenTotals = .zero, toolCounts: [String: Int] = [:]) {
        self.day = day
        self.sessionID = sessionID
        self.agent = agent
        self.project = project
        self.model = model
        self.isLocal = isLocal
        self.tokens = tokens
        self.toolCounts = toolCounts
    }

    /// Giorno nel fuso locale, formato yyyy-MM-dd.
    public static func dayString(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}
