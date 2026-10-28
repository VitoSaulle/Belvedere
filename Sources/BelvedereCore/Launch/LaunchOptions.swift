import Foundation

public enum PermissionChoice: String, Codable, CaseIterable, Sendable {
    case ask, acceptEdits, auto, plan, skip

    public var label: String {
        switch self {
        case .ask: "Chiedi"
        case .acceptEdits: "Accetta modifiche"
        case .auto: "Auto"
        case .plan: "Solo piano"
        case .skip: "Salta permessi"
        }
    }
}

/// Modello di LM Studio scelto per una sessione locale.
public struct LocalModelChoice: Codable, Equatable, Sendable {
    public let id: String
    public let contextLength: Int?

    public init(id: String, contextLength: Int?) {
        self.id = id
        self.contextLength = contextLength
    }
}

/// Tutto ciò che serve per lanciare (o riprendere) una sessione Claude Code o Codex.
public struct LaunchOptions: Codable, Equatable, Sendable {
    public var agent: AgentKind
    public var folder: String
    /// Alias (`opus`, `sonnet`, `haiku`) o id; `nil` = il predefinito di Claude Code.
    public var model: String?
    public var permission: PermissionChoice
    public var local: LocalModelChoice?
    public var worktree: Bool
    public var resumeID: String?
    public var name: String?

    public init(folder: String, agent: AgentKind = .claude, model: String? = nil, permission: PermissionChoice = .ask,
                local: LocalModelChoice? = nil, worktree: Bool = false, resumeID: String? = nil, name: String? = nil) {
        self.agent = agent
        self.folder = folder
        self.model = model
        self.permission = permission
        self.local = local
        self.worktree = worktree
        self.resumeID = resumeID
        self.name = name
    }

    private enum CodingKeys: String, CodingKey { case agent, folder, model, permission, local, worktree, resumeID, name }

    /// I preset salvati prima di Codex non hanno `agent`: sono sessioni Claude.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        agent = try c.decodeIfPresent(AgentKind.self, forKey: .agent) ?? .claude
        folder = try c.decode(String.self, forKey: .folder)
        model = try c.decodeIfPresent(String.self, forKey: .model)
        permission = try c.decode(PermissionChoice.self, forKey: .permission)
        local = try c.decodeIfPresent(LocalModelChoice.self, forKey: .local)
        worktree = try c.decode(Bool.self, forKey: .worktree)
        resumeID = try c.decodeIfPresent(String.self, forKey: .resumeID)
        name = try c.decodeIfPresent(String.self, forKey: .name)
    }

    /// Le stesse scelte per la volta dopo: «Salta permessi» non resta mai selezionato.
    public var forNextLaunch: LaunchOptions {
        var next = self
        if next.permission == .skip { next.permission = .ask }
        next.resumeID = nil
        return next
    }
}

public struct LaunchPreset: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public var options: LaunchOptions

    public init(id: UUID = UUID(), name: String, options: LaunchOptions) {
        self.id = id
        self.name = name
        self.options = options.forNextLaunch
    }
}

extension LaunchOptions {
    /// Le stesse scelte per riprendere `id`: nella cartella dove la sessione lavora davvero
    /// (un worktree già creato), senza crearne un altro.
    public func resuming(_ id: String, cwd: String?) -> LaunchOptions {
        var o = self
        o.resumeID = id
        if let cwd, !cwd.isEmpty { o.folder = cwd }
        o.worktree = false
        return o
    }

    /// Opzioni per riprendere una sessione vista nei log; una sessione locale resta locale.
    public static func resuming(_ s: SessionSnapshot) -> LaunchOptions {
        let local = s.isLocalModel ? s.model.map { LocalModelChoice(id: $0, contextLength: s.contextWindow) } : nil
        return LaunchOptions(folder: s.cwd, agent: s.agent, local: local, resumeID: s.id)
    }
}
