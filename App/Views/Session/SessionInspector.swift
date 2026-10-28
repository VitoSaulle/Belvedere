import BelvedereCore
import SwiftUI

struct SessionInspector: View {
    @Environment(AppModel.self) private var model
    let sessionID: String

    var body: some View {
        if let s = model.session(sessionID) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Panel(title: nil) {
                        HStack(spacing: 14) {
                            ContextRing(fraction: s.contextFraction)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Contesto").font(.system(size: 13, weight: .semibold))
                                Text(contextLabel(s))
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                                Text([s.origin?.appName, Fmt.ago(s.lastActivity)].compactMap { $0 }.joined(separator: " · "))
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    Panel(title: "Sessione") {
                        row("Stato", Theme.label(for: s.status))
                        row("Token", Fmt.tokens(s.tokens.total))
                        row("Input · output", "\(Fmt.tokens(s.tokens.input)) · \(Fmt.tokens(s.tokens.output))")
                        row("Cache letta", Fmt.tokens(s.tokens.cacheRead))
                        row("Costo stimato", s.costUSD.map(Fmt.usd) ?? "—")
                        row("Durata", duration(s))
                        row("Origine", s.origin?.appName ?? "sconosciuta")
                        if let model = s.model { row("Modello", ModelInfo.displayName(model)) }
                    }

                    if !s.toolCounts.isEmpty {
                        Panel(title: "Strumenti") {
                            ForEach(s.toolCounts.sorted { $0.value > $1.value }.prefix(6), id: \.key) { tool in
                                row(tool.key, "\(tool.value)")
                            }
                        }
                    }

                    Panel(title: "File modificati") {
                        if s.filesChanged.isEmpty {
                            Text("Nessuno").font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                        ForEach(s.filesChanged.suffix(12), id: \.path) { file in
                            HStack(spacing: 6) {
                                Text((file.path as NSString).lastPathComponent)
                                    .font(.system(size: 12, design: .monospaced))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .help(file.path)
                                Spacer()
                                Text("+\(file.added)").foregroundStyle(Theme.done)
                                Text("−\(file.removed)").foregroundStyle(Theme.danger)
                            }
                            .font(.system(size: 11.5, weight: .semibold))
                            .monospacedDigit()
                        }
                    }
                }
                .padding(16)
            }
        }
    }

    private func row(_ key: String, _ value: String) -> some View {
        HStack {
            Text(key).foregroundStyle(.secondary)
            Spacer()
            Text(value).fontWeight(.medium).monospacedDigit().lineLimit(1)
        }
        .font(.system(size: 12.5))
    }

    private func contextLabel(_ s: SessionSnapshot) -> String {
        guard let used = s.contextTokens, let window = s.contextWindow else { return "non noto" }
        return "\(Fmt.tokens(used)) di \(Fmt.tokens(window))"
    }

    private func duration(_ s: SessionSnapshot) -> String {
        guard let start = s.startedAt, let end = s.lastActivity else { return "—" }
        return Fmt.duration(end.timeIntervalSince(start))
    }
}

struct ContextRing: View {
    let fraction: Double?

    var body: some View {
        let value = fraction ?? 0
        ZStack {
            Circle().stroke(Color.primary.opacity(0.08), lineWidth: 6)
            Circle()
                .trim(from: 0, to: value)
                .stroke(Theme.contextColor(value), style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text(fraction.map(Fmt.percent) ?? "—")
                .font(.system(size: 13, weight: .bold))
                .monospacedDigit()
        }
        .frame(width: 58, height: 58)
        .animation(.smooth, value: value)
    }
}
