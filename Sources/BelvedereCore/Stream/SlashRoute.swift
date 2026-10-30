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
    /// Comandi che funzionano solo nel terminale.
    case terminalOnly(String)

    static let alwaysTerminal: Set<String> = ["login", "logout", "exit", "quit"]

    /// Comandi che la CLI non elenca in stream-json e che Belvedere esegue da sé: per il completamento.
    public static let nativeCommands = [
        SlashCommand(name: "remote-control", description: "Controlla la sessione dal telefono o da claude.ai/code", argumentHint: "[nome]"),
        SlashCommand(name: "rc", description: "Controlla la sessione dal telefono o da claude.ai/code", argumentHint: "[nome]"),
        SlashCommand(name: "plan", description: "Passa alla modalità piano", argumentHint: "[messaggio]"),
        SlashCommand(name: "resume", description: "Riprendi un'altra conversazione", argumentHint: "[cerca]"),
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
        default:
            if alwaysTerminal.contains(name) || terminalCommands.contains(name) { return .terminalOnly(name) }
            return .send(text)
        }
    }
}
