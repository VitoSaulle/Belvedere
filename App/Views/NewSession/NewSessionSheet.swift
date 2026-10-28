import AppKit
import BelvedereCore
import SwiftUI

/// Foglio «Nuova sessione» (tavola F).
struct NewSessionSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var folder = ""
    @State private var agent: AgentKind = .claude
    @State private var isLocal = false
    @State private var cloudModel: String?
    @State private var localModel: LMStudioModel?
    @State private var permission: PermissionChoice = .ask
    @State private var worktree = false
    @State private var name = ""
    @State private var confirmSkip = false
    @State private var presetName = ""
    @State private var askPresetName = false

    private static let cloudModels: [(String?, String)] = [(nil, "Predefinito"), ("opus", "Opus"), ("sonnet", "Sonnet"), ("haiku", "Haiku")]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(0.5)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    folderSection
                    agentSection
                    whereSection
                    permissionSection
                    isolationSection
                    commandPreview
                }
                .padding(22)
            }
            Divider().opacity(0.5)
            footer
        }
        .frame(width: 640, height: 780)
        .tint(Theme.accent)
        .onAppear(perform: prefill)
        .confirmationDialog("Saltare tutti i permessi?", isPresented: $confirmSkip) {
            Button("Salta i permessi", role: .destructive) { permission = .skip }
            Button("Annulla", role: .cancel) {}
        } message: {
            Text("\(Theme.agentName(agent)) potrà modificare file ed eseguire comandi senza chiedere, per tutta la sessione.")
        }
        .alert("Salva come preset", isPresented: $askPresetName) {
            TextField("Nome", text: $presetName)
            Button("Salva") {
                let trimmed = presetName.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { model.savePreset(name: trimmed, options: options) }
                presetName = ""
            }
            Button("Annulla", role: .cancel) { presetName = "" }
        } message: {
            Text("«Salta permessi» non viene salvato nei preset.")
        }
    }

    // MARK: - Sezioni

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Nuova sessione").font(.system(size: 20, weight: .bold))
                Text("Le impostazioni del progetto (MCP, CLAUDE.md, skill) vengono lette dalla cartella, senza copiarle.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            presetMenu
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
    }

    private var presetMenu: some View {
        Menu {
            if model.presets.isEmpty {
                Text("Nessun preset")
            }
            ForEach(model.presets) { preset in
                Button(preset.name) { apply(preset.options) }
            }
            if !model.presets.isEmpty {
                Menu("Elimina") {
                    ForEach(model.presets) { preset in
                        Button(preset.name, role: .destructive) { model.deletePreset(preset.id) }
                    }
                }
            }
        } label: {
            Label("Preset", systemImage: "square.stack")
        }
        .menuStyle(.button)
        .fixedSize()
    }

    private var folderSection: some View {
        SheetSection(title: "Cartella") {
            HStack(spacing: 8) {
                Image(systemName: "folder").foregroundStyle(.secondary)
                Text(folder.isEmpty ? "Nessuna cartella scelta" : folder.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(folder.isEmpty ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("Scegli…", action: chooseFolder)
            }
            .padding(10)
            .background(Color.primary.opacity(0.04), in: .rect(cornerRadius: 10))
            if !recents.isEmpty {
                FlowChips(items: recents, selected: folder) { folder = $0 }
            }
        }
    }

    private var agentSection: some View {
        SheetSection(title: "Agente") {
            HStack(spacing: 10) {
                ChoiceCard(title: "Claude Code", subtitle: "claude -p, stream-json", selected: agent == .claude) { agent = .claude }
                ChoiceCard(title: "Codex", subtitle: "codex app-server", selected: agent == .codex) { agent = .codex }
            }
        }
    }

    private var whereSection: some View {
        SheetSection(title: "Modello") {
            HStack(spacing: 10) {
                ChoiceCard(title: "Cloud", subtitle: agent == .claude ? "Usa il tuo piano Claude" : "Modello e provider della config di Codex",
                           selected: !isLocal) { isLocal = false }
                ChoiceCard(title: "Locale · LM Studio", subtitle: "localhost:1234 · nessun token del piano", selected: isLocal) {
                    isLocal = true
                }
            }
            if isLocal {
                localModels
            } else if agent == .claude {
                Picker("Modello", selection: $cloudModel) {
                    ForEach(Self.cloudModels, id: \.1) { Text($0.1).tag($0.0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
        }
    }

    @ViewBuilder private var localModels: some View {
        let loaded = model.lmStudio?.models.filter(\.loaded) ?? []
        if model.lmStudio?.reachable != true {
            Label("LM Studio non è in esecuzione", systemImage: "exclamationmark.circle")
                .font(.callout)
                .foregroundStyle(Theme.waiting)
        } else if loaded.isEmpty {
            Label("Nessun modello caricato in LM Studio", systemImage: "exclamationmark.circle")
                .font(.callout)
                .foregroundStyle(Theme.waiting)
        } else {
            VStack(spacing: 6) {
                ForEach(loaded, id: \.id) { m in
                    Button { localModel = m } label: {
                        HStack {
                            Image(systemName: localModel?.id == m.id ? "largecircle.fill.circle" : "circle")
                                .foregroundStyle(localModel?.id == m.id ? Theme.accent : .secondary)
                            Text(m.id).font(.system(size: 13, design: .monospaced))
                            Spacer()
                            Text(m.contextLength.map { "\(Fmt.tokens($0)) ctx" } ?? "contesto non disponibile")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
            }
            // Un solo modello caricato: è quello, senza un clic in più.
            .task(id: loaded.map(\.id)) {
                if localModel == nil, loaded.count == 1 { localModel = loaded[0] }
            }
            if let warning = LaunchAdvice.contextWarning(localModel?.contextLength, agent: agent) {
                Text(warning).font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private var permissionSection: some View {
        SheetSection(title: "Permessi") {
            HStack(spacing: 10) {
                Picker("Permessi", selection: Binding(
                    get: { permission == .skip ? PermissionChoice.ask : permission },
                    set: { permission = $0 })) {
                    ForEach(PermissionChoice.allCases.filter { $0 != .skip }, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .disabled(permission == .skip)
                Button(permission == .skip ? "Permessi saltati" : "Salta permessi…") {
                    if permission == .skip { permission = .ask } else { confirmSkip = true }
                }
                .foregroundStyle(Theme.danger)
            }
            if permission == .skip {
                Label("\(Theme.agentName(agent)) non chiederà nulla in questa sessione. Clic su «Permessi saltati» per annullare.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(Theme.danger)
            }
        }
    }

    private var isolationSection: some View {
        SheetSection(title: "Isolamento e nome") {
            Toggle("Lavora in un worktree git separato", isOn: $worktree)
                .disabled(!canUseWorktree)
                .help(agent == .codex ? "Codex app-server non crea worktree" : isGitRepository ? "" : "La cartella non è un repository git")
            TextField("Nome della sessione (facoltativo)", text: $name)
                .textFieldStyle(.roundedBorder)
        }
    }

    private var commandPreview: some View {
        SheetSection(title: "Comando") {
            VStack(alignment: .leading, spacing: 4) {
                if agent == .codex {
                    Text(folder.isEmpty ? "codex" : CodexCommand.preview(options))
                } else {
                    if let local = options.local {
                        Text("ANTHROPIC_BASE_URL=http://localhost:1234  ANTHROPIC_MODEL=\(local.id)")
                    }
                    Text(folder.isEmpty ? "claude" : ClaudeCommand.preview(options, isGitRepository: isGitRepository))
                }
            }
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(Color.primary.opacity(0.04), in: .rect(cornerRadius: 10))
        }
    }

    private var footer: some View {
        HStack {
            Button("Salva come preset") { askPresetName = true }
                .disabled(folder.isEmpty)
            Spacer()
            Button("Annulla", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Avvia") {
                model.launch(options)
                dismiss()
            }
            .keyboardShortcut(.return, modifiers: .command)
            .buttonStyle(.borderedProminent)
            .tint(Theme.accent)
            .disabled(!canStart)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
    }

    // MARK: - Dati

    private var options: LaunchOptions {
        LaunchOptions(folder: folder,
                      agent: agent,
                      model: isLocal || agent == .codex ? nil : cloudModel,
                      permission: permission,
                      local: isLocal ? localModel.map { LocalModelChoice(id: $0.id, contextLength: $0.contextLength) } : nil,
                      worktree: worktree && canUseWorktree,
                      name: name.trimmingCharacters(in: .whitespaces).isEmpty ? nil : name)
    }

    private var isGitRepository: Bool { !folder.isEmpty && GitInfo.isRepository(folder) }

    private var canUseWorktree: Bool { agent == .claude && isGitRepository }

    private var canStart: Bool {
        !folder.isEmpty && (!isLocal || localModel != nil)
    }

    private var recents: [String] {
        var seen: Set<String> = []
        return model.sessions
            .filter { !$0.cwd.isEmpty && FileManager.default.fileExists(atPath: $0.cwd) }
            .compactMap { seen.insert($0.cwd).inserted ? $0.cwd : nil }
            .prefix(8)
            .map { $0 }
    }

    private func prefill() {
        folder = model.newSessionFolder ?? recents.first ?? ""
        if UserDefaults.standard.bool(forKey: "BelvedereNewSessionLocal") { isLocal = true }
        model.newSessionFolder = nil
    }

    private func apply(_ o: LaunchOptions) {
        folder = o.folder
        agent = o.agent
        isLocal = o.local != nil
        cloudModel = o.model
        localModel = o.local.flatMap { choice in model.lmStudio?.models.first { $0.id == choice.id } }
        permission = o.permission
        worktree = o.worktree
        name = o.name ?? ""
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Scegli"
        if !folder.isEmpty { panel.directoryURL = URL(fileURLWithPath: folder) }
        if panel.runModal() == .OK, let url = panel.url { folder = url.path }
    }
}

private struct SheetSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(.secondary)
            content
        }
    }
}

private struct ChoiceCard: View {
    let title: String
    let subtitle: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13.5, weight: .semibold))
                Text(subtitle).font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(selected ? Theme.accent.opacity(0.10) : Color.primary.opacity(0.03), in: .rect(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12)
                .strokeBorder(selected ? Theme.accent : Color.primary.opacity(0.10), lineWidth: selected ? 1.5 : 1))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

/// Cartelle recenti come capsule.
private struct FlowChips: View {
    let items: [String]
    let selected: String
    let pick: (String) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(items, id: \.self) { path in
                    Button { pick(path) } label: {
                        Text(Fmt.folder(path))
                            .font(.system(size: 12, weight: .medium))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(path == selected ? Theme.accent.opacity(0.14) : Color.primary.opacity(0.05),
                                        in: .capsule)
                            .foregroundStyle(path == selected ? Theme.accent : .primary)
                    }
                    .buttonStyle(.plain)
                    .help(path)
                }
            }
        }
    }
}
