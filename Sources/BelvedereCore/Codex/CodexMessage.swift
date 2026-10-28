import Foundation

/// Una riga di `codex app-server` (JSON-RPC): risposte, richieste del server e notifiche utili.
public enum CodexMessage: Equatable, Sendable {
    case response(id: JSONValue, result: JSONValue)
    case failure(id: JSONValue, message: String)
    /// Richiesta del server che aspetta una risposta (approvazioni, domande).
    case request(id: JSONValue, method: String, params: JSONValue)
    case turnStarted(turnID: String)
    case turnCompleted(turnID: String, status: String, error: String?)
    case itemStarted(JSONValue)
    case itemCompleted(JSONValue)
    case agentDelta(text: String)
    /// Token dell'ultima richiesta al modello (il contesto occupato) e finestra dichiarata.
    case tokenUsage(contextTokens: Int, window: Int?)
    case rateLimits(PlanLimits)
    case error(message: String, willRetry: Bool)
    case other

    public static func decode(_ line: Data) -> CodexMessage {
        guard let raw = try? JSONSerialization.jsonObject(with: line), case .object(let o) = JSONValue(any: raw) else {
            return .other
        }
        let params = o["params"] ?? .object([:])
        switch (o["id"], o["method"]?.stringValue) {
        case (let id?, let method?):
            return .request(id: id, method: method, params: params)
        case (let id?, nil):
            if let error = o["error"] { return .failure(id: id, message: error["message"]?.stringValue ?? "errore") }
            return .response(id: id, result: o["result"] ?? .null)
        case (nil, let method?):
            return notification(method, params)
        default:
            return .other
        }
    }

    /// Il thread a cui appartiene una notifica o una richiesta del server, se lo dichiara.
    public static func thread(of line: Data) -> String? {
        guard let raw = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let params = raw["params"] as? [String: Any] else { return nil }
        return params["threadId"] as? String
    }

    private static func notification(_ method: String, _ p: JSONValue) -> CodexMessage {
        switch method {
        case "turn/started":
            return p["turn"]?["id"]?.stringValue.map { .turnStarted(turnID: $0) } ?? .other
        case "turn/completed":
            guard let turn = p["turn"], let id = turn["id"]?.stringValue else { return .other }
            return .turnCompleted(turnID: id, status: turn["status"]?.stringValue ?? "completed",
                                  error: turn["error"]?["message"]?.stringValue)
        case "item/started":
            return p["item"].map { .itemStarted($0) } ?? .other
        case "item/completed":
            return p["item"].map { .itemCompleted($0) } ?? .other
        case "item/agentMessage/delta":
            return p["delta"]?.stringValue.map { .agentDelta(text: $0) } ?? .other
        case "thread/tokenUsage/updated":
            guard let usage = p["tokenUsage"], let total = usage["last"]?["totalTokens"]?.numberValue else { return .other }
            return .tokenUsage(contextTokens: Int(total), window: usage["modelContextWindow"]?.numberValue.map { Int($0) })
        case "account/rateLimits/updated":
            return limits(p["rateLimits"]).map { .rateLimits($0) } ?? .other
        case "error":
            return .error(message: p["error"]?["message"]?.stringValue ?? "Errore di Codex",
                          willRetry: p["willRetry"] == .bool(true))
        default:
            return .other
        }
    }

    private static func limits(_ raw: JSONValue?) -> PlanLimits? {
        var fiveHour: LimitWindow?, weekly: LimitWindow?
        for (key, fallbackWeekly) in [("primary", false), ("secondary", true)] {
            guard let w = raw?[key], let used = w["usedPercent"]?.numberValue else { continue }
            let window = LimitWindow(usedPercent: used, resetsAt: w["resetsAt"]?.numberValue.map { Date(timeIntervalSince1970: $0) })
            switch w["windowDurationMins"]?.numberValue {
            case 300: fiveHour = window
            case 10080: weekly = window
            default: if fallbackWeekly { weekly = window } else { fiveHour = window }
            }
        }
        guard fiveHour != nil || weekly != nil else { return nil }
        return PlanLimits(fiveHour: fiveHour, weekly: weekly, observedAt: Date())
    }
}

/// Item dei thread di Codex → messaggi della chat, con gli stessi nomi degli strumenti dei file di sessione.
public enum CodexItems {
    /// `includeUser` solo per la storia: dal vivo il messaggio dell'utente è già nella chat.
    public static func item(_ item: JSONValue, includeUser: Bool) -> TranscriptItem? {
        guard let id = item["id"]?.stringValue else { return nil }
        switch item["type"]?.stringValue {
        case "userMessage":
            guard includeUser, case .array(let content)? = item["content"] else { return nil }
            let text = content.compactMap { $0["text"]?.stringValue }.joined(separator: "\n")
            return text.isEmpty ? nil : .user(id: id, text: text)
        case "agentMessage":
            guard let text = item["text"]?.stringValue, !text.isEmpty else { return nil }
            return .assistant(id: id, text: text)
        case "commandExecution":
            return .tool(id: id, name: "exec_command", detail: shellCommand(item["command"]?.stringValue ?? ""),
                         added: nil, removed: nil)
        case "fileChange":
            guard case .array(let changes)? = item["changes"] else { return nil }
            var added = 0, removed = 0
            for change in changes {
                for line in (change["diff"]?.stringValue ?? "").split(separator: "\n") {
                    if line.hasPrefix("+") && !line.hasPrefix("+++") { added += 1 }
                    if line.hasPrefix("-") && !line.hasPrefix("---") { removed += 1 }
                }
            }
            let paths = changes.compactMap { $0["path"]?.stringValue }.joined(separator: ", ")
            return .tool(id: id, name: "apply_patch", detail: paths, added: added, removed: removed)
        case "mcpToolCall":
            let server = item["server"]?.stringValue ?? "mcp", tool = item["tool"]?.stringValue ?? "?"
            let args = item["arguments"]?.anyValue as? [String: Any] ?? [:]
            return .tool(id: id, name: "\(server).\(tool)", detail: ClaudeReducer.toolSummary(name: tool, input: args),
                         added: nil, removed: nil)
        case "webSearch":
            return .tool(id: id, name: "web_search", detail: item["query"]?.stringValue ?? "", added: nil, removed: nil)
        default:
            return nil
        }
    }

    /// Tutti i messaggi di un thread ripreso (`thread.turns[].items[]`).
    public static func history(_ thread: JSONValue) -> [TranscriptItem] {
        guard case .array(let turns)? = thread["turns"] else { return [] }
        return turns.flatMap { turn -> [TranscriptItem] in
            guard case .array(let items)? = turn["items"] else { return [] }
            return items.compactMap { item($0, includeUser: true) }
        }
    }

    /// `/bin/zsh -c 'touch uno.txt'` → `touch uno.txt`.
    static func shellCommand(_ command: String) -> String {
        guard let match = command.firstMatch(of: /^\S*\/(?:zsh|bash|sh) -l?c (.+)$/) else { return command }
        let inner = String(match.1)
        if inner.count >= 2, inner.hasPrefix("'"), inner.hasSuffix("'") {
            return String(inner.dropFirst().dropLast()).replacingOccurrences(of: "'\\''", with: "'")
        }
        if inner.count >= 2, inner.hasPrefix("\""), inner.hasSuffix("\"") {
            return String(inner.dropFirst().dropLast())
        }
        return inner
    }
}
