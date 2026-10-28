import Foundation

/// Stato di una sessione Codex ricostruito dal suo file rollout.
public struct CodexReducer: TranscriptReducer {
    public private(set) var snapshot: SessionSnapshot
    public private(set) var planLimits: PlanLimits?
    private var lastTotal: TokenTotals?
    private var pending: [String: UsageBucket] = [:]

    public init(transcriptPath: String) {
        let stem = ((transcriptPath as NSString).lastPathComponent as NSString).deletingPathExtension
        // rollout-<data>-<uuid>: l'uuid occupa gli ultimi 36 caratteri.
        let id = stem.count > 36 && stem.hasPrefix("rollout-") ? String(stem.suffix(36)) : stem
        snapshot = SessionSnapshot(id: id, agent: .codex, transcriptPath: transcriptPath)
    }

    /// Provider che servono un modello in locale.
    public static func isLocalProvider(_ provider: String) -> Bool {
        let p = provider.lowercased()
        return p == "oss" || p.hasPrefix("ollama") || p.hasPrefix("lmstudio")
    }

    public mutating func consume(_ line: Data) {
        guard let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let type = obj["type"] as? String,
              let payload = obj["payload"] as? [String: Any] else { return }
        let date = TranscriptDate.parse(obj["timestamp"])
        switch type {
        case "session_meta":
            note(date)
            if let cwd = payload["cwd"] as? String, !cwd.isEmpty { snapshot.cwd = cwd }
            if let branch = (payload["git"] as? [String: Any])?["branch"] as? String { snapshot.gitBranch = branch }
            if let provider = payload["model_provider"] as? String { setProvider(provider) }
            if snapshot.model == nil,
               let model = ((payload["base_instructions"] as? [String: Any])?["provenance"] as? [String: Any])?["model"] as? String {
                snapshot.model = model
            }
        case "turn_context":
            note(date)
            if let cwd = payload["cwd"] as? String, !cwd.isEmpty { snapshot.cwd = cwd }
            if let model = payload["model"] as? String { snapshot.model = model }
        case "response_item":
            consumeItem(payload, date: date)
        case "event_msg":
            consumeEvent(payload, date: date)
        default: break
        }
    }

    public mutating func drainUsage() -> [UsageBucket] {
        defer { pending.removeAll() }
        return Array(pending.values)
    }

    // MARK: - Righe

    private mutating func consumeItem(_ payload: [String: Any], date: Date?) {
        switch payload["type"] as? String {
        case "function_call":
            guard let name = payload["name"] as? String else { return }
            note(date)
            let args = (payload["arguments"] as? String).flatMap {
                (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any]
            } ?? [:]
            let summary = (args["cmd"] as? String) ?? ClaudeReducer.toolSummary(name: name, input: args)
            snapshot.lastText = summary.isEmpty ? name : "\(name): \(summary)"
            snapshot.toolCounts[name, default: 0] += 1
            snapshot.status = .working
            addUsage(date: date, tokens: .zero, tool: name)
        case "message":
            guard payload["role"] as? String == "assistant" else { return }
            note(date)
            let texts = (payload["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }
            if let text = texts.last(where: { !$0.isEmpty }) { snapshot.lastText = text }
        default: break
        }
    }

    private mutating func consumeEvent(_ payload: [String: Any], date: Date?) {
        switch payload["type"] as? String {
        case "task_started":
            note(date)
            snapshot.status = .working
            if let window = (payload["model_context_window"] as? NSNumber)?.intValue { snapshot.contextWindow = window }
        case "task_complete":
            note(date)
            snapshot.status = .done
            if let text = payload["last_agent_message"] as? String, !text.isEmpty { snapshot.lastText = text }
        case "turn_aborted":
            note(date)
            snapshot.status = .idle
        case "thread_settings_applied":
            let settings = payload["thread_settings"] as? [String: Any] ?? [:]
            if let model = settings["model"] as? String { snapshot.model = model }
            if let provider = settings["model_provider_id"] as? String { setProvider(provider) }
        case "token_count":
            if let info = payload["info"] as? [String: Any] { consumeTokenInfo(info, date: date) }
            if let limits = payload["rate_limits"] as? [String: Any] { consumeLimits(limits, date: date) }
        default: break
        }
    }

    private mutating func consumeTokenInfo(_ info: [String: Any], date: Date?) {
        guard let total = info["total_token_usage"] as? [String: Any] else { return }
        note(date)
        let totals = Self.totals(total)
        let previous = lastTotal ?? .zero
        let delta = TokenTotals(input: max(0, totals.input - previous.input),
                                output: max(0, totals.output - previous.output),
                                cacheRead: max(0, totals.cacheRead - previous.cacheRead),
                                cacheWrite: max(0, totals.cacheWrite - previous.cacheWrite))
        lastTotal = totals
        snapshot.tokens = totals
        addUsage(date: date, tokens: delta, tool: nil)
        if let last = info["last_token_usage"] as? [String: Any] {
            snapshot.contextTokens = Self.int(last["input_tokens"])
        }
        if let window = (info["model_context_window"] as? NSNumber)?.intValue { snapshot.contextWindow = window }
    }

    private mutating func consumeLimits(_ limits: [String: Any], date: Date?) {
        var fiveHour: LimitWindow?, weekly: LimitWindow?
        for (key, fallbackWeekly) in [("primary", false), ("secondary", true)] {
            guard let raw = limits[key] as? [String: Any],
                  let used = (raw["used_percent"] as? NSNumber)?.doubleValue else { continue }
            let resets = (raw["resets_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
            let window = LimitWindow(usedPercent: used, resetsAt: resets)
            switch (raw["window_minutes"] as? NSNumber)?.intValue {
            case 300: fiveHour = window
            case 10080: weekly = window
            default: if fallbackWeekly { weekly = window } else { fiveHour = window }
            }
        }
        guard fiveHour != nil || weekly != nil else { return }
        planLimits = PlanLimits(fiveHour: fiveHour, weekly: weekly, observedAt: date ?? Date())
    }

    // MARK: - Utilità

    private mutating func setProvider(_ provider: String) {
        snapshot.isLocalModel = Self.isLocalProvider(provider)
    }

    private mutating func note(_ date: Date?) {
        guard let date else { return }
        if snapshot.startedAt == nil { snapshot.startedAt = date }
        if (snapshot.lastActivity ?? .distantPast) < date { snapshot.lastActivity = date }
    }

    private mutating func addUsage(date: Date?, tokens: TokenTotals, tool: String?) {
        guard let date, tokens.total > 0 || tool != nil else { return }
        let day = UsageBucket.dayString(date)
        let model = snapshot.model ?? "unknown"
        let key = day + "|" + model
        var bucket = pending[key] ?? UsageBucket(day: day, sessionID: snapshot.id, agent: .codex,
                                                 project: snapshot.cwd, model: model,
                                                 isLocal: snapshot.isLocalModel)
        bucket.tokens += tokens
        if let tool { bucket.toolCounts[tool, default: 0] += 1 }
        pending[key] = bucket
    }

    private static func totals(_ usage: [String: Any]) -> TokenTotals {
        let cached = int(usage["cached_input_tokens"])
        return TokenTotals(input: max(0, int(usage["input_tokens"]) - cached),
                           output: int(usage["output_tokens"]),
                           cacheRead: cached,
                           cacheWrite: int(usage["cache_write_input_tokens"]))
    }

    private static func int(_ value: Any?) -> Int { (value as? NSNumber)?.intValue ?? 0 }
}
