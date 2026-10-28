import Foundation

/// Un elemento della conversazione mostrato nella vista della sessione.
public enum TranscriptItem: Identifiable, Sendable, Equatable {
    case user(id: String, text: String)
    case assistant(id: String, text: String)
    case tool(id: String, name: String, detail: String, added: Int?, removed: Int?)

    public var id: String {
        switch self {
        case .user(let id, _), .assistant(let id, _), .tool(let id, _, _, _, _): id
        }
    }
}

/// Legge la coda di una trascrizione e la trasforma in messaggi leggibili.
public enum TranscriptMessages {
    /// Si leggono solo gli ultimi byte: le trascrizioni possono superare i 100 MB.
    public static let tailBytes = 6 << 20

    public static func load(path: String, agent: AgentKind, limit: Int = 200) throws -> [TranscriptItem] {
        var items: [TranscriptItem] = []
        var seen: Set<String> = []
        for line in try tailLines(path: path) {
            guard let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { continue }
            let parsed = agent == .claude ? claudeItems(obj) : codexItems(obj)
            for item in parsed where seen.insert(item.id).inserted { items.append(item) }
        }
        return Array(items.suffix(limit))
    }

    static func tailLines(path: String) throws -> [Data] {
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        let start = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
        try handle.seek(toOffset: start)
        let data = handle.readDataToEndOfFile()
        var lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)
        // Partendo a metà file la prima riga è troncata.
        if start > 0, !lines.isEmpty { lines.removeFirst() }
        return lines.map { Data($0) }
    }

    // MARK: - Claude

    public static func claudeItems(_ obj: [String: Any]) -> [TranscriptItem] {
        guard obj["isMeta"] as? Bool != true, let message = obj["message"] as? [String: Any] else { return [] }
        switch obj["type"] as? String {
        case "user":
            guard let id = obj["uuid"] as? String else { return [] }
            let text: String?
            if let string = message["content"] as? String {
                text = string
            } else {
                let blocks = message["content"] as? [[String: Any]] ?? []
                text = blocks.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }
                    .joined(separator: "\n").nilIfEmpty
            }
            guard let text = visible(text) else { return [] }
            return [.user(id: id, text: text)]
        case "assistant":
            guard let messageID = message["id"] as? String else { return [] }
            return (message["content"] as? [[String: Any]] ?? []).compactMap { block in
                switch block["type"] as? String {
                case "text":
                    guard let text = visible(block["text"] as? String) else { return nil }
                    return .assistant(id: "\(messageID)#text", text: text)
                case "tool_use":
                    guard let id = block["id"] as? String, let name = block["name"] as? String else { return nil }
                    let input = block["input"] as? [String: Any] ?? [:]
                    var added: Int?, removed: Int?
                    if name == "Edit" {
                        added = ClaudeReducer.lineCount(input["new_string"])
                        removed = ClaudeReducer.lineCount(input["old_string"])
                    } else if name == "Write" {
                        added = ClaudeReducer.lineCount(input["content"])
                    }
                    return .tool(id: id, name: name, detail: ClaudeReducer.toolSummary(name: name, input: input),
                                 added: added, removed: removed)
                default:
                    return nil
                }
            }
        default:
            return []
        }
    }

    // MARK: - Codex

    static func codexItems(_ obj: [String: Any]) -> [TranscriptItem] {
        guard obj["type"] as? String == "response_item", let payload = obj["payload"] as? [String: Any] else { return [] }
        switch payload["type"] as? String {
        case "message":
            let texts = (payload["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }
            guard let text = visible(texts.joined(separator: "\n")) else { return [] }
            let id = payload["id"] as? String ?? "\(text.hashValue)"
            switch payload["role"] as? String {
            case "user": return [.user(id: id, text: text)]
            case "assistant": return [.assistant(id: id, text: text)]
            default: return []
            }
        case "function_call":
            guard let name = payload["name"] as? String else { return [] }
            let args = (payload["arguments"] as? String).flatMap {
                (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any]
            } ?? [:]
            let detail = (args["cmd"] as? String) ?? ClaudeReducer.toolSummary(name: name, input: args)
            let id = payload["call_id"] as? String ?? payload["id"] as? String ?? UUID().uuidString
            return [.tool(id: id, name: name, detail: detail, added: nil, removed: nil)]
        default:
            return []
        }
    }

    /// Esclude testi vuoti e blocchi di sistema (`<command-name>`, `<environment_context>`, …).
    private static func visible(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty,
              !text.hasPrefix("<") else { return nil }
        return text
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
