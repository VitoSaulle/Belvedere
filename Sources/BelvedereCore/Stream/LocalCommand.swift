import Foundation

/// Comandi che la CLI rifiuta in stream-json perché sono schermate del terminale:
/// Belvedere risponde in chat con gli stessi dati, in sola lettura. I file si aprono dai link.
public enum LocalCommand: String, CaseIterable, Sendable {
    case status, memory, permissions, hooks, skills, statusline

    public func report(_ state: ChatState, folder: String, configDir: String) -> String {
        let folder = state.cwd ?? folder
        switch self {
        case .status: return Self.status(state, folder: folder)
        case .memory: return Self.memory(folder: folder, configDir: configDir)
        case .permissions: return Self.permissions(state, folder: folder, configDir: configDir)
        case .hooks: return Self.hooks(folder: folder, configDir: configDir)
        case .skills: return Self.skills(state)
        case .statusline: return Self.statusLine(configDir: configDir)
        }
    }

    private static func status(_ state: ChatState, folder: String) -> String {
        var lines = ["**Stato**", "- Cartella: `\(folder)`"]
        if let id = state.sessionID { lines.append("- Sessione: `\(id)`") }
        if let model = state.model { lines.append("- Modello: `\(model)`") }
        if let mode = state.permissionMode { lines.append("- Permessi: `\(mode)`") }
        if let used = state.contextTokens, let window = state.contextWindow { lines.append("- Contesto: \(used) di \(window) token") }
        for server in state.mcpServers { lines.append("- MCP `\(server.name)`: \(server.status)") }
        return lines.joined(separator: "\n")
    }

    private static func memory(folder: String, configDir: String) -> String {
        var candidates = ["\(configDir)/CLAUDE.md"]
        // Dalla radice alla cartella, come li carica la CLI.
        var ancestors: [String] = []
        var current = URL(fileURLWithPath: folder)
        while current.path != "/" {
            ancestors.insert(current.path, at: 0)
            current.deleteLastPathComponent()
        }
        for dir in ancestors {
            candidates += ["\(dir)/CLAUDE.md", "\(dir)/.claude/CLAUDE.md", "\(dir)/CLAUDE.local.md"]
        }
        let slug = folder.replacingOccurrences(of: "[^a-zA-Z0-9]", with: "-", options: .regularExpression)
        candidates.append("\(configDir)/projects/\(slug)/memory/MEMORY.md")
        // La cartella di configurazione può stare sul percorso del progetto: `~/.claude` sotto la home.
        var seen = Set<String>()
        let found = candidates.filter { FileManager.default.fileExists(atPath: $0) && seen.insert($0).inserted }
        guard !found.isEmpty else { return "**Memoria**\nNessun file di memoria per questa cartella." }
        return (["**Memoria**"] + found.map { "- \(link($0))" }).joined(separator: "\n")
    }

    private static func permissions(_ state: ChatState, folder: String, configDir: String) -> String {
        var lines = ["**Permessi**"]
        if let mode = state.permissionMode { lines.append("Modalità: `\(mode)`") }
        for file in settingsFiles(folder: folder, configDir: configDir) {
            let rules = file.json?["permissions"] as? [String: Any] ?? [:]
            let groups = [("allow", "Consenti"), ("ask", "Chiedi"), ("deny", "Nega")].flatMap { key, label in
                (rules[key] as? [String] ?? []).map { "- \(label): `\($0)`" }
            }
            lines += section(file, body: groups, empty: "Nessuna regola")
        }
        return lines.joined(separator: "\n")
    }

    private static func hooks(folder: String, configDir: String) -> String {
        var lines = ["**Hook**"]
        for file in settingsFiles(folder: folder, configDir: configDir) {
            let events = file.json?["hooks"] as? [String: Any] ?? [:]
            let body = events.keys.sorted().flatMap { event in
                (events[event] as? [[String: Any]] ?? []).flatMap { group in
                    (group["hooks"] as? [[String: Any]] ?? []).map { "- \(event): `\($0["command"] as? String ?? $0["type"] as? String ?? "?")`" }
                }
            }
            lines += section(file, body: body, empty: "Nessun hook")
        }
        return lines.joined(separator: "\n")
    }

    private static func skills(_ state: ChatState) -> String {
        // `init` arriva col primo turno: prima c'è solo l'elenco di tutti i comandi.
        let names = state.skills.isEmpty ? state.commands.map(\.name) : state.skills
        guard !names.isEmpty else { return "**Skill**\nL'elenco arriva dopo l'avvio della sessione." }
        let descriptions = Dictionary(state.commands.map { ($0.name, $0.description) }) { first, _ in first }
        return (["**Skill**"] + names.sorted().map { name in
            let text = descriptions[name] ?? ""
            return text.isEmpty ? "- `\(name)`" : "- `\(name)`: \(text.prefix(100))"
        }).joined(separator: "\n")
    }

    private static func statusLine(configDir: String) -> String {
        let path = "\(configDir)/settings.json"
        let json = readJSON(path)
        let command = (json?["statusLine"] as? [String: Any])?["command"] as? String
        return "**Status line**\n" + (command.map { "`\($0)`" } ?? "Nessuna configurata.") + "\nSi imposta in \(link(path))."
    }

    private struct SettingsFile {
        let label: String
        let path: String
        let json: [String: Any]?
        var exists: Bool { FileManager.default.fileExists(atPath: path) }
    }

    private static func settingsFiles(folder: String, configDir: String) -> [SettingsFile] {
        [("Utente", "\(configDir)/settings.json"), ("Progetto", "\(folder)/.claude/settings.json"),
         ("Locale", "\(folder)/.claude/settings.local.json")]
            .map { SettingsFile(label: $0.0, path: $0.1, json: readJSON($0.1)) }
            .filter(\.exists)
    }

    private static func section(_ file: SettingsFile, body: [String], empty: String) -> [String] {
        let title = "\n\(file.label): \(link(file.path))"
        if file.json == nil { return [title, "Il file non si legge: JSON non valido."] }
        return [title] + (body.isEmpty ? [empty] : body)
    }

    private static func readJSON(_ path: String) -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func link(_ path: String) -> String {
        "[\((path as NSString).lastPathComponent)](\(URL(fileURLWithPath: path).absoluteString)) `\(path)`"
    }
}
