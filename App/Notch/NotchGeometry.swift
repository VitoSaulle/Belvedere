import AppKit

/// Dove si trova il notch (o, senza notch, dove mettere la pillola) sullo schermo principale.
struct NotchGeometry: Equatable {
    let screenFrame: NSRect
    let hasNotch: Bool
    /// Larghezza della tacca fisica; 0 senza notch.
    let notchWidth: CGFloat
    /// Altezza della barra (tacca o menu bar).
    let barHeight: CGFloat
    /// Bordo superiore utile per la finestra.
    let top: CGFloat

    /// Lo schermo con il notch se c'è (anche se non è il principale), altrimenti quello della menu bar.
    static func current(_ screen: NSScreen? = NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.screens.first) -> NotchGeometry? {
        guard let screen else { return nil }
        let frame = screen.frame
        let inset = screen.safeAreaInsets.top
        if inset > 0, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            return NotchGeometry(screenFrame: frame, hasNotch: true,
                                 notchWidth: frame.width - left.width - right.width,
                                 barHeight: inset, top: frame.maxY)
        }
        // Senza notch: pillola appena sotto la menu bar.
        return NotchGeometry(screenFrame: frame, hasNotch: false, notchWidth: 0,
                             barHeight: 32, top: screen.visibleFrame.maxY - 6)
    }
}
