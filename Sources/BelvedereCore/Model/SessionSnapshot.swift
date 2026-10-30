import Foundation

public enum AgentKind: String, Codable, Sendable, CaseIterable {
    case claude, codex
}

extension AgentKind {
    public var productName: String { self == .claude ? "Claude Code" : "Codex" }
}

public enum SessionStatus: String, Codable, Sendable {
    case working, waiting, done, idle, ended
}

public struct TokenTotals: Codable, Equatable, Hashable, Sendable {
    public var input: Int
    public var output: Int
    public var cacheRead: Int
    public var cacheWrite: Int

    public init(input: Int = 0, output: Int = 0, cacheRead: Int = 0, cacheWrite: Int = 0) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
    }

    public static let zero = TokenTotals()

    public static func + (lhs: TokenTotals, rhs: TokenTotals) -> TokenTotals {
        TokenTotals(input: lhs.input + rhs.input, output: lhs.output + rhs.output,
                    cacheRead: lhs.cacheRead + rhs.cacheRead, cacheWrite: lhs.cacheWrite + rhs.cacheWrite)
    }

    public static func += (lhs: inout TokenTotals, rhs: TokenTotals) { lhs = lhs + rhs }

    public var total: Int { input + output + cacheRead + cacheWrite }
}

public struct PendingRequest: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case permission, question }

    public let id: String
    public let kind: Kind
    public let toolName: String?
    public let summary: String
    public let receivedAt: Date
    /// Strumento e input della richiesta: la accoppia al `PostToolUse` che la chiude.
    public let toolKey: String?

    public init(id: String, kind: Kind, toolName: String?, summary: String, receivedAt: Date, toolKey: String? = nil) {
        self.id = id
        self.toolKey = toolKey
        self.kind = kind
        self.toolName = toolName
        self.summary = summary
        self.receivedAt = receivedAt
    }
}

public struct FileChange: Codable, Equatable, Sendable {
    public let path: String
    public var added: Int
    public var removed: Int

    public init(path: String, added: Int, removed: Int) {
        self.path = path
        self.added = added
        self.removed = removed
    }
}

public struct SessionOrigin: Codable, Equatable, Sendable {
    public let appName: String
    public let bundleID: String?
    public let pid: Int32?

    public init(appName: String, bundleID: String?, pid: Int32?) {
        self.appName = appName
        self.bundleID = bundleID
        self.pid = pid
    }
}

public struct SessionSnapshot: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let agent: AgentKind
    public var cwd: String
    public var transcriptPath: String
    public var title: String?
    public var gitBranch: String?
    public var model: String?
    public var isLocalModel: Bool
    public var status: SessionStatus
    public var startedAt: Date?
    public var lastActivity: Date?
    public var lastText: String?
    public var tokens: TokenTotals
    public var contextTokens: Int?
    public var contextWindow: Int?
    public var costUSD: Double?
    public var toolCounts: [String: Int]
    public var filesChanged: [FileChange]
    public var pending: PendingRequest?
    public var origin: SessionOrigin?
    /// Profilo (account) a cui appartiene la sessione, dedotto dalla cartella della trascrizione.
    public var profileID: UUID?
    /// Ultima modalità dei permessi scritta nel log: la ripresa riparte da qui. Solo Claude Code.
    public var permissionMode: String?

    public init(id: String, agent: AgentKind, cwd: String = "", transcriptPath: String = "") {
        self.id = id
        self.agent = agent
        self.cwd = cwd
        self.transcriptPath = transcriptPath
        self.isLocalModel = false
        self.status = .idle
        self.tokens = .zero
        self.toolCounts = [:]
        self.filesChanged = []
    }

    /// Nome breve: il titolo della sessione o l'ultima cartella del percorso.
    public var displayName: String {
        if let title, !title.isEmpty { return title }
        let last = (cwd as NSString).lastPathComponent
        return last.isEmpty ? id : last
    }

    /// Percentuale del contesto usata, se nota.
    public var contextFraction: Double? {
        guard let used = contextTokens, let window = contextWindow, window > 0 else { return nil }
        return min(1, Double(used) / Double(window))
    }
}
