import Foundation

public enum ModelInfo {
    public static let defaultContextWindow = 200_000

    /// Un modello servito a Claude Code che non è di Anthropic gira in locale (LM Studio).
    public static func isLocal(claudeModel: String) -> Bool {
        !claudeModel.hasPrefix("claude-")
    }

    /// "claude-opus-5-5" → "Opus 5.5"; i modelli non Anthropic restano invariati.
    public static func displayName(_ model: String) -> String {
        guard model.hasPrefix("claude-") else { return model }
        let parts = model.dropFirst("claude-".count).split(separator: "-")
        guard let family = parts.first else { return model }
        let version = parts.dropFirst().prefix { $0.count <= 2 && $0.allSatisfy(\.isNumber) }
        let name = family.prefix(1).uppercased() + family.dropFirst()
        return version.isEmpty ? name : name + " " + version.joined(separator: ".")
    }
}
