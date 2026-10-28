import Foundation

/// Cosa fare di un testo scritto nel campo della chat.
public enum SlashRoute: Equatable, Sendable {
    case send(String)
    /// `/clear`: nuovo processo nella stessa cartella.
    case clear
    case setModel(String)
    /// Comandi che funzionano solo nel terminale.
    case terminalOnly(String)

    static let alwaysTerminal: Set<String> = ["plugin", "login", "logout", "resume", "exit", "quit"]

    public static func route(_ text: String, terminalCommands: [String]) -> SlashRoute {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return .send(text) }
        let parts = trimmed.dropFirst().split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard let name = parts.first.map(String.init) else { return .send(text) }
        let argument = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
        switch name {
        case "clear": return .clear
        case "model" where !argument.isEmpty: return .setModel(argument)
        default:
            if alwaysTerminal.contains(name) || terminalCommands.contains(name) { return .terminalOnly(name) }
            return .send(text)
        }
    }
}
