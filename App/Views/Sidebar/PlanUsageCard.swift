import BelvedereCore
import SwiftUI

/// Riquadro di vetro in fondo alla sidebar: limiti del piano e stato di LM Studio.
struct PlanUsageCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let five = model.planLimits?.fiveHour {
                HStack {
                    Text("Finestra 5 h").font(.system(size: 12, weight: .medium))
                    Spacer()
                    Text(Fmt.percent(five.usedPercent / 100)).font(.system(size: 12, weight: .semibold)).monospacedDigit()
                }
                MeterBar(fraction: five.usedPercent / 100, color: Theme.contextColor(five.usedPercent / 100))
                Text(detail(five))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Text("Limiti del piano").font(.system(size: 12, weight: .medium))
                Text(model.planLimits?.weekly.map { "Settimana \(Fmt.percent($0.usedPercent / 100))" } ?? "Non disponibili finché una sessione non risponde")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider().opacity(0.5)
            HStack(spacing: 6) {
                Circle()
                    .fill(model.lmStudio?.reachable == true ? Theme.done : Theme.idle)
                    .frame(width: 6, height: 6)
                Text(lmStudioText)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(12)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
    }

    private func detail(_ five: LimitWindow) -> String {
        var parts: [String] = []
        if let reset = Fmt.reset(five.resetsAt) { parts.append(reset.prefix(1).uppercased() + reset.dropFirst()) }
        if let week = model.planLimits?.weekly { parts.append("settimana \(Fmt.percent(week.usedPercent / 100))") }
        return parts.joined(separator: " · ")
    }

    private var lmStudioText: String {
        guard let status = model.lmStudio, status.reachable else { return "LM Studio · non in esecuzione" }
        let loaded = status.models.filter(\.loaded).count
        return loaded > 0 ? "LM Studio · in linea · \(loaded) caricati" : "LM Studio · in linea · \(status.models.count) modelli"
    }
}
