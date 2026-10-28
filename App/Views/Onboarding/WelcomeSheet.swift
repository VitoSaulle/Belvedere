import BelvedereCore
import SwiftUI

/// Primo avvio: cosa fa il collegamento e cosa modifica.
struct WelcomeSheet: View {
    @Environment(AppModel.self) private var model
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Benvenuto in Belvedere").font(.system(size: 20, weight: .bold))
                    Text("Le sessioni di Claude Code e Codex, tutte in un posto.")
                        .foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                point("eye", "Belvedere legge già i log delle sessioni: la Plancia funziona anche senza collegamento.")
                point("bell.badge", "Collegando Claude Code vedi in tempo reale richieste di permesso, stato e limiti del piano.")
                point("doc.badge.gearshape", "Il collegamento aggiunge hook e status line a ~/.claude/settings.json, dopo averne salvato una copia. Si toglie dalle Impostazioni.")
            }
            if let error {
                Text(error).font(.callout).foregroundStyle(Theme.danger)
            }
            HStack {
                Spacer()
                Button("Più tardi") { model.dismissWelcome() }
                    .keyboardShortcut(.cancelAction)
                Button("Collega Claude Code") {
                    do {
                        try model.connectClaude()
                        model.dismissWelcome()
                    } catch {
                        self.error = "Non riuscito: \(error.localizedDescription)"
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(26)
        .frame(width: 500)
    }

    private func point(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 15))
                .foregroundStyle(Theme.accent)
                .frame(width: 22)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Nota nella Plancia finché Claude Code non è collegato.
struct ConnectBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "bolt.horizontal.circle").foregroundStyle(Theme.accent)
            Text("Collega Claude Code per vedere permessi e limiti in tempo reale.")
                .font(.system(size: 12.5))
            Spacer()
            Button("Collega…") { model.showWelcome = true }
                .buttonStyle(.borderless)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .glassEffect(.regular, in: .capsule)
    }
}
