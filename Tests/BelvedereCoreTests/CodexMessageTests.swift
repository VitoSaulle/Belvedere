import Foundation
import Testing
@testable import BelvedereCore

@Suite struct CodexMessageTests {
    private var messages: [CodexMessage] { Fixture.lines("codex-app-server.jsonl").map(CodexMessage.decode) }

    private static func json(_ text: String) -> JSONValue {
        JSONValue(any: try! JSONSerialization.jsonObject(with: Data(text.utf8)))
    }

    @Test func decodesResponsesWithTheirID() {
        guard case .response(let id, let result) = messages[0] else { Issue.record("\(messages[0])"); return }
        #expect(id == .number(1))
        #expect(result["codexHome"]?.stringValue == "/Users/u/.codex")
    }

    @Test func decodesTurnLifecycle() {
        #expect(messages.contains(.turnStarted(turnID: "01a1825c-b3e4-7c02-94c8-a140e92dbeac")))
        #expect(messages.contains(.turnCompleted(turnID: "01a1825c-b3e4-7c02-94c8-a140e92dbeac", status: "completed", error: nil)))
        #expect(messages.contains { if case .turnCompleted(_, "interrupted", nil) = $0 { true } else { false } })
    }

    @Test func decodesServerRequestsWithNumericID() {
        let request = messages.first { if case .request = $0 { true } else { false } }
        guard case .request(let id, let method, let params)? = request else { Issue.record("nessuna richiesta"); return }
        #expect(id == .number(0))
        #expect(method == "item/commandExecution/requestApproval")
        #expect(params["command"]?.stringValue == "/bin/zsh -c 'touch uno.txt'")
    }

    @Test func decodesDeltaUsageAndLimits() {
        #expect(messages.contains(.agentDelta(text: "File")))
        #expect(messages.contains(.tokenUsage(contextTokens: 8993, window: 258400)))
        // Limiti vuoti (nessun account cloud): niente da mostrare.
        #expect(!messages.contains { if case .rateLimits = $0 { true } else { false } })
    }

    @Test func decodesRateLimitsWindows() {
        let line = #"{"method":"account/rateLimits/updated","params":{"rateLimits":{"primary":{"usedPercent":12.5,"windowDurationMins":300,"resetsAt":1793200000},"secondary":{"usedPercent":40,"windowDurationMins":10080,"resetsAt":null}}}}"#
        guard case .rateLimits(let limits) = CodexMessage.decode(Data(line.utf8)) else { Issue.record("niente limiti"); return }
        #expect(limits.fiveHour == LimitWindow(usedPercent: 12.5, resetsAt: Date(timeIntervalSince1970: 1793200000)))
        #expect(limits.weekly?.usedPercent == 40)
    }

    @Test func decodesErrorsAndFailedTurns() {
        let error = #"{"method":"error","params":{"error":{"message":"stream disconnected"},"willRetry":true,"threadId":"t","turnId":"u"}}"#
        #expect(CodexMessage.decode(Data(error.utf8)) == .error(message: "stream disconnected", willRetry: true))
        let failed = #"{"method":"turn/completed","params":{"threadId":"t","turn":{"id":"u","status":"failed","error":{"message":"no model"}}}}"#
        #expect(CodexMessage.decode(Data(failed.utf8)) == .turnCompleted(turnID: "u", status: "failed", error: "no model"))
        let rpc = #"{"id":4,"error":{"code":-32600,"message":"thread not found"}}"#
        #expect(CodexMessage.decode(Data(rpc.utf8)) == .failure(id: .number(4), message: "thread not found"))
    }

    // MARK: - Item

    @Test func mapsCommandToTool() {
        let item = Self.json(#"{"type":"commandExecution","id":"c1","command":"/bin/zsh -c 'touch uno.txt'","status":"completed"}"#)
        #expect(CodexItems.item(item, includeUser: false) == .tool(id: "c1", name: "exec_command", detail: "touch uno.txt", added: nil, removed: nil))
    }

    @Test func mapsFileChangeWithLineCounts() {
        let item = Self.json(#"{"type":"fileChange","id":"f1","status":"completed","changes":[{"path":"/tmp/proj/a.txt","kind":{"type":"update","move_path":null},"diff":"@@ -1 +1,2 @@\n-old\n+new\n+more\n"}]}"#)
        #expect(CodexItems.item(item, includeUser: false) == .tool(id: "f1", name: "apply_patch", detail: "/tmp/proj/a.txt", added: 2, removed: 1))
    }

    @Test func mapsMessagesAndSkipsLiveUserEcho() {
        let user = Self.json(#"{"type":"userMessage","id":"u1","content":[{"type":"text","text":"ciao","text_elements":[]}]}"#)
        #expect(CodexItems.item(user, includeUser: false) == nil)
        #expect(CodexItems.item(user, includeUser: true) == .user(id: "u1", text: "ciao"))
        let agent = Self.json(#"{"type":"agentMessage","id":"m1","text":"fatto"}"#)
        #expect(CodexItems.item(agent, includeUser: false) == .assistant(id: "m1", text: "fatto"))
        let mcp = Self.json(#"{"type":"mcpToolCall","id":"x","server":"github","tool":"search","arguments":{"q":"swift"}}"#)
        #expect(CodexItems.item(mcp, includeUser: false)?.id == "x")
        #expect(CodexItems.item(Self.json(#"{"type":"reasoning","id":"r","summary":[],"content":[]}"#), includeUser: false) == nil)
    }

    @Test func historyFromResumeKeepsOrder() {
        guard case .response(_, let result)? = messages.last(where: { if case .response(_, let r) = $0 { r["thread"]?["turns"] != nil } else { false } })
        else { Issue.record("nessuna ripresa"); return }
        let items = CodexItems.history(result["thread"]!)
        #expect(items.first == .user(id: "01a1825c-b41b-7ef0-9869-8dd1bdb416a2", text: "Esegui con la shell il comando: touch uno.txt"))
        #expect(items.contains { if case .tool(_, "exec_command", "touch uno.txt", _, _) = $0 { true } else { false } })
    }
}
