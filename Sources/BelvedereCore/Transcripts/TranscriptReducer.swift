import Foundation

/// Riduce le righe di una trascrizione JSONL allo stato della sessione.
public protocol TranscriptReducer: Codable, Sendable {
    mutating func consume(_ line: Data)
    /// Restituisce il consumo accumulato dall'ultima chiamata e lo azzera.
    mutating func drainUsage() -> [UsageBucket]
    var snapshot: SessionSnapshot { get }
}

enum TranscriptDate {
    private static let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let plain = Date.ISO8601FormatStyle()

    static func parse(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        return (try? fractional.parse(text)) ?? (try? plain.parse(text))
    }
}

/// Insieme limitato agli ultimi `capacity` elementi inseriti.
struct RecentSet: Codable, Sendable {
    private(set) var order: [String] = []
    private var members: Set<String> = []
    var capacity = 512

    init() {}

    // Su disco si salva solo l'ordine: l'insieme si ricostruisce.
    init(from decoder: Decoder) throws {
        order = try decoder.singleValueContainer().decode([String].self)
        members = Set(order)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(order)
    }

    /// Inserisce l'elemento; restituisce false se era già presente.
    mutating func insert(_ value: String) -> Bool {
        guard !members.contains(value) else { return false }
        members.insert(value)
        order.append(value)
        if order.count > capacity { members.remove(order.removeFirst()) }
        return true
    }
}
