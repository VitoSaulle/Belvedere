import BelvedereCore
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(NotchController.enabledKey) private var notchEnabled = true
    @AppStorage(Appearance.key) private var appearance = Appearance.system.rawValue
    @State private var error: String?

    var body: some View {
        Form {
            Section("Claude Code") {
                LabeledContent("Collegamento") {
                    HStack(spacing: 6) {
                        Circle().fill(model.hooksInstalled ? Theme.done : Theme.idle).frame(width: 8, height: 8)
                        Text(model.hooksInstalled ? "Collegato" : "Non collegato")
                    }
                }
                Text("Il collegamento aggiunge a ~/.claude/settings.json i hook di Belvedere e una status line che inoltra i limiti del piano. Le altre impostazioni restano com'erano e prima di ogni modifica viene salvata una copia.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    if model.hooksInstalled {
                        Button("Scollega Claude Code", role: .destructive) { run { try model.disconnectClaude() } }
                        Button("Aggiorna collegamento") { run { try model.connectClaude() } }
                    } else {
                        Button("Collega Claude Code") { run { try model.connectClaude() } }
                            .buttonStyle(.borderedProminent)
                    }
                }
                if let backup = model.lastBackup {
                    LabeledContent("Ultimo backup") {
                        Button((backup as NSString).lastPathComponent) {
                            NSWorkspace.shared.selectFile(backup, inFileViewerRootedAtPath: "")
                        }
                        .buttonStyle(.link)
                        .help(backup)
                    }
                }
                if let error {
                    Text(error).font(.callout).foregroundStyle(Theme.danger)
                }
            }

            Section("Permessi") {
                Picker("Richieste di permesso", selection: Binding(
                    get: { model.policy == .observeOnly ? "observe" : "hold" },
                    set: { model.setPolicy(PermissionPolicy(storageValue: $0)) })) {
                    Text("Rispondi da Belvedere o dal terminale").tag("hold")
                    Text("Solo osservare").tag("observe")
                }
                .pickerStyle(.radioGroup)
                Text("Con la prima opzione vince la prima risposta, ovunque arrivi. Con «Solo osservare» si risponde sempre nel terminale.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Aspetto") {
                Toggle("Mostra nel notch", isOn: $notchEnabled)
                Picker("Tema", selection: $appearance) {
                    ForEach(Appearance.allCases) { Text($0.label).tag($0.rawValue) }
                }
                .onChange(of: appearance) { _, value in (Appearance(rawValue: value) ?? .system).apply() }
            }

            Section("Server locale") {
                LabeledContent("Indirizzo", value: "127.0.0.1:\(Belvedere.defaultPort)")
                if let error = model.serverError {
                    Text(error).font(.callout).foregroundStyle(Theme.danger)
                } else {
                    LabeledContent("Stato", value: "In ascolto")
                }
            }

            Section("Cartelle osservate") {
                ForEach(model.watchedFolders, id: \.self) { url in
                    Text(url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .font(.system(.body, design: .monospaced))
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 640)
    }

    private func run(_ action: () throws -> Void) {
        do {
            try action()
            error = nil
        } catch {
            self.error = "Non riuscito: \(error.localizedDescription)"
        }
    }
}
