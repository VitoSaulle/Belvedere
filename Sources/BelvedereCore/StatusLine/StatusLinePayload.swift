import Foundation

/// Il JSON che Claude Code passa al comando della status line.
public struct StatusLinePayload: Sendable {
    public let sessionID: String
    public let modelDisplayName: String?
    public let cwd: String?
    public let contextUsedPercent: Double?
    public let contextWindowSize: Int?
    public let costUSD: Double?
    public let limits: PlanLimits?

    public enum DecodeError: Error { case notAnObject, missingSessionID }

    public static func decode(_ data: Data, now: Date) throws -> StatusLinePayload {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw DecodeError.notAnObject
        }
        guard let sessionID = obj["session_id"] as? String, !sessionID.isEmpty else {
            throw DecodeError.missingSessionID
        }
        let context = obj["context_window"] as? [String: Any] ?? [:]
        let rates = obj["rate_limits"] as? [String: Any] ?? [:]
        let fiveHour = window(rates["five_hour"])
        let weekly = window(rates["seven_day"])
        return StatusLinePayload(
            sessionID: sessionID,
            modelDisplayName: (obj["model"] as? [String: Any])?["display_name"] as? String,
            cwd: (obj["workspace"] as? [String: Any])?["current_dir"] as? String ?? obj["cwd"] as? String,
            contextUsedPercent: (context["used_percentage"] as? NSNumber)?.doubleValue,
            contextWindowSize: (context["context_window_size"] as? NSNumber)?.intValue,
            costUSD: ((obj["cost"] as? [String: Any])?["total_cost_usd"] as? NSNumber)?.doubleValue,
            limits: fiveHour == nil && weekly == nil ? nil : PlanLimits(fiveHour: fiveHour, weekly: weekly, observedAt: now))
    }

    private static func window(_ raw: Any?) -> LimitWindow? {
        guard let dict = raw as? [String: Any], let used = (dict["used_percentage"] as? NSNumber)?.doubleValue else { return nil }
        let resets = (dict["resets_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
        return LimitWindow(usedPercent: used, resetsAt: resets)
    }
}

/// La riga mostrata nel terminale quando l'utente non aveva una status line sua.
public enum StatusLineText {
    public static func render(_ p: StatusLinePayload) -> String {
        var parts: [String] = []
        if let model = p.modelDisplayName { parts.append(model) }
        if let ctx = p.contextUsedPercent { parts.append("ctx \(Int(ctx.rounded()))%") }
        if let five = p.limits?.fiveHour { parts.append("5h \(Int(five.usedPercent.rounded()))%") }
        return parts.isEmpty ? "Belvedere" : parts.joined(separator: " · ")
    }
}
