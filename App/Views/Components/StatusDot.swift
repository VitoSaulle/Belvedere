import BelvedereCore
import SwiftUI

/// Pallino di stato; pulsa quando la sessione lavora o aspetta.
struct StatusDot: View {
    let status: SessionStatus
    var size: CGFloat = 8

    var body: some View {
        let color = Theme.color(for: status)
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .background {
                if status == .working || status == .waiting {
                    // A 15 fps: un'animazione a frequenza piena per ogni scheda tiene occupata tutta la finestra.
                    TimelineView(.animation(minimumInterval: 1 / 15)) { context in
                        let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.4) / 1.4
                        let eased = 1 - (1 - phase) * (1 - phase)
                        Circle()
                            .fill(color.opacity(0.35))
                            .frame(width: size * 2, height: size * 2)
                            .scaleEffect(0.5 + 0.5 * eased)
                            .opacity(1 - eased)
                    }
                }
            }
            .accessibilityLabel(Theme.label(for: status))
    }
}

/// Etichetta piccola grigia (agente, origine, Cloud/Locale).
struct Tag: View {
    let text: String
    var tint: Color? = nil

    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(tint ?? .secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background((tint ?? Color.primary).opacity(tint == nil ? 0.06 : 0.12), in: .rect(cornerRadius: 6))
            .lineLimit(1)
    }
}

/// Barra orizzontale arrotondata con riempimento proporzionale.
struct MeterBar: View {
    let fraction: Double
    var color: Color = Theme.accent
    var height: CGFloat = 5

    var body: some View {
        Capsule()
            .fill(Color.primary.opacity(0.08))
            .overlay(alignment: .leading) {
                GeometryReader { geo in
                    Capsule().fill(color).frame(width: max(height, geo.size.width * min(1, max(0, fraction))))
                }
            }
            .frame(height: height)
    }
}

/// Riquadro con etichetta maiuscola, usato nell'inspector e nella sidebar.
struct Panel<Content: View>: View {
    let title: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                Text(title.uppercased())
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(.secondary)
            }
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.opacity(0.85), in: .rect(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.07)))
    }
}

/// Sfondo della finestra: tre aloni tenui come nella tavola A + C.
struct Backdrop: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let dark = scheme == .dark
        ZStack {
            (dark ? Color(hex: 0x15171C) : Color(hex: 0xF4F5F8))
            RadialGradient(colors: [Color(hex: dark ? 0x26314F : 0xC9D6F4), .clear],
                           center: UnitPoint(x: 0.12, y: 0.08), startRadius: 0, endRadius: 650)
            RadialGradient(colors: [Color(hex: dark ? 0x3A2C25 : 0xF4DCCB), .clear],
                           center: UnitPoint(x: 0.92, y: 0.18), startRadius: 0, endRadius: 600)
            RadialGradient(colors: [Color(hex: dark ? 0x1E332E : 0xCFE6DF), .clear],
                           center: UnitPoint(x: 0.6, y: 1.05), startRadius: 0, endRadius: 650)
        }
        .ignoresSafeArea()
    }
}
