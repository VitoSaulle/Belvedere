import BelvedereCore
import SwiftUI

struct SessionCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var scheme
    let session: SessionSnapshot
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            status
            if let fraction = session.contextFraction {
                HStack(spacing: 10) {
                    MeterBar(fraction: fraction, color: Theme.contextColor(fraction), height: 4)
                    Text("ctx \(Fmt.percent(fraction))")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .fixedSize()
                }
            }
            footer
            if let pending = session.pending {
                PendingBox(session: session, pending: pending)
            }
        }
        .padding(14)
        .background(cardFill, in: .rect(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(border, lineWidth: session.status == .waiting ? 1.5 : 1))
        .shadow(color: .black.opacity(hovering ? 0.12 : 0.06), radius: hovering ? 18 : 12, y: hovering ? 8 : 4)
        .offset(y: hovering ? -2 : 0)
        .animation(.smooth(duration: 0.18), value: hovering)
        .onHover { hovering = $0 }
        .contentShape(.rect(cornerRadius: 18))
        .onTapGesture { model.route = .session(session.id) }
        .contextMenu {
            Button("Apri") { model.route = .session(session.id) }
            if model.canResumeHere(session) {
                Button("Riprendi in Belvedere") { model.resume(session.id) }
            }
            if session.origin != nil {
                Button("Vai a \(session.origin!.appName)") { model.activateOrigin(of: session.id) }
            }
            Button("Mostra la cartella nel Finder") {
                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: session.cwd)
            }
            .disabled(session.cwd.isEmpty)
        }
    }

    private var cardFill: Color {
        scheme == .dark ? Color(hex: 0x23252B, opacity: 0.92) : Color.white.opacity(0.88)
    }

    private var border: Color {
        session.status == .waiting ? Theme.waiting.opacity(0.55) : Color.primary.opacity(0.07)
    }

    private var header: some View {
        HStack(spacing: 9) {
            AgentBadge(agent: session.agent)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.displayName)
                    .font(.system(size: 13.5, weight: .semibold))
                    .lineLimit(1)
                HStack(spacing: 5) {
                    if let model = session.model {
                        Text(ModelInfo.displayName(model))
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Tag(text: session.isLocalModel ? "Locale" : "Cloud",
                        tint: session.isLocalModel ? Theme.local : nil)
                }
            }
            Spacer(minLength: 6)
            if model.host(for: session.id)?.options.permission == .skip {
                Tag(text: "Permessi saltati", tint: Theme.danger)
            }
            if let origin = session.origin {
                Tag(text: origin.appName)
            } else if model.launchedHere(session) {
                Tag(text: "Belvedere")
            }
        }
    }

    private var status: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                StatusDot(status: session.status, size: 7)
                Text(Theme.label(for: session.status))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.color(for: session.status))
            }
            Text(session.lastText ?? Fmt.folder(session.cwd))
                .font(.system(size: 12.5))
                .foregroundStyle(.primary.opacity(0.75))
                .lineLimit(2, reservesSpace: true)
        }
    }

    private var footer: some View {
        HStack {
            Text("\(Fmt.tokens(session.tokens.total)) tok")
            if let cost = session.costUSD, cost > 0 {
                Text("·")
                Text(Fmt.usd(cost))
            }
            Spacer()
            Text(timeLabel)
        }
        .font(.system(size: 11.5))
        .foregroundStyle(.secondary)
        .monospacedDigit()
    }

    private var timeLabel: String {
        if session.status == .working || session.status == .waiting, let start = session.startedAt {
            return Fmt.duration(Date().timeIntervalSince(start))
        }
        return Fmt.ago(session.lastActivity)
    }
}

struct AgentBadge: View {
    let agent: AgentKind
    var size: CGFloat = 28

    var body: some View {
        let ink = agent == .claude ? Theme.claudeInk : Theme.codex
        Text(agent == .claude ? "C" : "X")
            .font(.system(size: size * 0.43, weight: .bold, design: .rounded))
            .foregroundStyle(ink)
            .frame(width: size, height: size)
            .background(Theme.agentColor(agent).opacity(0.16), in: .rect(cornerRadius: size * 0.32))
            .accessibilityLabel(Theme.agentName(agent))
    }
}

/// Richiesta in sospeso sulla scheda: comando e pulsanti Nega / Consenti.
struct PendingBox: View {
    @Environment(AppModel.self) private var model
    let session: SessionSnapshot
    let pending: PendingRequest

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(pending.kind == .permission ? "Vuole usare \(pending.toolName ?? "uno strumento")" : "Ha una domanda")
                .font(.system(size: 12, weight: .semibold))
            if !pending.summary.isEmpty {
                Text(pending.summary)
                    .font(.system(size: 11.5, design: .monospaced))
                    .lineLimit(3)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.05), in: .rect(cornerRadius: 8))
            }
            HStack(spacing: 8) {
                Spacer()
                if pending.kind == .permission && model.answersHere(session.id) {
                    Button("Nega") { model.respond(to: pending, with: .deny(reason: "Negato da Belvedere")) }
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                    Button("Consenti") { model.respond(to: pending, with: .allow) }
                        .buttonStyle(.borderedProminent)
                        .buttonBorderShape(.capsule)
                        .tint(Color.primary)
                } else if model.host(for: session.id) != nil {
                    Button("Rispondi") { model.route = .session(session.id) }
                        .buttonStyle(.borderedProminent)
                        .buttonBorderShape(.capsule)
                        .tint(Color.primary)
                } else {
                    Button("Vai al terminale") { model.activateOrigin(of: session.id) }
                        .buttonStyle(.borderedProminent)
                        .buttonBorderShape(.capsule)
                        .tint(Color.primary)
                        .disabled(session.origin == nil)
                }
            }
            .controlSize(.small)
        }
        .padding(10)
        .background(Theme.waiting.opacity(0.08), in: .rect(cornerRadius: 12))
    }
}
