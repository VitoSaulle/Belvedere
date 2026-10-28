import Foundation

/// Una finestra di limite del piano: percentuale usata e momento del reset.
public struct LimitWindow: Codable, Equatable, Sendable {
    public let usedPercent: Double
    public let resetsAt: Date?

    public init(usedPercent: Double, resetsAt: Date?) {
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
    }
}

/// Limiti del piano osservati (5 ore e settimanale).
public struct PlanLimits: Codable, Equatable, Sendable {
    public var fiveHour: LimitWindow?
    public var weekly: LimitWindow?
    public var observedAt: Date

    public init(fiveHour: LimitWindow?, weekly: LimitWindow?, observedAt: Date) {
        self.fiveHour = fiveHour
        self.weekly = weekly
        self.observedAt = observedAt
    }
}
