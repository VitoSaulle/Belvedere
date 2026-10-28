import AppKit
import BelvedereCore
import SwiftUI

/// Pannello della menu bar (tavola D).
struct MenuBarPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if ProfileMenu.isVisible(model) {
                HStack {
                    ProfileMenu()
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                    Spacer()
                }
            }
            limits
            let waiting = model.sessions.filter { $0.status == .waiting }
            if !waiting.isEmpty {
                section("Aspettano te")
                ForEach(waiting.prefix(3)) { session in
                    WaitingCard(session: session) { open(.session(session.id)) }
                        .contextMenu { SessionMenuItems(sessionID: session.id) }
                }
            }
            let live = model.sessions.filter { $0.status == .working || ($0.status == .done && isRecent($0)) }
            if !live.isEmpty {
                section("In corso")
                VStack(spacing: 2) {
                    ForEach(live.prefix(5)) { session in
                        Button { open(.session(session.id)) } label: { LiveRow(session: session) }
                            .buttonStyle(.plain)
                            .contextMenu { SessionMenuItems(sessionID: session.id) }
                    }
                }
            }
            if waiting.isEmpty && live.isEmpty {
                Text("Nessuna sessione attiva.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            }
            Divider().opacity(0.5)
            VStack(spacing: 2) {
                MenuAction(title: "Nuova sessione", shortcut: "⌘N", systemImage: "plus") {
                    model.showNewSession = true
                    open(nil)
                }
                MenuAction(title: "Apri Belvedere", shortcut: "⌥⌘B", systemImage: "macwindow") { open(nil) }
                MenuAction(title: "Statistiche", shortcut: nil, systemImage: "chart.bar.xaxis") { open(.stats) }
            }
            Divider().opacity(0.5)
            footer
        }
        .padding(14)
        .frame(width: 372)
    }

    private var limits: some View {
        HStack(spacing: 14) {
            LimitRing(title: "5 h", window: model.planLimits?.fiveHour, color: Theme.accent)
            LimitRing(title: "Settimana", window: model.planLimits?.weekly, color: .primary)
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 2) {
                Text(Date().formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).locale(Locale(identifier: "it_IT"))))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                Text(Fmt.clock(Date())).font(.system(size: 20, weight: .semibold)).monospacedDigit()
            }
        }
    }

    private var footer: some View {
        let today = model.stats(range: .today, project: nil)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle().fill(model.lmStudio?.reachable == true ? Theme.done : Theme.idle).frame(width: 6, height: 6)
                Text(lmStudioText).lineLimit(1)
            }
            Text("Oggi \(Fmt.tokens(today.totalTokens)) token · stima API \(today.costUSD.map(Fmt.usd) ?? "—")")
        }
        .font(.system(size: 11.5))
        .foregroundStyle(.secondary)
    }

    private var lmStudioText: String {
        guard let status = model.lmStudio, status.reachable else { return "LM Studio · non in esecuzione" }
        if let loaded = status.models.first(where: \.loaded) {
            let ctx = loaded.contextLength.map { " · \(Fmt.tokens($0))" } ?? ""
            return "LM Studio · \(loaded.id) caricato\(ctx)"
        }
        return "LM Studio · in linea, nessun modello caricato"
    }

    private func section(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(.secondary)
    }

    private func isRecent(_ s: SessionSnapshot) -> Bool {
        Date().timeIntervalSince(s.lastActivity ?? .distantPast) < 30 * 60
    }

    private func open(_ route: Route?) {
        if let route { model.route = route }
        openWindow(id: "main")
        NSApp.activate()
    }
}

struct LimitRing: View {
    let title: String
    let window: LimitWindow?
    let color: Color

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                Circle().stroke(Color.primary.opacity(0.1), lineWidth: 5)
                Circle()
                    .trim(from: 0, to: min(1, (window?.usedPercent ?? 0) / 100))
                    .stroke(color, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text(window.map { "\(Int($0.usedPercent.rounded()))" } ?? "—")
                    .font(.system(size: 12, weight: .bold))
                    .monospacedDigit()
            }
            .frame(width: 42, height: 42)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12.5, weight: .semibold))
                Text(window.flatMap { Fmt.resetShort($0.resetsAt) } ?? "—")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

struct WaitingCard: View {
    @Environment(AppModel.self) private var model
    let session: SessionSnapshot
    let openSession: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                StatusDot(status: .waiting, size: 7)
                Text(session.displayName).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                Spacer()
                Text(Fmt.ago(session.pending?.receivedAt ?? session.lastActivity))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            if let pending = session.pending {
                Text(pending.kind == .question ? (pending.summary.isEmpty ? "Ha una domanda" : pending.summary)
                                               : (pending.summary.isEmpty ? (pending.toolName ?? "Permesso") : pending.summary))
                    .font(.system(size: 11.5, design: pending.kind == .permission ? .monospaced : .default))
                    .lineLimit(2)
                    .padding(7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.05), in: .rect(cornerRadius: 7))
            }
            HStack(spacing: 6) {
                Spacer()
                if let pending = session.pending, pending.kind == .permission, model.answersHere(session.id) {
                    Button("Nega") { model.respond(to: pending, with: .deny(reason: "Negato da Belvedere")) }
                    Button("Apri", action: openSession)
                    Button("Consenti") { model.respond(to: pending, with: .allow) }
                        .buttonStyle(.borderedProminent)
                        .tint(Color.primary)
                } else if model.host(for: session.id) != nil {
                    Button("Rispondi", action: openSession)
                        .buttonStyle(.borderedProminent)
                        .tint(Color.primary)
                } else {
                    Button("Apri", action: openSession)
                    Button("Vai al terminale") { model.activateOrigin(of: session.id) }
                        .buttonStyle(.borderedProminent)
                        .tint(Color.primary)
                        .disabled(session.origin == nil)
                }
            }
            .buttonBorderShape(.capsule)
            .controlSize(.small)
        }
        .padding(10)
        .background(Theme.waiting.opacity(0.08), in: .rect(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.waiting.opacity(0.35)))
    }
}

struct LiveRow: View {
    let session: SessionSnapshot
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            StatusDot(status: session.status, size: 7)
            VStack(alignment: .leading, spacing: 1) {
                Text(session.displayName).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Text(Fmt.tokens(session.tokens.total))
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(hovering ? Color.primary.opacity(0.06) : .clear, in: .rect(cornerRadius: 8))
        .contentShape(.rect)
        .onHover { hovering = $0 }
    }

    private var subtitle: String {
        var parts = [Theme.label(for: session.status)]
        if let origin = session.origin { parts.append("da \(origin.appName)") }
        if let model = session.model { parts.append(session.isLocalModel ? "locale" : ModelInfo.displayName(model)) }
        return parts.joined(separator: " · ")
    }
}

struct MenuAction: View {
    let title: String
    let shortcut: String?
    let systemImage: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage).frame(width: 18).foregroundStyle(.secondary)
                Text(title)
                Spacer()
                if let shortcut { Text(shortcut).foregroundStyle(.secondary) }
            }
            .font(.system(size: 12.5))
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(hovering ? Color.primary.opacity(0.06) : .clear, in: .rect(cornerRadius: 8))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
