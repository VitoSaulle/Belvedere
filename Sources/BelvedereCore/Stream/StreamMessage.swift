import Foundation

/// Comando disponibile nella sessione, dalla risposta a `initialize`.
public struct SlashCommand: Equatable, Sendable, Codable {
    public let name: String
    public let description: String
    public let argumentHint: String

    public init(name: String, description: String, argumentHint: String) {
        self.name = name
        self.description = description
        self.argumentHint = argumentHint
    }
}

public struct MCPServerInfo: Equatable, Sendable {
    public let name: String
    public let status: String
}

/// Dati di `system/init`: si ripete a ogni turno.
public struct StreamInit: Equatable, Sendable {
    public let sessionID: String
    public let model: String
    public let permissionMode: String
    public let cwd: String
    public let slashCommands: [String]
    public let terminalCommands: [String]
    public let mcpServers: [MCPServerInfo]
}

/// Richiesta `can_use_tool`: un permesso, oppure una domanda se lo strumento è `AskUserQuestion`.
public struct PermissionAsk: Equatable, Sendable, Identifiable {
    public let id: String
    public let toolName: String
    public let toolUseID: String?
    public let input: JSONValue
    public let description: String?
    public let suggestions: [JSONValue]
    /// Approvazione permanente offerta da Codex (per un comando, o per la sessione).
    var codexAlways: AlwaysOption? = nil

    public var isQuestion: Bool { toolName == "AskUserQuestion" }

    /// Il terzo pulsante, se l'agente lo offre: «Sempre in questo progetto» per Claude Code.
    public var always: AlwaysOption? {
        if let codexAlways { return codexAlways }
        guard !alwaysRules.isEmpty else { return nil }
        return AlwaysOption(title: "Sempre in questo progetto",
                            help: "Claude Code aggiunge la regola a .claude/settings.local.json del progetto")
    }

    /// Regole che la CLI salva da sé in `.claude/settings.local.json` («Sempre in questo progetto»).
    public var alwaysRules: [JSONValue] { suggestions.filter { $0["type"]?.stringValue == "addRules" } }

    /// Risposta a una domanda: l'input originale più le risposte per testo della domanda.
    public func answering(_ answers: [String: String]) -> HostDecision {
        var object: [String: JSONValue] = [:]
        if case .object(let o) = input { object = o }
        object["answers"] = .object(answers.mapValues(JSONValue.string))
        return .allow(input: .object(object), rules: [])
    }
}

public struct AlwaysOption: Equatable, Sendable {
    public let title: String
    public let help: String
}

/// Remote Control attivo su questa sessione.
public struct RemoteControl: Equatable, Sendable {
    public let url: String
    public var isReconnecting = false
}

public struct TurnResult: Equatable, Sendable {
    public let isError: Bool
    public let subtype: String
    public let costUSD: Double?
    public let contextTokens: Int?
    public let contextWindow: Int?
    /// Testo del risultato: per un turno in errore è il messaggio della CLI (es. login scaduto).
    public var message: String? = nil
    public var turns: Int? = nil
}

/// Una riga dell'output stream-json di `claude -p`.
public enum StreamMessage: Equatable, Sendable {
    case initialized(StreamInit)
    case commands([SlashCommand])
    /// Righe `assistant` e `user`: hanno lo stesso formato delle trascrizioni.
    case line(json: JSONValue)
    case textDelta(String)
    case permission(PermissionAsk)
    case controlResponse(requestID: String, payload: JSONValue)
    case controlFailed(requestID: String, message: String)
    /// La richiesta è stata risolta altrove (dal telefono, con Remote Control).
    case controlCancelled(requestID: String)
    /// `system/bridge_state`: come va la connessione di Remote Control.
    case bridgeState(state: String, detail: String?)
    case rateLimits(PlanLimits)
    case interrupted
    case result(TurnResult)
    case other

    public static func decode(_ line: Data) -> StreamMessage {
        guard let raw = try? JSONSerialization.jsonObject(with: line), case .object(let o) = JSONValue(any: raw) else {
            return .other
        }
        let json = JSONValue.object(o)
        switch o["type"]?.stringValue {
        case "system":
            switch o["subtype"]?.stringValue {
            case "init": return initialized(json)
            case "bridge_state":
                guard let state = o["state"]?.stringValue else { return .other }
                return .bridgeState(state: state, detail: o["detail"]?.stringValue)
            default: return .other
            }
        case "assistant":
            return .line(json: json)
        case "user":
            if case .array(let blocks)? = json["message"]?["content"],
               blocks.contains(where: { $0["text"]?.stringValue == "[Request interrupted by user]" }) {
                return .interrupted
            }
            return .line(json: json)
        case "stream_event":
            guard let event = json["event"], event["type"]?.stringValue == "content_block_delta",
                  event["delta"]?["type"]?.stringValue == "text_delta",
                  let text = event["delta"]?["text"]?.stringValue else { return .other }
            return .textDelta(text)
        case "control_request":
            guard let id = o["request_id"]?.stringValue, let request = json["request"],
                  request["subtype"]?.stringValue == "can_use_tool",
                  let tool = request["tool_name"]?.stringValue else { return .other }
            var suggestions: [JSONValue] = []
            if case .array(let s)? = request["permission_suggestions"] { suggestions = s }
            return .permission(PermissionAsk(id: id, toolName: tool, toolUseID: request["tool_use_id"]?.stringValue,
                                             input: request["input"] ?? .object([:]),
                                             description: request["description"]?.stringValue,
                                             suggestions: suggestions))
        case "control_response":
            guard let response = json["response"], let id = response["request_id"]?.stringValue else { return .other }
            if response["subtype"]?.stringValue == "error" {
                return .controlFailed(requestID: id, message: response["error"]?.stringValue ?? "")
            }
            let payload = response["response"] ?? .null
            if case .array(let list)? = payload["commands"] {
                return .commands(list.compactMap { c in
                    c["name"]?.stringValue.map {
                        SlashCommand(name: $0, description: c["description"]?.stringValue ?? "",
                                     argumentHint: c["argumentHint"]?.stringValue ?? "")
                    }
                })
            }
            return .controlResponse(requestID: id, payload: payload)
        case "control_cancel_request":
            return o["request_id"]?.stringValue.map { .controlCancelled(requestID: $0) } ?? .other
        case "rate_limit_event":
            return rateLimits(json["rate_limit_info"]?["unifiedWindows"])
        case "result":
            return result(json)
        default:
            return .other
        }
    }

    private static func strings(_ value: JSONValue?) -> [String] {
        guard case .array(let a)? = value else { return [] }
        return a.compactMap(\.stringValue)
    }

    private static func initialized(_ json: JSONValue) -> StreamMessage {
        guard let id = json["session_id"]?.stringValue else { return .other }
        var servers: [MCPServerInfo] = []
        if case .array(let list)? = json["mcp_servers"] {
            servers = list.compactMap { s in
                s["name"]?.stringValue.map { MCPServerInfo(name: $0, status: s["status"]?.stringValue ?? "") }
            }
        }
        return .initialized(StreamInit(sessionID: id, model: json["model"]?.stringValue ?? "",
                                       permissionMode: json["permissionMode"]?.stringValue ?? "",
                                       cwd: json["cwd"]?.stringValue ?? "",
                                       slashCommands: strings(json["slash_commands"]),
                                       terminalCommands: strings(json["terminal_slash_commands"]),
                                       mcpServers: servers))
    }

    private static func rateLimits(_ windows: JSONValue?) -> StreamMessage {
        guard let windows else { return .other }
        func window(_ key: String) -> LimitWindow? {
            guard let w = windows[key], let used = w["utilization"]?.numberValue else { return nil }
            return LimitWindow(usedPercent: (used * 100).rounded(),
                               resetsAt: w["resetsAt"]?.numberValue.map { Date(timeIntervalSince1970: $0) })
        }
        let limits = PlanLimits(fiveHour: window("five_hour"), weekly: window("seven_day"), observedAt: Date())
        return limits.fiveHour == nil && limits.weekly == nil ? .other : .rateLimits(limits)
    }

    private static func result(_ json: JSONValue) -> StreamMessage {
        var contextTokens: Int?
        if case .array(let iterations)? = json["usage"]?["iterations"], let last = iterations.last {
            let parts = ["input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"]
            contextTokens = Int(parts.compactMap { last[$0]?.numberValue }.reduce(0, +))
        }
        var window: Int?
        if case .object(let models)? = json["modelUsage"] {
            window = models.values.compactMap { $0["contextWindow"]?.numberValue }.max().map { Int($0) }
        }
        let isError: Bool
        if case .bool(let b)? = json["is_error"] { isError = b } else { isError = false }
        return .result(TurnResult(isError: isError, subtype: json["subtype"]?.stringValue ?? "",
                                  costUSD: json["total_cost_usd"]?.numberValue,
                                  contextTokens: contextTokens, contextWindow: window,
                                  message: json["result"]?.stringValue,
                                  turns: json["num_turns"]?.numberValue.map { Int($0) }))
    }
}
