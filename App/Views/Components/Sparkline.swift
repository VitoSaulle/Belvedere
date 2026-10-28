import SwiftUI

/// Piccolo grafico a barre, senza assi: l'andamento a colpo d'occhio.
struct Sparkline: View {
    let values: [Double]
    var color: Color = Theme.accent
    var highlightLast = true

    var body: some View {
        GeometryReader { geo in
            let peak = max(values.max() ?? 0, 1)
            let gap: CGFloat = 2
            let width = values.isEmpty ? 0 : (geo.size.width - gap * CGFloat(values.count - 1)) / CGFloat(values.count)
            HStack(alignment: .bottom, spacing: gap) {
                ForEach(values.indices, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(color.opacity(highlightLast && i == values.count - 1 ? 1 : 0.45))
                        .frame(width: max(1, width), height: max(2, geo.size.height * values[i] / peak))
                }
            }
            .frame(maxHeight: .infinity, alignment: .bottom)
        }
        .accessibilityHidden(true)
    }
}
