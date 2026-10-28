import BelvedereCore
import SwiftUI

/// Pannello «Plugin» (`/plugin`): installati con interruttore, aggiornamento e rimozione; ricerca nei marketplace.
struct PluginsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var removing: InstalledPlugin?

    private var plugins: PluginManager { model.plugins }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(0.5)
            messages
            List {
                Section("Installati") {
                    if let catalog = plugins.catalog {
                        if catalog.installed.isEmpty {
                            Text("Nessun plugin installato.").foregroundStyle(.secondary)
                        }
                        ForEach(catalog.installed) { installedRow($0) }
                    } else if plugins.isLoading {
                        HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Leggo i plugin…").foregroundStyle(.secondary) }
                    }
                }
                Section("Da installare") {
                    TextField("Cerca nei marketplace", text: $query)
                        .textFieldStyle(.roundedBorder)
                    if let catalog = plugins.catalog {
                        let results = catalog.search(query)
                        ForEach(results.prefix(60)) { availableRow($0) }
                        if results.count > 60 {
                            Text("Altri \(results.count - 60): affina la ricerca.").font(.callout).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            Divider().opacity(0.5)
            footer
        }
        .frame(width: 620, height: 680)
        .tint(Theme.accent)
        .task { await plugins.load() }
        .confirmationDialog("Disinstallare \(removing?.name ?? "")?", isPresented: Binding(
            get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("Disinstalla", role: .destructive) {
                guard let p = removing else { return }
                Task { await plugins.perform(.uninstall, plugin: p.pluginID, scope: p.scope, projectPath: p.projectPath) }
            }
            Button("Annulla", role: .cancel) {}
        } message: {
            Text("Il plugin viene rimosso dall'ambito «\(scopeLabel(removing))». I suoi dati salvati restano.")
        }
    }

    // MARK: - Parti

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Plugin").font(.system(size: 20, weight: .bold))
                Text("Gestiti con `claude plugin`: Belvedere non modifica a mano i file dei plugin.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button { Task { await plugins.load() } } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless)
                .disabled(plugins.isLoading)
                .help("Ricarica")
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
    }

    @ViewBuilder private var messages: some View {
        if let error = plugins.error {
            notice(error, systemImage: "exclamationmark.triangle.fill", tint: Theme.danger)
        }
        if let command = plugins.terminalCommand {
            VStack(alignment: .leading, spacing: 6) {
                Text("Questo plugin si installa eseguendo un comando scelto dal marketplace. Leggilo e confermalo nel terminale:")
                    .font(.system(size: 12.5))
                Text(command).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.waiting.opacity(0.12), in: .rect(cornerRadius: 10))
            .padding(.horizontal, 16)
            .padding(.top, 10)
        }
    }

    private func notice(_ text: String, systemImage: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: systemImage).foregroundStyle(tint)
            Text(text).font(.system(size: 12.5)).textSelection(.enabled).lineLimit(4)
            Spacer()
            Button { plugins.dismissMessages() } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
        }
        .padding(10)
        .background(tint.opacity(0.10), in: .rect(cornerRadius: 10))
        .padding(.horizontal, 16)
        .padding(.top, 10)
    }

    private func installedRow(_ p: InstalledPlugin) -> some View {
        let busy = plugins.isBusy(p.pluginID, scope: p.scope, projectPath: p.projectPath)
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(p.name).font(.system(size: 13, weight: .semibold))
                Text([p.marketplace, p.version.map { "v\($0)" }, scopeLabel(p)].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if busy { ProgressView().controlSize(.small) }
            Toggle("Attivo", isOn: Binding(get: { p.enabled }, set: { on in
                Task { await plugins.perform(on ? .enable : .disable, plugin: p.pluginID, scope: p.scope, projectPath: p.projectPath) }
            }))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
            .disabled(busy)
            Menu {
                Button("Aggiorna", systemImage: "arrow.down.circle") {
                    Task { await plugins.perform(.update, plugin: p.pluginID, scope: p.scope, projectPath: p.projectPath) }
                }
                Button("Disinstalla…", systemImage: "trash", role: .destructive) { removing = p }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(.borderless)
            .fixedSize()
            .disabled(busy)
        }
        .padding(.vertical, 2)
    }

    private func availableRow(_ p: AvailablePlugin) -> some View {
        let busy = plugins.isBusy(p.id)
        return HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(p.name).font(.system(size: 13, weight: .semibold))
                if !p.description.isEmpty {
                    Text(p.description).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
                }
                Text([p.marketplace, p.installCount.map { "\(Fmt.tokens($0)) installazioni" }].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            if busy {
                ProgressView().controlSize(.small)
            } else {
                Button("Installa") { Task { await plugins.perform(.install, plugin: p.id) } }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .controlSize(.small)
            }
        }
        .padding(.vertical, 2)
    }

    private var footer: some View {
        HStack {
            Text(plugins.changedSinceOpen
                 ? "Le modifiche valgono per le sessioni che partono da ora; in quelle aperte usa /reload-plugins nel terminale."
                 : "Si installano nell'ambito utente, per tutti i progetti.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("Fine") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
    }

    private func scopeLabel(_ p: InstalledPlugin?) -> String {
        switch p?.scope {
        case "project": "progetto \(Fmt.folder(p?.projectPath ?? ""))"
        case "local": "locale \(Fmt.folder(p?.projectPath ?? ""))"
        default: "utente"
        }
    }
}
