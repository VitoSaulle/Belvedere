import BelvedereCore
import SwiftUI

struct SessionInspector: View {
    @Environment(AppModel.self) private var model
    let sessionID: String

    var body: some View {
        let host = model.host(for: sessionID)
        if let s = model.session(host?.state.sessionID ?? sessionID) ?? host?.state.snapshot(launchedAt: host?.launchedAt) {
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
                        row("Origine", s.origin?.appName ?? (model.launchedHere(s) ? "Belvedere" : "sconosciuta"))
                        if let model = s.model { row("Modello", ModelInfo.displayName(model)) }
                    }

                    if let host, !host.state.mcpServers.isEmpty || host.state.permissionMode != nil {
                        Panel(title: "Server MCP") {
                            if host.state.mcpServers.isEmpty {
                                Text("Nessuno").font(.system(size: 12)).foregroundStyle(.secondary)
                            }
                            ForEach(host.state.mcpServers, id: \.name) { server in
                                HStack(spacing: 8) {
                                    Circle().fill(Self.color(server.status)).frame(width: 7, height: 7)
                                    Text(server.name).font(.system(size: 12.5)).lineLimit(1)
                                    Spacer()
                                    Text(Self.label(server.status)).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1).fixedSize()
                                }
                            }
                            if let mode = host.state.permissionMode {
                                Divider().opacity(0.4)
                                row("Permessi", Self.modeLabel(mode, skip: host.options.permission == .skip))
                            }
                        }
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

    static func color(_ status: String) -> Color {
        switch status {
        case "connected": Theme.done
        case "failed": Theme.danger
        case "pending": Theme.waiting
        default: Theme.idle
        }
    }

    static func label(_ status: String) -> String {
        switch status {
        case "connected": "connesso"
        case "failed": "errore"
        case "pending": "in avvio"
        case "needs-auth": "da autorizzare"
        case "disabled": "spento"
        default: status
        }
    }

    static func modeLabel(_ mode: String, skip: Bool) -> String {
        if skip { return PermissionChoice.skip.label }
        switch mode {
        case "default": return PermissionChoice.ask.label
        case "acceptEdits": return PermissionChoice.acceptEdits.label
        case "auto": return PermissionChoice.auto.label
        case "plan": return PermissionChoice.plan.label
        default: return mode
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
