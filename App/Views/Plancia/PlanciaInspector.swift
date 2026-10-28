import BelvedereCore
import SwiftUI

struct PlanciaInspector: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let today = model.stats(range: .today, project: nil)
        let recent = model.stats(range: .days14, project: nil)
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Panel(title: "Oggi") {
                    Text("\(Fmt.tokens(today.totalTokens)) token")
                        .font(.system(size: 22, weight: .bold))
                        .monospacedDigit()
                    Text(costLine(today))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    ShareBar(summary: today)
                    Sparkline(values: recent.days.map { Double($0.total) })
                        .frame(height: 34)
                        .padding(.top, 2)
                    Text("Ultimi 14 giorni").font(.system(size: 10.5)).foregroundStyle(.tertiary)
                }

                Panel(title: model.codexLimits == nil ? "Limiti del piano" : "Limiti di Claude") {
                    LimitRow(title: "Finestra 5 h", window: model.planLimits?.fiveHour, color: Theme.accent)
                    LimitRow(title: "Settimana", window: model.planLimits?.weekly, color: .primary)
                    if model.planLimits == nil {
                        Text("Compaiono dopo la prima risposta di una sessione con la status line di Belvedere.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if let codex = model.codexLimits {
                    Panel(title: "Limiti di Codex") {
                        LimitRow(title: "Finestra 5 h", window: codex.fiveHour, color: Theme.codex)
                        LimitRow(title: "Settimana", window: codex.weekly, color: .primary)
                    }
                }

                Panel(title: "Attività") {
                    if model.feed.isEmpty {
                        Text("Nessun evento da quando Belvedere è aperto.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(model.feed.prefix(14)) { event in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(Fmt.clock(event.date))
                                    .font(.system(size: 11))
                                    .foregroundStyle(.tertiary)
                                    .monospacedDigit()
                                    .frame(width: 36, alignment: .leading)
                                Text(event.text)
                                    .font(.system(size: 12))
                                    .lineLimit(2)
                            }
                            .contentShape(.rect)
                            .onTapGesture { model.route = .session(event.sessionID) }
                        }
                    }
                }
            }
            .padding(16)
        }
    }

    private func costLine(_ s: StatsSummary) -> String {
        let cost = s.costUSD.map { "Stima API \(Fmt.usd($0))" } ?? "Stima API —"
        return "\(cost) · \(s.sessions) sessioni"
    }
}

/// Quota Claude / Codex / Locale con legenda.
struct ShareBar: View {
    let summary: StatsSummary

    var body: some View {
        let claude = summary.days.reduce(0) { $0 + $1.claude }
        let codex = summary.days.reduce(0) { $0 + $1.codex }
        let local = summary.days.reduce(0) { $0 + $1.local }
        let total = max(1, claude + codex + local)
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geo in
                HStack(spacing: 2) {
                    ForEach(Array(zip([claude, codex, local], [Theme.claude, Theme.codex, Theme.local])), id: \.1) { value, color in
                        if value > 0 {
                            Rectangle().fill(color).frame(width: max(3, geo.size.width * CGFloat(value) / CGFloat(total) - 2))
                        }
                    }
                }
                .clipShape(.capsule)
            }
            .frame(height: 6)
            .background(Color.primary.opacity(0.08), in: .capsule)
            HStack(spacing: 12) {
                legend("Claude", Theme.claude)
                legend("Codex", Theme.codex)
                legend("Locale", Theme.local)
            }
        }
    }

    private func legend(_ name: String, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(name).font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
}

struct LimitRow: View {
    let title: String
    let window: LimitWindow?
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title).font(.system(size: 12.5, weight: .medium))
                Spacer()
                Text(window.map { Fmt.percent($0.usedPercent / 100) } ?? "—")
                    .font(.system(size: 12.5, weight: .semibold))
                    .monospacedDigit()
            }
            MeterBar(fraction: (window?.usedPercent ?? 0) / 100, color: color)
            if let reset = Fmt.reset(window?.resetsAt) {
                Text(reset.prefix(1).uppercased() + reset.dropFirst())
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }
}
