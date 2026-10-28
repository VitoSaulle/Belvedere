import BelvedereCore
import SwiftUI

struct SessionView: View {
    @Environment(AppModel.self) private var model
    let sessionID: String

    var body: some View {
        if let session = model.session(sessionID) {
            VStack(spacing: 0) {
                SessionHeader(session: session)
                Divider().opacity(0.4)
                TranscriptList(session: session)
                ReadOnlyBar(session: session)
            }
        } else {
            ContentUnavailableView("Sessione non trovata", systemImage: "questionmark.circle",
                                   description: Text("Il suo log non esiste più."))
        }
    }
}

struct SessionHeader: View {
    @Environment(AppModel.self) private var model
    let session: SessionSnapshot

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
            Tag(text: session.isLocalModel ? "Locale" : "Cloud", tint: session.isLocalModel ? Theme.local : nil)
        }
        .padding(.horizontal, 16)
        .frame(height: 56)
    }
}

/// Barra in basso al posto del campo di testo: in questa fase la sessione si osserva soltanto.
struct ReadOnlyBar: View {
    @Environment(AppModel.self) private var model
    let session: SessionSnapshot

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "eye").foregroundStyle(.secondary)
            Text("Sola lettura in questa fase").foregroundStyle(.secondary)
            Spacer()
            if let fraction = session.contextFraction {
                Text("ctx \(Fmt.percent(fraction))").foregroundStyle(.secondary).monospacedDigit()
            }
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
        .font(.system(size: 12.5))
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: .capsule)
        .padding(.horizontal, 24)
        .padding(.bottom, 14)
        .frame(maxWidth: 760)
    }
}
