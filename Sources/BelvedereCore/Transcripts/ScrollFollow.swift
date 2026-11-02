import Foundation

/// Quando la chat deve restare in fondo: finché chi legge ci sta. Si smette appena sale, si riprende
/// quando torna giù. La crescita del contenuto o un cambio di altezza della finestra non contano come salita.
public struct ScrollSpot: Equatable, Sendable {
    public var offset: Double
    public var viewport: Double
    public var content: Double

    public init(offset: Double, viewport: Double, content: Double) {
        self.offset = offset
        self.viewport = viewport
        self.content = content
    }

    public var isAtBottom: Bool { offset + viewport >= content - 40 }

    public static func following(_ following: Bool, from old: ScrollSpot, to new: ScrollSpot) -> Bool {
        if new.isAtBottom { return true }
        if new.offset < old.offset - 1, new.viewport == old.viewport { return false }
        return following
    }
}
