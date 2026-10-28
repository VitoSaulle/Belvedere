import BelvedereCore
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(Updater.self) private var updater
    @AppStorage(NotchController.enabledKey) private var notchEnabled = true
    @AppStorage(Appearance.key) private var appearance = Appearance.system.rawValue
    @State private var error: String?
    @State private var launchAtLogin = [.enabled, .requiresApproval].contains(SMAppService.mainApp.status)
    @State private var loginError: String?

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
                Button("Gestisci i plugin…") { model.showPlugins = true }
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

            Section("Avvio") {
                Toggle("Apri Belvedere al login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in setLaunchAtLogin(on) }
                if SMAppService.mainApp.status == .requiresApproval {
                    Text("macOS chiede di approvarlo in Impostazioni di Sistema › Generali › Elementi login.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                if let loginError {
                    Text(loginError).font(.callout).foregroundStyle(Theme.danger)
                }
            }

            Section("Aggiornamenti") {
                if updater.isAvailable {
                    Toggle("Controlla automaticamente", isOn: Binding(get: { updater.checksAutomatically },
                                                                      set: { updater.checksAutomatically = $0 }))
                    LabeledContent("Versione \(Updater.versionText)") {
                        Button("Controlla ora") { updater.checkForUpdates() }
                            .disabled(!updater.canCheck)
                    }
                } else {
                    LabeledContent("Versione", value: Updater.versionText)
                    Text("Gli aggiornamenti automatici ci sono solo nelle versioni scaricate da GitHub.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Aspetto") {
                Toggle("Mostra nel notch", isOn: $notchEnabled)
                Picker("Tema", selection: $appearance) {
                    ForEach(Appearance.allCases) { Text($0.label).tag($0.rawValue) }
                }
                .onChange(of: appearance) { _, value in (Appearance(rawValue: value) ?? .system).apply() }
            }

            Section("Sessioni nascoste (\(model.hiddenSessions.count))") {
                if model.hiddenSessions.isEmpty {
                    Text("Nessuna. Dal menu contestuale di una sessione scegli «Nascondi»: i file restano dove sono e la sessione ricompare se torna attiva.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(model.hiddenSessions) { session in
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(session.displayName).lineLimit(1)
                                Text("\(Fmt.folder(session.cwd)) · \(Fmt.ago(session.lastActivity))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Button("Mostra di nuovo") { model.unhide(session.id) }
                            DeleteButton(sessionIDs: [session.id]).labelStyle(.titleOnly)
                        }
                    }
                }
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

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = "Non riuscito: \(error.localizedDescription)"
        }
        // Lo stato vero, anche se la richiesta non è andata a buon fine.
        let enabled = [.enabled, .requiresApproval].contains(SMAppService.mainApp.status)
        if launchAtLogin != enabled { launchAtLogin = enabled }
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
