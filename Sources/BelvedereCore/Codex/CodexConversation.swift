import Foundation

/// Il dialogo con `codex app-server`: riceve le righe, aggiorna la chat e dice cosa scrivere.
/// Non tocca processi né file, così ogni passaggio si prova con righe registrate.
public struct CodexConversation: Sendable {
    public private(set) var threadID: String?
    public private(set) var turnID: String?
    private let options: LaunchOptions
    private var nextID = 1
    private var pending: [Int: Purpose] = [:]
    /// Messaggi scritti prima che il thread esista.
    private var queued: [String] = []
    /// Modello scelto con `/model`: va con il turno successivo e da lì resta a Codex.
    private var modelOverride: String?
    /// Richieste del server in attesa, per id della card.
    private var requests: [String: ServerRequest] = [:]
    /// Percorsi delle modifiche ai file, per mostrarli nella richiesta di approvazione.
    private var filePaths: [String: String] = [:]

    private enum Purpose: Sendable { case initialize, startThread, resumeThread, turn, interrupt }

    private enum ServerRequest: Sendable {
        case command(id: JSONValue, amendment: JSONValue?)
        case fileChange(id: JSONValue)
        case question(id: JSONValue, ids: [String: String])
    }

    public init(options: LaunchOptions) {
        self.options = options
    }

    // MARK: - Verso Codex

    public mutating func begin() -> [Data] {
        [request("initialize", ["clientInfo": .object(["name": .string("belvedere"), "title": .string("Belvedere"),
                                                        "version": .string("1")]),
                                "capabilities": .null], purpose: .initialize)]
    }

    public mutating func send(_ text: String) -> [Data] {
        guard let threadID else {
            queued.append(text)
            return []
        }
        var params: [String: JSONValue] = [
            "threadId": .string(threadID),
            "input": .array([.object(["type": .string("text"), "text": .string(text), "text_elements": .array([])])]),
        ]
        if let modelOverride { params["model"] = .string(modelOverride) }
        modelOverride = nil
        return [request("turn/start", params, purpose: .turn)]
    }

    public mutating func setModel(_ model: String, state: inout ChatState) {
        modelOverride = model
        state.model = model
    }

    public mutating func interrupt() -> [Data] {
        guard let threadID, let turnID else { return [] }
        return [request("turn/interrupt", ["threadId": .string(threadID), "turnId": .string(turnID)], purpose: .interrupt)]
    }

    /// `/clear`: un thread nuovo nello stesso processo.
    public mutating func newThread(state: inout ChatState) -> [Data] {
        threadID = nil
        turnID = nil
        requests = [:]
        state = ChatState(agent: .codex, isLocal: options.local != nil)
        return [startThread(resuming: nil)]
    }

    public mutating func answer(_ askID: String, allow: Bool, always: Bool) -> [Data] {
        guard let pending = requests.removeValue(forKey: askID) else { return [] }
        switch pending {
        case .command(let id, let amendment):
            let decision: JSONValue
            if !allow {
                decision = .string("decline")
            } else if always, let amendment {
                decision = .object(["acceptWithExecpolicyAmendment": .object(["execpolicy_amendment": amendment])])
            } else {
                decision = .string("accept")
            }
            return [reply(id, .object(["decision": decision]))]
        case .fileChange(let id):
            let decision = !allow ? "decline" : always ? "acceptForSession" : "accept"
            return [reply(id, .object(["decision": .string(decision)]))]
        case .question(let id, _):
            return [reply(id, .object(["answers": .object([:])]))]
        }
    }

    /// Risposte per testo della domanda, come le dà la card; più scelte separate da «, ».
    public mutating func answer(_ askID: String, answers: [String: String]) -> [Data] {
        guard case .question(let id, let ids)? = requests.removeValue(forKey: askID) else { return [] }
        var result: [String: JSONValue] = [:]
        for (question, answer) in answers {
            guard let key = ids[question] else { continue }
            let labels = answer.components(separatedBy: ", ").map(JSONValue.string)
            result[key] = .object(["answers": .array(labels)])
        }
        return [reply(id, .object(["answers": .object(result)]))]
    }

    // MARK: - Da Codex

    public mutating func receive(_ message: CodexMessage, state: inout ChatState, now: Date) -> [Data] {
        switch message {
        case .response(let id, let result):
            return responded(id, result: result, state: &state)
        case .failure(let id, let text):
            let purpose = id.numberValue.flatMap { pending.removeValue(forKey: Int($0)) }
            switch purpose {
            case .startThread, .resumeThread, .initialize:
                state.lastError = "Codex non ha aperto la sessione: \(text)"
                state.status = .ended
            case .turn:
                state.lastError = text
                state.status = state.asks.isEmpty ? .done : .waiting
            case .interrupt, nil:
                break
            }
            state.lastActivity = now
        case .request(let id, let method, let params):
            return serverRequest(id, method: method, params: params, state: &state, now: now)
        case .turnStarted(let id):
            turnID = id
            if state.status != .waiting { state.status = .working }
            state.lastActivity = now
        case .turnCompleted(_, let status, let error):
            turnID = nil
            state.streaming = nil
            state.lastActivity = now
            switch status {
            case "interrupted":
                requests = [:]
                state.asks = []
                state.upsert(.note(id: "interrotto-\(UUID().uuidString)", text: "Interrotto"))
                state.status = .idle
            case "failed":
                state.lastError = error ?? "Il turno di Codex non è riuscito."
                state.status = .done
            default:
                if state.lastError?.hasSuffix(Self.retrySuffix) == true { state.lastError = nil }
                state.status = state.asks.isEmpty ? .done : .waiting
            }
        case .itemStarted(let item):
            if item["type"]?.stringValue == "agentMessage" { state.streaming = state.streaming ?? "" }
            if item["type"]?.stringValue == "fileChange", let id = item["id"]?.stringValue,
               case .array(let changes)? = item["changes"] {
                filePaths[id] = changes.compactMap { $0["path"]?.stringValue }.joined(separator: ", ")
            }
            if let mapped = CodexItems.item(item, includeUser: false), case .tool = mapped { state.upsert(mapped) }
            state.lastActivity = now
        case .itemCompleted(let item):
            if item["type"]?.stringValue == "agentMessage" { state.streaming = nil }
            if let mapped = CodexItems.item(item, includeUser: false) { state.upsert(mapped) }
            state.lastActivity = now
        case .agentDelta(let text):
            state.streaming = (state.streaming ?? "") + text
            if state.status != .waiting { state.status = .working }
            state.lastActivity = now
        case .tokenUsage(let tokens, let window):
            state.contextTokens = tokens
            state.contextWindow = options.local?.contextLength ?? window
        case .rateLimits(let limits):
            state.limits = limits
        case .error(let text, let willRetry):
            state.lastError = willRetry ? text + Self.retrySuffix : text
            state.lastActivity = now
        case .other:
            break
        }
        return []
    }

    static let retrySuffix = " · Codex riprova…"

    private mutating func responded(_ id: JSONValue, result: JSONValue, state: inout ChatState) -> [Data] {
        guard let number = id.numberValue, let purpose = pending.removeValue(forKey: Int(number)) else { return [] }
        switch purpose {
        case .initialize:
            return [notification("initialized"), startThread(resuming: options.resumeID)]
        case .startThread, .resumeThread:
            guard let thread = result["thread"], let id = thread["id"]?.stringValue else { return [] }
            threadID = id
            state.sessionID = id
            state.cwd = result["cwd"]?.stringValue ?? state.cwd ?? options.folder
            state.model = result["model"]?.stringValue ?? state.model
            if purpose == .resumeThread {
                let history = CodexItems.history(thread)
                if !history.isEmpty { state.items = history }
            }
            let waiting = queued
            queued = []
            return waiting.flatMap { send($0) }
        case .turn, .interrupt:
            return []
        }
    }

    private mutating func serverRequest(_ id: JSONValue, method: String, params: JSONValue,
                                        state: inout ChatState, now: Date) -> [Data] {
        let askID = "codex-\(Self.key(id))"
        let ask: PermissionAsk
        switch method {
        case "item/commandExecution/requestApproval":
            let amendment = params["proposedExecpolicyAmendment"].flatMap { $0 == .null ? nil : $0 }
            var input: [String: JSONValue] = ["command": .string(CodexItems.shellCommand(params["command"]?.stringValue ?? ""))]
            if let cwd = params["cwd"] { input["cwd"] = cwd }
            ask = PermissionAsk(id: askID, toolName: "Shell", toolUseID: params["itemId"]?.stringValue, input: .object(input),
                                description: params["reason"]?.stringValue, suggestions: [],
                                codexAlways: amendment == nil ? nil : AlwaysOption(
                                    title: "Sempre per questo comando",
                                    help: "Codex aggiunge il comando alle regole che approva da sé"))
            requests[askID] = .command(id: id, amendment: amendment)
        case "item/fileChange/requestApproval":
            let item = params["itemId"]?.stringValue
            var input: [String: JSONValue] = [:]
            if let paths = item.flatMap({ filePaths[$0] }), !paths.isEmpty { input["file_path"] = .string(paths) }
            ask = PermissionAsk(id: askID, toolName: "Modifica file", toolUseID: item, input: .object(input),
                                description: params["reason"]?.stringValue, suggestions: [],
                                codexAlways: AlwaysOption(title: "Per questa sessione",
                                                          help: "Codex non chiede più per le modifiche ai file in questa sessione"))
            requests[askID] = .fileChange(id: id)
        case "item/tool/requestUserInput":
            guard case .array(let list)? = params["questions"] else { return unsupported(id, method, askID, &state) }
            var ids: [String: String] = [:]
            let questions: [JSONValue] = list.compactMap { q in
                guard let text = q["question"]?.stringValue, let qid = q["id"]?.stringValue else { return nil }
                ids[text] = qid
                var options: [JSONValue] = []
                if case .array(let opts)? = q["options"] {
                    options = opts.map { .object(["label": $0["label"] ?? .string(""), "description": $0["description"] ?? .string("")]) }
                }
                return .object(["question": .string(text), "header": q["header"] ?? .string(""),
                                "options": .array(options), "multiSelect": .bool(false)])
            }
            ask = PermissionAsk(id: askID, toolName: "AskUserQuestion", toolUseID: params["itemId"]?.stringValue,
                                input: .object(["questions": .array(questions)]), description: nil, suggestions: [])
            requests[askID] = .question(id: id, ids: ids)
        default:
            return unsupported(id, method, askID, &state)
        }
        state.asks.removeAll { $0.id == askID }
        state.asks.append(ask)
        state.status = .waiting
        state.lastActivity = now
        return []
    }

    /// Una richiesta senza risposta bloccherebbe Codex: si rifiuta e lo si dice nella chat.
    private func unsupported(_ id: JSONValue, _ method: String, _ askID: String, _ state: inout ChatState) -> [Data] {
        state.upsert(.note(id: "richiesta-\(askID)", text: "Codex ha chiesto «\(method)», che Belvedere non gestisce ancora."))
        return [Self.line(["jsonrpc": .string("2.0"), "id": id,
                           "error": .object(["code": .number(-32601), "message": .string("Non supportato da Belvedere")])])]
    }

    // MARK: - Righe JSON-RPC

    private mutating func startThread(resuming id: String?) -> Data {
        guard case .object(var params) = CodexCommand.threadParams(options) else { return Data() }
        if let id {
            params["threadId"] = .string(id)
            return request("thread/resume", params, purpose: .resumeThread)
        }
        return request("thread/start", params, purpose: .startThread)
    }

    private mutating func request(_ method: String, _ params: [String: JSONValue], purpose: Purpose) -> Data {
        let id = nextID
        nextID += 1
        pending[id] = purpose
        return Self.line(["jsonrpc": .string("2.0"), "id": .number(Double(id)), "method": .string(method),
                          "params": .object(params)])
    }

    private func notification(_ method: String) -> Data {
        Self.line(["jsonrpc": .string("2.0"), "method": .string(method), "params": .object([:])])
    }

    private func reply(_ id: JSONValue, _ result: JSONValue) -> Data {
        Self.line(["jsonrpc": .string("2.0"), "id": id, "result": result])
    }

    private static func key(_ id: JSONValue) -> String {
        if let n = id.numberValue { return String(Int(n)) }
        return id.stringValue ?? "?"
    }

    private static func line(_ object: [String: JSONValue]) -> Data {
        var data = (try? JSONSerialization.data(withJSONObject: JSONValue.object(object).anyValue, options: [.sortedKeys])) ?? Data()
        data.append(0x0A)
        return data
    }
}
