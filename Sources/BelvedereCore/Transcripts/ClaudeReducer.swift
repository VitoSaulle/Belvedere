import Foundation

/// Stato di una sessione Claude Code ricostruito dalla sua trascrizione.
public struct ClaudeReducer: TranscriptReducer {
    public private(set) var snapshot: SessionSnapshot
    private var seenMessages = RecentSet()
    private var seenTools = RecentSet()
    private var pending: [String: UsageBucket] = [:]

    public init(transcriptPath: String) {
        let id = ((transcriptPath as NSString).lastPathComponent as NSString).deletingPathExtension
        snapshot = SessionSnapshot(id: id, agent: .claude, transcriptPath: transcriptPath)
        snapshot.contextWindow = ModelInfo.defaultContextWindow
    }

    private static let wanted = ["assistant", "user", "ai-title", "cost-state"]
    private static let markers = wanted.map { Data("\"\($0)\"".utf8) }
    private static let typePrefix = Data(#"{"type":""#.utf8)
    private static let wantedPrefixes = wanted.map { Data(#"{"type":"\#($0)""#.utf8) }

    /// Scarta senza decodificarle le righe che non servono: molte (es. `api-request-blob`)
    /// iniziano con il loro `type`, le altre devono almeno nominare un tipo utile.
    static func isRelevant(_ line: Data) -> Bool {
        if line.starts(with: typePrefix) { return wantedPrefixes.contains { line.starts(with: $0) } }
        return markers.contains { line.range(of: $0) != nil }
    }

    public mutating func consume(_ line: Data) {
        guard Self.isRelevant(line),
              let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let type = obj["type"] as? String else { return }
        switch type {
        case "assistant": consumeAssistant(obj)
        case "user": consumeUser(obj)
        case "ai-title":
            if let title = obj["aiTitle"] as? String, !title.isEmpty { snapshot.title = title }
        case "cost-state":
            if let cost = (obj["totalCostUSD"] as? NSNumber)?.doubleValue { snapshot.costUSD = cost }
        default: break
        }
    }

    public mutating func drainUsage() -> [UsageBucket] {
        defer { pending.removeAll() }
        return Array(pending.values)
    }

    // MARK: - Righe

    private mutating func consumeAssistant(_ obj: [String: Any]) {
        guard let message = obj["message"] as? [String: Any] else { return }
        let date = noteCommon(obj)
        let model = message["model"] as? String
        if let model, model != "<synthetic>" {
            snapshot.model = model
            snapshot.isLocalModel = ModelInfo.isLocal(claudeModel: model)
        }

        if let id = message["id"] as? String, let usage = message["usage"] as? [String: Any],
           seenMessages.insert(id) {
            let tokens = TokenTotals(input: Self.int(usage["input_tokens"]),
                                     output: Self.int(usage["output_tokens"]),
                                     cacheRead: Self.int(usage["cache_read_input_tokens"]),
                                     cacheWrite: Self.int(usage["cache_creation_input_tokens"]))
            snapshot.tokens += tokens
            let context = tokens.input + tokens.cacheRead + tokens.cacheWrite
            snapshot.contextTokens = context
            // Il log non dice la finestra: se il contesto supera quella standard, è la variante da 1M.
            if context > snapshot.contextWindow ?? ModelInfo.defaultContextWindow {
                snapshot.contextWindow = ModelInfo.extendedContextWindow
            }
            addUsage(date: date, tokens: tokens, tool: nil)
        }

        for block in message["content"] as? [[String: Any]] ?? [] {
            switch block["type"] as? String {
            case "text":
                if let text = block["text"] as? String, !text.isEmpty { snapshot.lastText = text }
            case "tool_use":
                consumeToolUse(block, date: date)
            default: break
            }
        }

        switch message["stop_reason"] as? String {
        case "end_turn", "stop_sequence", "max_tokens": snapshot.status = .done
        default: snapshot.status = .working
        }
    }

    private mutating func consumeUser(_ obj: [String: Any]) {
        guard let message = obj["message"] as? [String: Any] else { return }
        _ = noteCommon(obj)
        // I comandi locali (`/context`, `/cost`…) non aprono un turno: nessun assistant chiuderebbe lo stato.
        if let text = message["content"] as? String,
           text.hasPrefix("<command-name>") || text.hasPrefix("<local-command-") { return }
        let blocks = message["content"] as? [[String: Any]] ?? []
        if blocks.contains(where: { ($0["text"] as? String)?.hasPrefix("[Request interrupted by user") == true }) {
            snapshot.status = .idle
            return
        }
        snapshot.status = .working
    }

    private mutating func consumeToolUse(_ block: [String: Any], date: Date?) {
        guard let name = block["name"] as? String else { return }
        let input = block["input"] as? [String: Any] ?? [:]
        let summary = Self.toolSummary(name: name, input: input)
        snapshot.lastText = summary.isEmpty ? name : "\(name): \(summary)"

        if let toolID = block["id"] as? String, !seenTools.insert(toolID) { return }
        snapshot.toolCounts[name, default: 0] += 1
        addUsage(date: date, tokens: .zero, tool: name)
        recordFileChange(name: name, input: input)
    }

    /// Campi comuni: cartella, branch, orari. Restituisce l'orario della riga.
    private mutating func noteCommon(_ obj: [String: Any]) -> Date? {
        // La cartella di avvio: dove `--resume` cerca la sessione e dove gira il suo processo.
        // Le righe successive seguono i `cd` fatti durante la sessione.
        if snapshot.cwd.isEmpty, let cwd = obj["cwd"] as? String, !cwd.isEmpty { snapshot.cwd = cwd }
        if let branch = obj["gitBranch"] as? String, !branch.isEmpty { snapshot.gitBranch = branch }
        let date = TranscriptDate.parse(obj["timestamp"])
        if let date {
            if snapshot.startedAt == nil { snapshot.startedAt = date }
            if (snapshot.lastActivity ?? .distantPast) < date { snapshot.lastActivity = date }
        }
        return date
    }

    private mutating func addUsage(date: Date?, tokens: TokenTotals, tool: String?) {
        guard let date else { return }
        let day = UsageBucket.dayString(date)
        let model = snapshot.model ?? "unknown"
        let key = day + "|" + model
        var bucket = pending[key] ?? UsageBucket(day: day, sessionID: snapshot.id, agent: .claude,
                                                 project: snapshot.cwd, model: model,
                                                 isLocal: snapshot.isLocalModel)
        bucket.tokens += tokens
        if let tool { bucket.toolCounts[tool, default: 0] += 1 }
        pending[key] = bucket
    }

    private mutating func recordFileChange(name: String, input: [String: Any]) {
        guard let path = input["file_path"] as? String else { return }
        var added = 0, removed = 0
        switch name {
        case "Edit":
            added = Self.lineCount(input["new_string"])
            removed = Self.lineCount(input["old_string"])
        case "MultiEdit":
            for edit in input["edits"] as? [[String: Any]] ?? [] {
                added += Self.lineCount(edit["new_string"])
                removed += Self.lineCount(edit["old_string"])
            }
        case "Write":
            added = Self.lineCount(input["content"])
        default:
            return
        }
        if let i = snapshot.filesChanged.firstIndex(where: { $0.path == path }) {
            snapshot.filesChanged[i].added += added
            snapshot.filesChanged[i].removed += removed
        } else {
            snapshot.filesChanged.append(FileChange(path: path, added: added, removed: removed))
        }
    }

    // MARK: - Utilità

    static func toolSummary(name: String, input: [String: Any]) -> String {
        for key in ["command", "file_path", "pattern", "url", "description", "prompt"] {
            if let value = input[key] as? String, !value.isEmpty {
                return value.split(separator: "\n").first.map(String.init) ?? value
            }
        }
        return ""
    }

    static func lineCount(_ value: Any?) -> Int {
        guard let text = value as? String, !text.isEmpty else { return 0 }
        return text.split(separator: "\n", omittingEmptySubsequences: false).count
    }

    private static func int(_ value: Any?) -> Int { (value as? NSNumber)?.intValue ?? 0 }
}
