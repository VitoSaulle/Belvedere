import Foundation

/// Impostazioni di un profilo nuovo, copiate dal predefinito senza credenziali.
public enum ProfileSettings {
    /// Chiavi che portano credenziali o forzano l'account: non passano mai a un altro profilo.
    static let droppedKeys: Set<String> = ["apiKeyHelper", "awsAuthRefresh", "awsCredentialExport", "otelHeadersHelper",
                                           "forceLoginMethod", "forceLoginOrgUUID"]
    static let droppedEnvFragments = ["KEY", "TOKEN", "SECRET", "PASSWORD", "AUTH"]
    static let droppedEnv: Set<String> = ["ANTHROPIC_BASE_URL", "CLAUDE_CONFIG_DIR"]

    /// `settings.json` del predefinito senza credenziali e senza le voci di Belvedere,
    /// che il collegamento rimette con i percorsi giusti.
    public static func filteredClaudeSettings(_ settings: [String: Any], port: UInt16) -> [String: Any] {
        var result = ClaudeSettingsInstaller.uninstall(from: settings, port: port)
        for key in droppedKeys { result.removeValue(forKey: key) }
        if let env = result["env"] as? [String: Any] {
            let kept = env.filter { name, _ in
                let upper = name.uppercased()
                return !droppedEnv.contains(upper) && !droppedEnvFragments.contains { upper.contains($0) }
            }
            result["env"] = kept.isEmpty ? nil : kept
        }
        return result
    }

    /// Cosa si copia: mai credenziali, conversazioni, cache o plugin. Il `config.toml` di Codex
    /// può contenere token dei server MCP e resta fuori.
    public static func copiedItems(_ agent: AgentKind) -> [String] {
        agent == .claude ? ["settings.json", "CLAUDE.md", "commands", "agents", "skills"] : ["AGENTS.md"]
    }

    /// Crea la cartella del profilo e ci copia le impostazioni del predefinito. Non sovrascrive niente.
    public static func seed(from source: Profile, to target: Profile, port: UInt16,
                            fileManager fm: FileManager = .default) throws {
        let from = URL(fileURLWithPath: source.configDir, isDirectory: true)
        let to = URL(fileURLWithPath: target.configDir, isDirectory: true)
        try fm.createDirectory(at: to, withIntermediateDirectories: true)
        for name in copiedItems(target.agent) {
            let src = from.appendingPathComponent(name), dst = to.appendingPathComponent(name)
            guard fm.fileExists(atPath: src.path), !fm.fileExists(atPath: dst.path) else { continue }
            if name == "settings.json" {
                let filtered = filteredClaudeSettings(try SettingsFile(url: src).read(), port: port)
                let data = try JSONSerialization.data(withJSONObject: filtered,
                                                      options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
                try data.write(to: dst, options: .atomic)
            } else {
                try fm.copyItem(at: src.resolvingSymlinksInPath(), to: dst)
            }
        }
    }
}

extension SettingsFile {
    /// Il `settings.json` di un profilo Claude.
    public init(profile: Profile) {
        self.init(url: URL(fileURLWithPath: profile.configDir, isDirectory: true).appendingPathComponent("settings.json"))
    }
}
