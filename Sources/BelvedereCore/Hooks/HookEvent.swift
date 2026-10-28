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
                         requestID: obj["tool_use_id"] as? String ?? UUID().uuidString,
                         receivedAt: Date())
    }
}

/// Cosa comporta un evento per lo stato della sessione.
public enum HookEffect: Equatable, Sendable {
    case register(cwd: String?, transcriptPath: String?, pid: Int32?)
    case status(SessionStatus)
    case pending(PendingRequest)
    case clearPending
    case ended
    case none
}

extension HookEvent {
    public var effects: [HookEffect] {
        switch name {
        case "SessionStart":
            return [.register(cwd: cwd, transcriptPath: transcriptPath, pid: callerPID)]
        case "UserPromptSubmit", "PreToolUse", "SubagentStart", "PreCompact":
            return [.status(.working)]
        case "PostToolUse", "PostToolUseFailure":
            return [.clearPending, .status(.working)]
        case "PermissionRequest":
            return [.pending(PendingRequest(id: requestID, kind: .permission, toolName: toolName,
                                            summary: toolSummary ?? toolName ?? "", receivedAt: receivedAt))]
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
