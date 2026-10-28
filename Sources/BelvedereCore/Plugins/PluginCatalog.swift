import Foundation

/// Un plugin installato, come lo elenca `claude plugin list --json`: lo stesso plugin può esserci
/// una volta per ambito (utente, progetto, locale).
public struct InstalledPlugin: Decodable, Identifiable, Equatable, Sendable {
    public let pluginID: String
    public let version: String?
    public let scope: String
    public let enabled: Bool
    public let projectPath: String?

    public var id: String { [pluginID, scope, projectPath ?? ""].joined(separator: "|") }
    public var name: String { String(pluginID.split(separator: "@").first ?? Substring(pluginID)) }
    public var marketplace: String { pluginID.split(separator: "@").dropFirst().first.map(String.init) ?? "" }

    enum CodingKeys: String, CodingKey {
        case pluginID = "id", version, scope, enabled, projectPath
    }
}

/// Un plugin dei marketplace aggiunti.
public struct AvailablePlugin: Decodable, Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let description: String
    public let marketplace: String
    public let installCount: Int?

    enum CodingKeys: String, CodingKey {
        case id = "pluginId", name, description, marketplace = "marketplaceName", installCount
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? id
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        marketplace = try c.decodeIfPresent(String.self, forKey: .marketplace) ?? ""
        installCount = try c.decodeIfPresent(Int.self, forKey: .installCount)
    }
}

/// `claude plugin list --available --json`.
public struct PluginCatalog: Decodable, Equatable, Sendable {
    public let installed: [InstalledPlugin]
    public let available: [AvailablePlugin]

    public static func decode(_ data: Data) throws -> PluginCatalog {
        try JSONDecoder().decode(PluginCatalog.self, from: data)
    }

    /// Plugin da installare: senza quelli già installati, i più installati prima.
    public func search(_ query: String) -> [AvailablePlugin] {
        let owned = Set(installed.map(\.pluginID))
        let q = query.trimmingCharacters(in: .whitespaces)
        return available
            .filter { !owned.contains($0.id) }
            .filter { q.isEmpty || $0.name.localizedCaseInsensitiveContains(q) || $0.description.localizedCaseInsensitiveContains(q) }
            .sorted { ($0.installCount ?? 0) > ($1.installCount ?? 0) }
    }
}

public enum PluginAction: String, Sendable {
    case install, uninstall, enable, disable, update
}

/// Righe di comando di `claude plugin`: Belvedere non tocca i file dei plugin, li gestisce la CLI.
public enum PluginCommand {
    public static let listArguments = ["plugin", "list", "--available", "--json"]

    /// Mai `-y`: un plugin che si installa eseguendo un comando del marketplace va confermato
    /// da una persona che lo legge, nel terminale.
    public static func arguments(_ action: PluginAction, plugin: String, scope: String) -> [String] {
        ["plugin", action.rawValue, "--json", "-s", scope, "--", plugin]
    }

    /// La riga da incollare nel terminale: id e ambito tra apici, l'id viene da un marketplace.
    public static func terminalLine(_ action: PluginAction, plugin: String, scope: String) -> String {
        "claude plugin \(action.rawValue) \(ClaudeCommand.quote(plugin)) -s \(ClaudeCommand.quote(scope))"
    }
}

/// La riga di risultato di un comando `claude plugin … --json`.
public struct PluginResult: Equatable, Sendable {
    public let succeeded: Bool
    public let message: String
    /// Il marketplace vuole eseguire un comando: si conferma solo nel terminale.
    public let needsTerminal: Bool

    public static func decode(_ stdout: Data, exitCode: Int32) -> PluginResult {
        let text = String(decoding: stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let line = text.split(separator: "\n").first { $0.hasPrefix("{") }
        guard let line, let obj = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else {
            return PluginResult(succeeded: exitCode == 0, message: text, needsTerminal: false)
        }
        let already = obj["alreadyInGoalState"] as? Bool == true
        let needsTerminal = obj["shownCommand"] != nil
        let failed = obj["outcome"] as? String == "failed" || exitCode != 0
        return PluginResult(succeeded: already || (!failed && !needsTerminal),
                            message: obj["message"] as? String ?? text, needsTerminal: needsTerminal)
    }
}
