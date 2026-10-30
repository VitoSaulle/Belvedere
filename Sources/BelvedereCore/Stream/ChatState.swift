import Foundation

/// Conversazione di una sessione lanciata da Belvedere, ricostruita dai messaggi stream-json.
public struct ChatState: Sendable {
    public var agent: AgentKind
    /// Modello di LM Studio: niente costi e niente quota del piano.
    public var isLocal: Bool
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
    /// Remote Control attivo; `nil` se è spento.
    public var remoteControl: RemoteControl?
    /// Richiesta `remote_control` senza ancora risposta.
    var remoteControlRequest: (id: String, enabling: Bool)?
    /// Comando rifiutato dalla CLI perché esiste solo nel terminale.
    public var unavailableCommand: String?
    public var contextTokens: Int?
    public var contextWindow: Int?
    public var costUSD: Double?
    public var limits: PlanLimits?
    /// Le righe utili dell'errore; `errorDetail` ha il testo completo quando è stato accorciato.
    public var lastError: String? { didSet { errorDetail = nil } }
    public var errorDetail: String?
    /// Un messaggio scritto mentre Claude lavorava: la CLI lo esegue dopo il `result` del turno in corso
    /// (anche dopo un'interruzione), unendo in un turno solo tutti quelli in coda.
    var queuedTurn = false
    /// L'ultimo messaggio in coda: se la sua eco arriva prima del `result`, la CLI l'ha unito al turno in corso.
    var lastQueuedID: String?
    public var lastActivity: Date?
    /// Turni chiusi senza errore: il primo conferma il passaggio della conversazione a un altro profilo.
    public var completedTurns = 0

    public init(agent: AgentKind = .claude, isLocal: Bool = false, history: [TranscriptItem] = []) {
        self.agent = agent
        self.isLocal = isLocal
        items = history
    }

    /// Una sessione ripresa con `--resume`: la CLI manda `init` solo al primo turno,
    /// ma id e cartella sono già noti.
    public init(agent: AgentKind = .claude, isLocal: Bool = false, history: [TranscriptItem] = [],
                resuming sessionID: String, folder: String) {
        self.agent = agent
        self.isLocal = isLocal
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
            if json["type"]?.stringValue == "user" {
                // Testo aggiunto dalla CLI, come il riassunto di `/compact`: non l'ha scritto nessuno.
                if json["isSynthetic"] == .bool(true) { return }
                if json["isReplay"] == .bool(true) {
                    // L'eco di un messaggio scritto qui; quello che manca arriva da Remote Control.
                    if let id = json["uuid"]?.stringValue, items.contains(where: { $0.id == id }) {
                        if id == lastQueuedID { queuedTurn = false }
                        return
                    }
                    if status != .waiting { status = .working }
                }
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
        case .controlResponse(let id, let payload):
            guard let request = remoteControlRequest, request.id == id else { break }
            remoteControlRequest = nil
            remoteControl = request.enabling ? payload["session_url"]?.stringValue.map { RemoteControl(url: $0) } : nil
        case .controlFailed(let id, let message):
            guard remoteControlRequest?.id == id else { break }
            remoteControlRequest = nil
            lastError = "Remote Control non è disponibile: \(message)"
        case .controlCancelled(let id):
            answered(id)
        case .bridgeState(let bridge, let detail):
            guard remoteControl != nil else { break }
            switch bridge {
            case "failed", "policy_disabled":
                remoteControl = nil
                lastError = "Remote Control si è interrotto" + (detail.map { ": \($0)" } ?? ".")
            default:
                remoteControl?.isReconnecting = bridge == "reconnecting"
            }
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
            if result.turns == 0, !result.isError, let name = Self.unavailableCommand(result.message) {
                unavailableCommand = name
            }
            if queuedTurn {
                queuedTurn = false
                status = asks.isEmpty ? .working : .waiting
            } else if result.subtype == "error_during_execution" {
                if status != .idle { status = .idle }
            } else {
                status = asks.isEmpty ? .done : .waiting
                if result.isError {
                    lastError = result.message?.nilIfEmpty ?? "Il turno si è chiuso con un errore (\(result.subtype))."
                } else {
                    completedTurns += 1
                }
            }
        case .other:
            break
        }
    }

    public mutating func userSent(_ text: String, id: String = "local-\(UUID().uuidString)", now: Date) {
        if status == .working || status == .waiting {
            queuedTurn = true
            lastQueuedID = id
        }
        items.append(.user(id: id, text: text))
        status = asks.isEmpty ? .working : .waiting
        lastError = nil
        unavailableCommand = nil
        lastActivity = now
    }

    /// Il messaggio non è arrivato a Claude (processo assente o chiuso): niente «al lavoro».
    public mutating func sendFailed(_ error: String, now: Date) {
        queuedTurn = false
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
        queuedTurn = false
        remoteControl = nil
        remoteControlRequest = nil
        streaming = nil
        asks = []
        status = .ended
        lastActivity = now
        guard code != 0 else { return }
        let text = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            lastError = "\(agent.productName) si è chiuso con il codice \(code)."
            return
        }
        let summary = Self.errorSummary(text)
        lastError = summary
        if summary != text { errorDetail = stderr }
    }

    public mutating func remoteControlRequested(_ requestID: String, enabling: Bool) {
        remoteControlRequest = (requestID, enabling)
    }

    /// La CLI in stream-json risponde così ai comandi che esistono solo nel terminale:
    /// un turno senza modello e senza errore, e il comando non è elencato da nessuna parte.
    private static func unavailableCommand(_ text: String?) -> String? {
        guard let text, text.hasPrefix("/"), text.hasSuffix(" isn't available in this environment.") else { return nil }
        let name = text.dropFirst().prefix { $0 != " " }
        return name.isEmpty ? nil : String(name)
    }

    /// Le ultime 3 righe non vuote che non sono righe di uno stack (`at …`): il motivo sta in fondo.
    static func errorSummary(_ text: String) -> String {
        let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("at ") }
        return lines.suffix(3).joined(separator: "\n")
    }

    /// La sessione come la vedono Plancia, menu bar e notch; `nil` finché Claude non ha dato l'id.
    public func snapshot(launchedAt: Date?) -> SessionSnapshot? {
        guard let sessionID else { return nil }
        var s = SessionSnapshot(id: sessionID, agent: agent, cwd: cwd ?? "")
        s.status = status
        s.model = model
        s.isLocalModel = isLocal
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
    /// `/model` è una richiesta di controllo, non un turno: nessun `result` lo chiuderà.
    public mutating func modelChanged(_ model: String) {
        addNote("Modello: \(model)")
    }

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
