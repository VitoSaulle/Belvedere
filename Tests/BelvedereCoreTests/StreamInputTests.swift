import Foundation
import Testing
@testable import BelvedereCore

@Suite struct StreamInputTests {
    private func object(_ data: Data) throws -> [String: Any] {
        #expect(data.last == 0x0A)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func ask() throws -> PermissionAsk {
        try #require(Fixture.lines("stream-allow.jsonl").lazy.compactMap { line -> PermissionAsk? in
            if case .permission(let a) = StreamMessage.decode(line) { return a } else { return nil }
        }.first)
    }

    @Test func userLine() throws {
        let o = try object(StreamInput.user("ciao"))
        #expect(o["type"] as? String == "user")
        let message = try #require(o["message"] as? [String: Any])
        #expect(message["role"] as? String == "user")
        #expect(message["content"] as? String == "ciao")
    }

    @Test func allowAlwaysCarriesRules() throws {
        let a = try ask()
        let o = try object(StreamInput.decision(.allow(input: a.input, rules: a.alwaysRules), for: "r"))
        #expect(o["type"] as? String == "control_response")
        let response = try #require(o["response"] as? [String: Any])
        #expect(response["subtype"] as? String == "success")
        #expect(response["request_id"] as? String == "r")
        let inner = try #require(response["response"] as? [String: Any])
        #expect(inner["behavior"] as? String == "allow")
        #expect((inner["updatedInput"] as? [String: Any])?["command"] as? String == "touch spike-ok")
        let rules = try #require(inner["updatedPermissions"] as? [[String: Any]])
        #expect(rules.first?["type"] as? String == "addRules")
    }

    @Test func plainAllowHasNoPermissions() throws {
        let a = try ask()
        let o = try object(StreamInput.decision(.allow(input: a.input, rules: []), for: "r"))
        let inner = try #require((o["response"] as? [String: Any])?["response"] as? [String: Any])
        #expect(inner["updatedPermissions"] == nil)
    }

    @Test func denyMessage() throws {
        let o = try object(StreamInput.decision(.deny(message: "Negato da Belvedere"), for: "r"))
        let inner = try #require((o["response"] as? [String: Any])?["response"] as? [String: Any])
        #expect(inner["behavior"] as? String == "deny")
        #expect(inner["message"] as? String == "Negato da Belvedere")
    }

    @Test func answeringAddsAnswers() throws {
        let a = try #require(Fixture.lines("stream-ask.jsonl").lazy.compactMap { line -> PermissionAsk? in
            if case .permission(let a) = StreamMessage.decode(line) { return a } else { return nil }
        }.first)
        guard case .allow(let input, let rules) = a.answering(["Preferisci il rosso o il blu?": "Blu"]) else {
            Issue.record("atteso allow"); return
        }
        #expect(rules.isEmpty)
        #expect(input["answers"]?["Preferisci il rosso o il blu?"]?.stringValue == "Blu")
        #expect(input["questions"] != nil)
    }

    @Test func controlRequests() throws {
        let cases: [(Data, String)] = [
            (StreamInput.initialize(requestID: "a"), "initialize"),
            (StreamInput.interrupt(requestID: "b"), "interrupt"),
            (StreamInput.setModel(requestID: "c", model: "sonnet"), "set_model"),
            (StreamInput.setPermissionMode(requestID: "d", mode: "plan"), "set_permission_mode"),
        ]
        for (data, subtype) in cases {
            let o = try object(data)
            #expect(o["type"] as? String == "control_request")
            #expect(o["request_id"] as? String != nil)
            let request = try #require(o["request"] as? [String: Any])
            #expect(request["subtype"] as? String == subtype)
        }
        let model = try object(StreamInput.setModel(requestID: "c", model: "sonnet"))
        #expect((model["request"] as? [String: Any])?["model"] as? String == "sonnet")
        let mode = try object(StreamInput.setPermissionMode(requestID: "d", mode: "plan"))
        #expect((mode["request"] as? [String: Any])?["mode"] as? String == "plan")
    }
}
