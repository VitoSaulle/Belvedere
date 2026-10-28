import AppKit
import SwiftUI

/// Icona della menu bar: glifo, numero di sessioni attive e punto ambra se qualcuna aspetta.
struct MenuBarLabel: View {
    let active: Int
    let waiting: Bool

    var body: some View {
        Image(nsImage: Self.image(active: active, waiting: waiting))
            .accessibilityLabel(waiting ? "Belvedere, una sessione ti aspetta" : "Belvedere, \(active) sessioni attive")
    }

    /// Disegnata al momento dell'uso, così segue l'aspetto chiaro o scuro della menu bar.
    static func image(active: Int, waiting: Bool) -> NSImage {
        let symbolConfig = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        let symbol = NSImage(systemSymbolName: "building.columns.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(symbolConfig) ?? NSImage()
        let text = active > 0 ? "\(active)" : ""
        let font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        let textWidth = text.isEmpty ? 0 : (text as NSString).size(withAttributes: [.font: font]).width + 4
        let size = NSSize(width: symbol.size.width + textWidth + 4, height: 18)

        let image = NSImage(size: size, flipped: false) { rect in
            let ink = NSColor.labelColor
            let symbolRect = NSRect(x: 1, y: (rect.height - symbol.size.height) / 2,
                                    width: symbol.size.width, height: symbol.size.height)
            let tinted = NSImage(size: symbol.size, flipped: false) { r in
                symbol.draw(in: r)
                ink.set()
                r.fill(using: .sourceAtop)
                return true
            }
            tinted.draw(in: symbolRect)
            if !text.isEmpty {
                let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: ink]
                let h = (text as NSString).size(withAttributes: attributes).height
                (text as NSString).draw(at: NSPoint(x: symbolRect.maxX + 3, y: (rect.height - h) / 2), withAttributes: attributes)
            }
            if waiting {
                NSColor(red: 0xE3 / 255, green: 0x9A / 255, blue: 0x2B / 255, alpha: 1).setFill()
                NSBezierPath(ovalIn: NSRect(x: symbolRect.maxX - 4, y: symbolRect.maxY - 5, width: 6, height: 6)).fill()
            }
            return true
        }
        image.isTemplate = false
        return image
    }
}
