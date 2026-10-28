import BelvedereCore
import SwiftUI

struct SessionView: View {
    @Environment(AppModel.self) private var model
    let sessionID: String

    var body: some View {
        let host = model.host(for: sessionID)
        if let host, let session = model.session(host.state.sessionID ?? sessionID) ?? placeholder(host) {
            VStack(spacing: 0) {
                SessionHeader(session: session, host: host)
                Divider().opacity(0.4)
                HostedTranscript(host: host)
                ProfileTransferBar(session: session)
                Composer(host: host, sessionID: session.id)
            }
        } else if let session = model.session(sessionID) {
            VStack(spacing: 0) {
                SessionHeader(session: session, host: nil)
                Divider().opacity(0.4)
                TranscriptList(session: session)
                ProfileTransferBar(session: session)
                ReadOnlyBar(session: session)
            }
        } else {
            ContentUnavailableView("Sessione non trovata", systemImage: "questionmark.circle",
                                   description: Text("Il suo log non esiste più."))
        }
    }
}

/// Sessione appena lanciata: Claude non ha ancora comunicato il suo id.
@MainActor private func placeholder(_ host: HostedSession) -> SessionSnapshot? {
    if let snapshot = host.state.snapshot(launchedAt: host.launchedAt) { return snapshot }
    var s = SessionSnapshot(id: AppModel.provisionalPrefix + host.id.uuidString, agent: host.agent, cwd: host.options.folder)
    s.status = host.isRunning ? .working : .idle
    s.model = host.options.local?.id ?? host.options.model
    s.isLocalModel = host.options.local != nil
    s.startedAt = host.launchedAt
    return s
}

struct SessionHeader: View {
    @Environment(AppModel.self) private var model
    let session: SessionSnapshot
    let host: HostedSession?

    var body: some View {
        HStack(spacing: 10) {
            Button {
                withAnimation(.smooth(duration: 0.3)) { model.route = .plancia }
            } label: {
                Image(systemName: "chevron.left").font(.system(size: 13, weight: .semibold))
                    .frame(width: 30, height: 30)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .circle)
            .help("Torna alla Plancia (⌘0)")

            AgentBadge(agent: session.agent, size: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(session.displayName).font(.system(size: 14.5, weight: .semibold)).lineLimit(1)
                Text(session.cwd.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 12)
            if let branch = session.gitBranch {
                Label(branch, systemImage: "arrow.triangle.branch")
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if let name = session.model {
                Text(ModelInfo.displayName(name)).font(.system(size: 12, weight: .medium))
            }
            if host?.options.permission == .skip {
                Tag(text: "Permessi saltati", tint: Theme.danger)
            }
            Tag(text: session.isLocalModel || host?.options.local != nil ? "Locale" : "Cloud",
                tint: session.isLocalModel || host?.options.local != nil ? Theme.local : nil)
        }
        .padding(.horizontal, 16)
        .frame(height: 56)
    }
}

/// Barra in basso per le sessioni che Belvedere osserva soltanto; se la sessione è ferma si può riprendere qui.
struct ReadOnlyBar: View {
    @Environment(AppModel.self) private var model
    let session: SessionSnapshot

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "eye").foregroundStyle(.secondary)
            Text(model.canResumeHere(session) ? "Sessione ferma" : "Solo osservazione").foregroundStyle(.secondary)
            Spacer()
            if model.canResumeHere(session) {
                Button {
                    model.resume(session.id)
                } label: {
                    Label("Riprendi in Belvedere", systemImage: "play.fill")
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .help(session.agent == .claude ? "Riprende la conversazione qui con claude --resume" : "Riprende il thread qui con codex app-server")
            }
            if let fraction = session.contextFraction {
                Text("ctx \(Fmt.percent(fraction))").foregroundStyle(.secondary).monospacedDigit()
            }
            // Una sessione partita da Belvedere non ha un'altra app a cui tornare.
            if session.origin?.appName != "Belvedere" {
                Button {
                    model.activateOrigin(of: session.id)
                } label: {
                    Label(session.origin.map { "Vai a \($0.appName)" } ?? "Vai al terminale", systemImage: "arrow.up.forward.app")
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .tint(Theme.accent)
                .disabled(session.origin == nil)
                .help(session.origin == nil ? "Origine sconosciuta: la sessione è partita prima di Belvedere" : "")
            }
        }
        .font(.system(size: 12.5))
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: .capsule)
        .padding(.horizontal, 24)
        .padding(.bottom, 14)
        .frame(maxWidth: 760)
    }
}

/// Passaggio a un altro profilo dalla chat: proposto quando la sessione si ferma per il limite del piano,
/// e la sessione nuova come ripiego se la conversazione non è passata.
struct ProfileTransferBar: View {
    @Environment(AppModel.self) private var model
    let session: SessionSnapshot

    var body: some View {
        if let failure = model.transferFailure, failure.sessionID == session.id,
           let target = model.profiles.profile(failure.profile) {
            bar(icon: "exclamationmark.triangle.fill", tint: Theme.danger,
                text: "Non sono riuscito a portare la conversazione in \(target.name).") {
                Button("Apri una sessione nuova in \(Fmt.folder(failure.folder))") {
                    model.startFresh(folder: failure.folder, profile: target.id)
                }
                .disabled(failure.folder.isEmpty)
                Button("Chiudi") { model.transferFailure = nil }
            }
        } else if model.hitPlanLimit(session), model.canContinueElsewhere(session), let best = model.bestTarget(session) {
            bar(icon: "gauge.with.dots.needle.100percent", tint: Theme.waiting,
                text: "Limite del piano raggiunto con \(model.profile(of: session).name).") {
                Button("Continua con \(best.name)") { Task { await model.continueIn(session.id, profile: best.id) } }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
            }
        }
    }

    private func bar(icon: String, tint: Color, text: String, @ViewBuilder actions: () -> some View) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(tint)
            Text(text).lineLimit(2)
            Spacer(minLength: 8)
            actions()
        }
        .font(.system(size: 12.5))
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: .capsule)
        .padding(.horizontal, 24)
        .padding(.bottom, 8)
        .frame(maxWidth: 760)
    }
}
