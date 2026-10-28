import Foundation

/// Un account di una CLI: la cartella di configurazione dove la CLI tiene login, impostazioni e conversazioni.
public struct Profile: Codable, Equatable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public var name: String
    public let agent: AgentKind
    public let configDir: String
    /// `~/.claude` o `~/.codex`: al lancio nessuna variabile, come prima dei profili.
    public let isDefault: Bool

    public init(id: UUID = UUID(), name: String, agent: AgentKind, configDir: String, isDefault: Bool = false) {
        self.id = id
        self.name = name
        self.agent = agent
        self.configDir = configDir
        self.isDefault = isDefault
    }

    /// Dove la CLI scrive le trascrizioni.
    public var transcriptRoot: URL {
        URL(fileURLWithPath: configDir, isDirectory: true)
            .appendingPathComponent(agent == .claude ? "projects" : "sessions", isDirectory: true)
    }

    /// Variabile che indica alla CLI la cartella del profilo.
    public var environmentKey: String { agent == .claude ? "CLAUDE_CONFIG_DIR" : "CODEX_HOME" }
}

/// Tutti i profili, con il profilo attivo di ciascuna CLI.
public struct ProfileSet: Codable, Equatable, Sendable {
    public static let storageKey = "profiles"

    public private(set) var profiles: [Profile]
    public private(set) var active: [AgentKind: UUID]

    /// I due profili predefiniti, attivi.
    public static func initial(home: URL) -> ProfileSet {
        let claude = Profile(name: "Principale", agent: .claude,
                             configDir: home.appendingPathComponent(".claude").path, isDefault: true)
        let codex = Profile(name: "Principale", agent: .codex,
                            configDir: home.appendingPathComponent(".codex").path, isDefault: true)
        return ProfileSet(profiles: [claude, codex], active: [.claude: claude.id, .codex: codex.id])
    }

    public func profiles(_ agent: AgentKind) -> [Profile] { profiles.filter { $0.agent == agent } }

    public func defaultProfile(_ agent: AgentKind) -> Profile {
        profiles.first { $0.agent == agent && $0.isDefault }!
    }

    public func active(_ agent: AgentKind) -> Profile {
        profile(active[agent]).flatMap { $0.agent == agent ? $0 : nil } ?? defaultProfile(agent)
    }

    public func profile(_ id: UUID?) -> Profile? {
        guard let id else { return nil }
        return profiles.first { $0.id == id }
    }

    /// Più di un profilo per la CLI: solo allora l'interfaccia mostra switch, badge e selettori.
    public func hasChoice(_ agent: AgentKind) -> Bool { profiles(agent).count > 1 }

    public mutating func add(_ p: Profile) {
        guard !profiles.contains(where: { $0.id == p.id }) else { return }
        profiles.append(p)
    }

    public mutating func rename(_ id: UUID, to name: String) {
        guard let i = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles[i].name = name
    }

    public mutating func setActive(_ id: UUID) {
        guard let p = profile(id) else { return }
        active[p.agent] = id
    }

    /// I predefiniti restano; se esce l'attivo, torna attivo il predefinito.
    public mutating func remove(_ id: UUID) {
        guard let p = profile(id), !p.isDefault else { return }
        profiles.removeAll { $0.id == id }
        if active[p.agent] == id { active[p.agent] = defaultProfile(p.agent).id }
    }

    /// `~/.claude-<nome>` o `~/.codex-<nome>`, la convenzione di chi lo fa già a mano.
    public static func suggestedFolder(name: String, agent: AgentKind, home: URL) -> String {
        let folded = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
        let slug = folded.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? String($0) : "-" }.joined()
            .split(separator: "-").joined(separator: "-")
        let base = agent == .claude ? ".claude" : ".codex"
        return home.appendingPathComponent(slug.isEmpty ? base + "-profilo" : base + "-" + slug).path
    }
}
