import Foundation

/// Risposta a una richiesta `can_use_tool`.
public enum HostDecision: Equatable, Sendable {
    /// `rules` non vuote = «Sempre in questo progetto».
    case allow(input: JSONValue, rules: [JSONValue])
    case deny(message: String)
}

/// Righe da scrivere su stdin di `claude -p --input-format stream-json`.
public enum StreamInput {
    /// `id` torna nell'eco della CLI (`--replay-user-messages`): così il messaggio non compare due volte.
    public static func user(_ text: String, images: [ImagePayload] = [], id: String? = nil) -> Data {
        var envelope: [String: Any] = ["type": "user"]
        if let id { envelope["uuid"] = id }
        guard !images.isEmpty else {
            envelope["message"] = ["role": "user", "content": text]
            return line(envelope)
        }
        var blocks: [[String: Any]] = images.map {
            ["type": "image", "source": ["type": "base64", "media_type": $0.mediaType, "data": $0.base64]]
        }
        if !text.isEmpty { blocks.append(["type": "text", "text": text]) }
        envelope["message"] = ["role": "user", "content": blocks]
        return line(envelope)
    }

    public static func initialize(requestID: String) -> Data {
        control(requestID, ["subtype": "initialize"])
    }

    public static func interrupt(requestID: String) -> Data {
        control(requestID, ["subtype": "interrupt"])
    }

    public static func setModel(requestID: String, model: String) -> Data {
        control(requestID, ["subtype": "set_model", "model": model])
    }

    public static func setPermissionMode(requestID: String, mode: String) -> Data {
        control(requestID, ["subtype": "set_permission_mode", "mode": mode])
    }

    public static func remoteControl(requestID: String, enabled: Bool, name: String? = nil) -> Data {
        var request: [String: Any] = ["subtype": "remote_control", "enabled": enabled]
        if let name { request["name"] = name }
        return control(requestID, request)
    }

    public static func decision(_ decision: HostDecision, for requestID: String) -> Data {
        var inner: [String: Any]
        switch decision {
        case .allow(let input, let rules):
            inner = ["behavior": "allow", "updatedInput": input.anyValue]
            if !rules.isEmpty { inner["updatedPermissions"] = rules.map(\.anyValue) }
        case .deny(let message):
            inner = ["behavior": "deny", "message": message]
        }
        return line(["type": "control_response",
                     "response": ["subtype": "success", "request_id": requestID, "response": inner]])
    }

    private static func control(_ id: String, _ request: [String: Any]) -> Data {
        line(["type": "control_request", "request_id": id, "request": request])
    }

    private static func line(_ object: [String: Any]) -> Data {
        var data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        data.append(0x0A)
        return data
    }
}
