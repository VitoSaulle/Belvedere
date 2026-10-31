import Foundation

/// Sessioni scelte a mano in Plancia, con le regole del Finder: ⌘ alterna, ⇧ estende dall'ultima scelta.
public struct SessionSelection: Equatable, Sendable {
    public private(set) var ids: Set<String> = []
    private var anchor: String?

    public init() {}

    public var isEmpty: Bool { ids.isEmpty }

    public mutating func toggle(_ id: String) {
        if ids.remove(id) == nil { ids.insert(id) }
        anchor = id
    }

    /// Dall'ultima scelta a `id`, nell'ordine in cui le sessioni si vedono.
    public mutating func extend(to id: String, in order: [String]) {
        guard let anchor, let from = order.firstIndex(of: anchor), let to = order.firstIndex(of: id) else {
            return toggle(id)
        }
        ids.formUnion(order[min(from, to)...max(from, to)])
    }

    /// Su cosa agisce il menu di `id`: tutta la selezione se ne fa parte, altrimenti solo lei.
    public func targets(for id: String) -> [String] {
        ids.contains(id) ? ids.sorted() : [id]
    }
}
