import Foundation

/// Un evento ricevuto da un hook di Claude Code.
public struct HookEvent: Sendable {
    public let name: String
    public let sessionID: String
    public let cwd: String?
    public let transcriptPath: String?
    public let permissionMode: String?
    public let toolName: String?
    public let toolSummary: String?
    public let notificationType: String?
    public let message: String?
    public let callerPID: Int32?
    /// Nome dello strumento e input in forma canonica; `nil` se l'evento non riguarda uno strumento.
    public let toolKey: String?
    /// `tool_use_id` se presente, altrimenti un identificativo generato: collega la richiesta alla risposta.
    public let requestID: String
    public let receivedAt: Date

    public enum DecodeError: Error { case notAnObject, missingSessionID }

    public static func decode(name: String, body: Data) throws -> HookEvent {
        guard let obj = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else {
            throw DecodeError.notAnObject
        }
        guard let sessionID = obj["session_id"] as? String, !sessionID.isEmpty else {
            throw DecodeError.missingSessionID
        }
        let input = obj["tool_input"] as? [String: Any] ?? [:]
        let summary = ["command", "file_path", "url"].lazy.compactMap { input[$0] as? String }.first
        return HookEvent(name: name, sessionID: sessionID,
                         cwd: obj["cwd"] as? String,
                         transcriptPath: obj["transcript_path"] as? String,
                         permissionMode: obj["permission_mode"] as? String,
                         toolName: obj["tool_name"] as? String,
                         toolSummary: summary,
                         notificationType: obj["notification_type"] as? String,
                         message: obj["message"] as? String,
                         callerPID: (obj["belvedere_ppid"] as? NSNumber)?.int32Value,
                         toolKey: toolKey(name: obj["tool_name"] as? String, input: obj["tool_input"]),
                         requestID: obj["tool_use_id"] as? String ?? UUID().uuidString,
                         receivedAt: Date())
    }

    private static func toolKey(name: String?, input: Any?) -> String? {
        guard let name else { return nil }
        let data = input.flatMap { try? JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys, .fragmentsAllowed]) }
        return name + "\u{1F}" + String(decoding: data ?? Data(), as: UTF8.self)
    }
}

/// Cosa comporta un evento per lo stato della sessione.
public enum HookEffect: Equatable, Sendable {
    case register(cwd: String?, transcriptPath: String?, pid: Int32?)
    case status(SessionStatus)
    case pending(PendingRequest)
    /// Toglie tutte le richieste della sessione.
    case clearPending
    /// Toglie le domande e le richieste di permesso per questo strumento e input.
    case clearTool(key: String?)
    case ended
    case none
}

extension HookEvent {
    public var effects: [HookEffect] {
        switch name {
        case "SessionStart":
            return [.register(cwd: cwd, transcriptPath: transcriptPath, pid: callerPID)]
        case "UserPromptSubmit":
            // Un nuovo prompt vuol dire che nessun dialogo è più aperto: anche una richiesta
            // negata nel terminale con Esc, che non produce né PostToolUse né Stop, si chiude qui.
            return [.clearPending, .status(.working)]
        case "PreToolUse", "SubagentStart", "PreCompact":
            return [.status(.working)]
        case "PostToolUse", "PostToolUseFailure":
            return [.clearTool(key: toolKey), .status(.working)]
        case "PermissionRequest":
            return [.pending(PendingRequest(id: requestID, kind: .permission, toolName: toolName,
                                            summary: toolSummary ?? toolName ?? "", receivedAt: receivedAt,
                                            toolKey: toolKey))]
        case "Notification":
            switch notificationType {
            case "permission_prompt": return [.status(.waiting)]
            case "idle_prompt": return [.status(.idle)]
            case "agent_needs_input":
                return [.pending(PendingRequest(id: requestID, kind: .question, toolName: nil,
                                                summary: message ?? "", receivedAt: receivedAt))]
            default: return [.none]
            }
        case "Stop", "StopFailure":
            return [.clearPending, .status(.done)]
        case "SessionEnd":
            return [.ended]
        default:
            return [.none]
        }
    }
}

extension HookEvent {
    /// Lo stesso evento con l'id di richiesta di un suo doppione già arrivato.
    public func with(requestID: String) -> HookEvent {
        HookEvent(name: name, sessionID: sessionID, cwd: cwd, transcriptPath: transcriptPath, permissionMode: permissionMode,
                  toolName: toolName, toolSummary: toolSummary, notificationType: notificationType, message: message,
                  callerPID: callerPID, toolKey: toolKey, requestID: requestID, receivedAt: receivedAt)
    }
}

/// Con i hook di Belvedere sia nelle impostazioni globali sia in quelle di un progetto, Claude manda ogni
/// evento due volte, quasi insieme. Il doppione si riconosce dal contenuto: `PermissionRequest` non ha
/// `tool_use_id` e i due id generati sarebbero diversi.
public struct HookDeduplicator: Sendable {
    /// I due hook partono in parallelo: oltre questo intervallo un evento uguale è un evento nuovo.
    public static let window: TimeInterval = 3
    private var recent: [String: (requestID: String, at: Date)] = [:]

    public init() {}

    /// `nil` per un evento nuovo; per un doppione, l'id di richiesta del primo.
    public mutating func duplicate(of event: HookEvent, now: Date) -> String? {
        recent = recent.filter { now.timeIntervalSince($0.value.at) < Self.window }
        let key = [event.name, event.sessionID, event.toolKey ?? "", event.notificationType ?? "", event.message ?? "",
                   event.callerPID.map(String.init) ?? ""].joined(separator: "\u{1F}")
        if let seen = recent[key] { return seen.requestID }
        recent[key] = (event.requestID, now)
        return nil
    }

    /// Richiesta risposta: un evento uguale che arriva dopo è una richiesta nuova (lo stesso comando due volte).
    public mutating func forget(requestID: String) {
        recent = recent.filter { $0.value.requestID != requestID }
    }
}
