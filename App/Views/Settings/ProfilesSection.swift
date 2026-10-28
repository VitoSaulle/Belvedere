import AppKit
import BelvedereCore
import SwiftUI

/// Impostazioni › Profili: gli account di Claude Code e Codex, ciascuno nella sua cartella.
struct ProfilesSection: View {
    @Environment(AppModel.self) private var model
    @State private var adding = false
    @State private var removing: Profile?

    var body: some View {
        Section("Profili") {
            Text("Ogni profilo è un account con la sua cartella di configurazione. Le nuove sessioni partono con il profilo attivo; il login si fa nel Terminale con la CLI.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(AgentKind.allCases, id: \.self) { agent in
                ForEach(model.profiles.profiles(agent)) { profile in
                    ProfileRow(profile: profile) { removing = profile }
                }
            }
            if model.duplicateSessionCount > 0 {
                Text("\(model.duplicateSessionCount) conversazioni sono in più profili: Belvedere mostra la copia più recente.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if !model.unconnectedProfiles.isEmpty && model.unconnectedProfiles.count < model.profiles.profiles(.claude).count {
                HStack {
                    Text("Da collegare: \(model.unconnectedProfiles.map(\.name).joined(separator: ", ")).")
                        .font(.callout)
                    Spacer()
                    Button("Collega") { try? model.connectClaude() }
                }
            }
            Button("Aggiungi profilo…") { adding = true }
        }
        .sheet(isPresented: $adding) { AddProfileSheet() }
        .confirmationDialog("Eliminare il profilo «\(removing?.name ?? "")»?",
                            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("Elimina profilo", role: .destructive) {
                if let id = removing?.id { Task { await model.removeProfile(id) } }
                removing = nil
            }
        } message: {
            Text("Il profilo esce da Belvedere. La cartella \(Fmt.folder(removing?.configDir ?? "")) resta sul disco.")
        }
    }
}

private struct ProfileRow: View {
    @Environment(AppModel.self) private var model
    let profile: Profile
    let onRemove: () -> Void
    @State private var name = ""

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    TextField("Nome", text: $name)
                        .textFieldStyle(.plain)
                        .fixedSize()
                        .onSubmit { model.renameProfile(profile.id, to: name) }
                    Text(profile.agent.productName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if model.profiles.active(profile.agent).id == profile.id && model.profiles.hasChoice(profile.agent) {
                        Text("attivo").font(.caption.weight(.medium)).foregroundStyle(Theme.accent)
                    }
                }
                Text(model.profileFolderMissing(profile) ? "\(Fmt.folder(profile.configDir)) · cartella mancante" : Fmt.folder(profile.configDir))
                    .font(.caption)
                    .foregroundStyle(model.profileFolderMissing(profile) ? Theme.danger : .secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button("Accedi") { model.login(profile) }
                .help("Apre il Terminale con il login di \(profile.agent.productName) per questo profilo")
                .disabled(model.profileFolderMissing(profile))
            if !profile.isDefault {
                Button("Elimina", role: .destructive, action: onRemove)
            }
        }
        .onAppear { name = profile.name }
        .onChange(of: profile.name) { _, value in name = value }
    }
}

private struct AddProfileSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var agent: AgentKind = .claude
    @State private var folder = ""
    @State private var folderEdited = false
    @State private var seed = true
    @State private var error: String?
    @State private var saving = false

    var body: some View {
        Form {
            TextField("Nome", text: $name)
                .onChange(of: name) { _, _ in suggest() }
            Picker("CLI", selection: $agent) {
                ForEach(AgentKind.allCases, id: \.self) { Text($0.productName).tag($0) }
            }
            .onChange(of: agent) { _, _ in suggest() }
            LabeledContent("Cartella") {
                HStack {
                    Text(folder.isEmpty ? "—" : Fmt.folder(folder))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button("Scegli…", action: choose)
                }
            }
            if !folderExists {
                Toggle("Copia le impostazioni dal profilo Principale", isOn: $seed)
                Text(agent == .claude
                     ? "Copia settings.json (senza chiavi e token), CLAUDE.md, comandi, agenti e skill. Mai login né conversazioni."
                     : "Copia AGENTS.md. config.toml non viene copiato: può contenere token dei server MCP.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Dopo averlo creato, usa «Accedi» per fare il login con l'account di questo profilo.")
                .font(.callout)
                .foregroundStyle(.secondary)
            if let error { Text(error).font(.callout).foregroundStyle(Theme.danger) }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Annulla") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Crea profilo", action: create)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || folder.isEmpty || saving)
            }
        }
    }

    private var folderExists: Bool { FileManager.default.fileExists(atPath: (folder as NSString).expandingTildeInPath) }

    private func suggest() {
        guard !folderEdited else { return }
        folder = name.trimmingCharacters(in: .whitespaces).isEmpty
            ? "" : ProfileSet.suggestedFolder(name: name, agent: agent, home: Belvedere.home)
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.showsHiddenFiles = true
        panel.prompt = "Usa questa cartella"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        folder = url.path
        folderEdited = true
    }

    private func create() {
        saving = true
        Task {
            do {
                try await model.addProfile(name: name.trimmingCharacters(in: .whitespaces), agent: agent, folder: folder,
                                           seedSettings: seed && !folderExists)
                dismiss()
            } catch {
                self.error = "Non riuscito: \(error.localizedDescription)"
            }
            saving = false
        }
    }
}
