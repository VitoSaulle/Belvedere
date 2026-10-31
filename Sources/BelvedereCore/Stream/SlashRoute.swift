import Foundation

/// Cosa fare di un testo scritto nel campo della chat.
public enum SlashRoute: Equatable, Sendable {
    case send(String)
    /// `/clear`: nuovo processo nella stessa cartella.
    case clear
    case setModel(String)
    /// `/plugin`: il pannello nativo, sopra `claude plugin …`.
    case plugins
    /// `/rc`: Remote Control, sopra la richiesta di controllo `remote_control`.
    case remoteControl(name: String?)
    /// `/plan`: la modalità piano, più il messaggio se c'è.
    case plan(prompt: String?)
    /// `/resume`: il selettore delle conversazioni, con il testo cercato se c'è.
    case resume(query: String?)
    /// Schermate del terminale a cui Belvedere risponde da sé.
    case local(LocalCommand)
    /// `/theme`: l'aspetto di Belvedere, chiaro, scuro o di sistema; senza argomento si alterna.
    case theme(String?)
    /// Comandi che funzionano solo nel terminale.
    case terminalOnly(String)

    static let alwaysTerminal: Set<String> = ["login", "logout", "exit", "quit"]

    /// Comandi che la CLI non elenca in stream-json e che Belvedere esegue da sé: per il completamento.
    public static let nativeCommands = [
        SlashCommand(name: "remote-control", description: "Controlla la sessione dal telefono o da claude.ai/code", argumentHint: "[nome]"),
        SlashCommand(name: "rc", description: "Controlla la sessione dal telefono o da claude.ai/code", argumentHint: "[nome]"),
        SlashCommand(name: "plan", description: "Passa alla modalità piano", argumentHint: "[messaggio]"),
        SlashCommand(name: "resume", description: "Riprendi un'altra conversazione", argumentHint: "[cerca]"),
        SlashCommand(name: "status", description: "Stato della sessione", argumentHint: ""),
        SlashCommand(name: "memory", description: "File di memoria e CLAUDE.md in uso", argumentHint: ""),
        SlashCommand(name: "permissions", description: "Regole dei permessi", argumentHint: ""),
        SlashCommand(name: "hooks", description: "Hook configurati", argumentHint: ""),
        SlashCommand(name: "skills", description: "Skill disponibili", argumentHint: ""),
        SlashCommand(name: "statusline", description: "Status line configurata", argumentHint: ""),
        SlashCommand(name: "tasks", description: "Subagent e altre sessioni attive", argumentHint: ""),
        SlashCommand(name: "theme", description: "Aspetto di Belvedere", argumentHint: "[chiaro|scuro|sistema]"),
    ]

    public static func route(_ text: String, terminalCommands: [String]) -> SlashRoute {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return .send(text) }
        let parts = trimmed.dropFirst().split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard let name = parts.first.map(String.init) else { return .send(text) }
        let argument = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
        switch name {
        case "clear": return .clear
        case "plugin", "plugins": return .plugins
        case "model" where !argument.isEmpty: return .setModel(argument)
        case "rc", "remote-control": return .remoteControl(name: argument.isEmpty ? nil : argument)
        case "plan": return .plan(prompt: argument.isEmpty ? nil : argument)
        case "resume": return .resume(query: argument.isEmpty ? nil : argument)
        case "theme": return .theme(argument.isEmpty ? nil : argument)
        // La CLI non ha `/tasks` in stream-json: `/list-agents` è il suo equivalente più vicino.
        case "tasks": return .send("/list-agents")
        default:
            if let local = LocalCommand(rawValue: name) { return .local(local) }
            if alwaysTerminal.contains(name) || terminalCommands.contains(name) { return .terminalOnly(name) }
            return .send(text)
        }
    }
}
