import Foundation
import Testing
@testable import BelvedereCore

@Suite struct HookEventTests {
    private func event(_ name: String, _ extra: String = "") throws -> HookEvent {
        let json = #"{"session_id":"s1","transcript_path":"/t/s1.jsonl","cwd":"/p","permission_mode":"default","hook_event_name":"\#(name)""# + extra + "}"
        return try HookEvent.decode(name: name, body: Data(json.utf8))
    }

    @Test func decodesPreToolUse() throws {
        let e = try event("PreToolUse", #","tool_name":"Bash","tool_use_id":"toolu_1","tool_input":{"command":"npm test"},"belvedere_ppid":4242"#)
        #expect(e.sessionID == "s1")
        #expect(e.cwd == "/p")
        #expect(e.transcriptPath == "/t/s1.jsonl")
        #expect(e.permissionMode == "default")
        #expect(e.toolName == "Bash")
        #expect(e.toolSummary == "npm test")
        #expect(e.callerPID == 4242)
        #expect(e.requestID == "toolu_1")
    }

    @Test func summaryFallsBackToFileAndURL() throws {
        #expect(try event("PreToolUse", #","tool_name":"Edit","tool_input":{"file_path":"/p/a.swift"}"#).toolSummary == "/p/a.swift")
        #expect(try event("PreToolUse", #","tool_name":"WebFetch","tool_input":{"url":"https://x.y"}"#).toolSummary == "https://x.y")
    }

    @Test func rejectsMissingSession() {
        #expect(throws: (any Error).self) { try HookEvent.decode(name: "Stop", body: Data("{}".utf8)) }
        #expect(throws: (any Error).self) { try HookEvent.decode(name: "Stop", body: Data("nope".utf8)) }
    }

    @Test func effectsMap() throws {
        #expect(try event("SessionStart", #","belvedere_ppid":7"#).effects == [.register(cwd: "/p", transcriptPath: "/t/s1.jsonl", pid: 7)])
        for name in ["PreToolUse", "SubagentStart", "PreCompact"] {
            #expect(try event(name).effects == [.status(.working)], "\(name)")
        }
        #expect(try event("UserPromptSubmit").effects == [.clearPending, .status(.working)])
        for name in ["PostToolUse", "PostToolUseFailure"] {
            #expect(try event(name).effects == [.clearTool(key: nil), .status(.working)], "\(name)")
        }
        for name in ["Stop", "StopFailure"] {
            #expect(try event(name).effects == [.clearPending, .status(.done)], "\(name)")
        }
        #expect(try event("SessionEnd").effects == [.ended])
        #expect(try event("Notification", #","notification_type":"permission_prompt""#).effects == [.status(.waiting)])
        #expect(try event("Notification", #","notification_type":"idle_prompt""#).effects == [.status(.idle)])
        #expect(try event("Whatever").effects == [.none])
    }

    /// Il `PermissionRequest` reale non porta `tool_use_id`: lo si accoppia al `PostToolUse` per strumento e input.
    @Test func permissionAndPostToolUseShareToolKey() throws {
        let request = try event("PermissionRequest", #","tool_name":"Bash","tool_input":{"description":"d","command":"touch a"}"#)
        let post = try event("PostToolUse", #","tool_name":"Bash","tool_use_id":"toolu_1","tool_input":{"command":"touch a","description":"d"}"#)
        let other = try event("PostToolUse", #","tool_name":"Bash","tool_use_id":"toolu_2","tool_input":{"command":"touch b"}"#)
        #expect(request.toolKey != nil)
        #expect(request.toolKey == post.toolKey)
        #expect(request.toolKey != other.toolKey)
        guard case .pending(let req) = request.effects.first else { Issue.record("atteso .pending"); return }
        #expect(req.toolKey == request.toolKey)
    }

    @Test func pendingEffects() throws {
        let p = try event("PermissionRequest", #","tool_name":"Bash","tool_use_id":"toolu_9","tool_input":{"command":"rm -rf build"}"#)
        guard case .pending(let req) = p.effects.first else { Issue.record("atteso .pending"); return }
        #expect(req.id == "toolu_9")
        #expect(req.kind == .permission)
        #expect(req.toolName == "Bash")
        #expect(req.summary == "rm -rf build")
        let q = try event("Notification", #","notification_type":"agent_needs_input","message":"Quale branch?""#)
        guard case .pending(let ask) = q.effects.first else { Issue.record("atteso .pending"); return }
        #expect(ask.kind == .question)
        #expect(ask.summary == "Quale branch?")
    }

    @Test func responseBodies() throws {
        let allow = try JSONSerialization.jsonObject(with: HookResponse.body(for: .allow)) as? [String: Any]
        let out = allow?["hookSpecificOutput"] as? [String: Any]
        #expect(out?["hookEventName"] as? String == "PermissionRequest")
        #expect((out?["decision"] as? [String: Any])?["behavior"] as? String == "allow")
        let deny = try JSONSerialization.jsonObject(with: HookResponse.body(for: .deny(reason: "No"))) as? [String: Any]
        let decision = (deny?["hookSpecificOutput"] as? [String: Any])?["decision"] as? [String: Any]
        #expect(decision?["behavior"] as? String == "deny")
        #expect(decision?["message"] as? String == "No")
        #expect(HookResponse.body(for: nil).isEmpty)
    }
}
