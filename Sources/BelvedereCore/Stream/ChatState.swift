import Foundation

/// Conversazione di una sessione lanciata da Belvedere, ricostruita dai messaggi stream-json.
public struct ChatState: Sendable {
    public var agent: AgentKind
    public var items: [TranscriptItem]
    /// Testo dell'assistente ancora in arrivo nel turno in corso.
    public var streaming: String?
    /// Permessi e domande che aspettano una risposta, dal più vecchio.
    public var asks: [PermissionAsk] = []
    public var status: SessionStatus = .idle
    public var sessionID: String?
    public var cwd: String?
    public var model: String?
    public var permissionMode: String?
    public var mcpServers: [MCPServerInfo] = []
    public var commands: [SlashCommand] = []
    public var terminalCommands: [String] = []
    public var contextTokens: Int?
    public var contextWindow: Int?
    public var costUSD: Double?
    public var limits: PlanLimits?
    public var lastError: String?
    public var lastActivity: Date?

    public init(agent: AgentKind = .claude, history: [TranscriptItem] = []) {
        self.agent = agent
        items = history
    }

    /// Una sessione ripresa con `--resume`: la CLI manda `init` solo al primo turno,
    /// ma id e cartella sono già noti.
    public init(agent: AgentKind = .claude, history: [TranscriptItem] = [], resuming sessionID: String, folder: String) {
        self.agent = agent
        items = history
        self.sessionID = sessionID
        cwd = folder
    }

    public mutating func apply(_ message: StreamMessage, now: Date) {
        switch message {
        case .initialized(let info):
            sessionID = info.sessionID
            cwd = info.cwd
            model = info.model
            permissionMode = info.permissionMode
            mcpServers = info.mcpServers
            terminalCommands = info.terminalCommands
            if commands.isEmpty { commands = info.slashCommands.map { SlashCommand(name: $0, description: "", argumentHint: "") } }
        case .commands(let list):
            commands = list
        case .line(let json):
            lastActivity = now
            guard case .object = json, let object = json.anyValue as? [String: Any] else { return }
            if json["type"]?.stringValue == "user", let text = json["message"]?["content"]?.stringValue,
               let output = Self.localOutput(text) {
                upsert(.assistant(id: json["uuid"]?.stringValue ?? UUID().uuidString, text: output))
                return
            }
            let parsed = TranscriptMessages.claudeItems(object)
            parsed.forEach { upsert($0) }
            if json["type"]?.stringValue == "assistant" {
                if parsed.contains(where: { if case .assistant = $0 { true } else { false } }) { streaming = nil }
                if status != .waiting { status = .working }
            }
        case .textDelta(let text):
            streaming = (streaming ?? "") + text
            lastActivity = now
            if status != .waiting { status = .working }
        case .permission(let ask):
            asks.removeAll { $0.id == ask.id }
            asks.append(ask)
            status = .waiting
            lastActivity = now
        case .controlResponse:
            break
        case .rateLimits(let l):
            limits = l
        case .interrupted:
            streaming = nil
            asks = []
            status = .idle
            lastActivity = now
        case .result(let result):
            streaming = nil
            lastActivity = now
            if let cost = result.costUSD { costUSD = cost }
            if let tokens = result.contextTokens, tokens > 0 { contextTokens = tokens }
            if let window = result.contextWindow { contextWindow = window }
            if result.subtype == "error_during_execution" {
                if status != .idle { status = .idle }
            } else {
                status = asks.isEmpty ? .done : .waiting
                if result.isError {
                    lastError = result.message?.nilIfEmpty ?? "Il turno si è chiuso con un errore (\(result.subtype))."
                }
            }
        case .other:
            break
        }
    }

    public mutating func userSent(_ text: String, now: Date) {
        items.append(.user(id: "local-\(UUID().uuidString)", text: text))
        status = asks.isEmpty ? .working : .waiting
        lastError = nil
        lastActivity = now
    }

    /// Il messaggio non è arrivato a Claude (processo assente o chiuso): niente «al lavoro».
    public mutating func sendFailed(_ error: String, now: Date) {
        streaming = nil
        asks = []
        status = .ended
        lastError = error
        lastActivity = now
    }

    public mutating func answered(_ requestID: String) {
        asks.removeAll { $0.id == requestID }
        if asks.isEmpty && status == .waiting { status = .working }
    }

    public mutating func processExited(code: Int32, stderr: String, now: Date) {
        streaming = nil
        asks = []
        status = .ended
        lastActivity = now
        guard code != 0 else { return }
        let text = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        lastError = text.isEmpty ? "\(agent.productName) si è chiuso con il codice \(code)." : text
    }

    /// La sessione come la vedono Plancia, menu bar e notch; `nil` finché Claude non ha dato l'id.
    public func snapshot(launchedAt: Date?) -> SessionSnapshot? {
        guard let sessionID else { return nil }
        var s = SessionSnapshot(id: sessionID, agent: agent, cwd: cwd ?? "")
        s.status = status
        s.model = model
        s.startedAt = launchedAt
        s.lastActivity = lastActivity ?? launchedAt
        s.contextTokens = contextTokens
        s.contextWindow = contextWindow
        s.costUSD = costUSD
        s.origin = SessionOrigin(appName: "Belvedere", bundleID: nil, pid: nil)
        for item in items.reversed() {
            if case .assistant(_, let text) = item { s.lastText = String(text.prefix(280)); break }
        }
        if let ask = asks.first {
            s.pending = PendingRequest(id: ask.id, kind: ask.isQuestion ? .question : .permission, toolName: ask.toolName,
                                       summary: Self.summary(ask), receivedAt: lastActivity ?? Date())
        }
        return s
    }

    /// Riga della sessione che non è di nessuno (un'interruzione, un cambio di modello).
    public mutating func addNote(_ text: String) {
        items.append(.note(id: "nota-\(UUID().uuidString)", text: text))
    }

    mutating func upsert(_ item: TranscriptItem) {
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            items[index] = item
        } else {
            items.append(item)
        }
    }

    private static func localOutput(_ text: String) -> String? {
        let open = "<local-command-stdout>", close = "</local-command-stdout>"
        guard text.hasPrefix(open) else { return nil }
        var inner = text.dropFirst(open.count)
        if inner.hasSuffix(close) { inner = inner.dropLast(close.count) }
        let trimmed = inner.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func summary(_ ask: PermissionAsk) -> String {
        if ask.isQuestion, case .array(let questions)? = ask.input["questions"],
           let first = questions.first?["question"]?.stringValue {
            return first
        }
        for key in ["command", "file_path", "url", "pattern"] {
            if let value = ask.input[key]?.stringValue { return value }
        }
        return ask.description ?? ask.toolName
    }
}
