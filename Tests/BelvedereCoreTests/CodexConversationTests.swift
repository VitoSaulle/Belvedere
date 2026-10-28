import Foundation
import Testing
@testable import BelvedereCore

@Suite struct CodexConversationTests {
    private let now = Date()

    private static func object(_ data: Data) -> JSONValue {
        JSONValue(any: try! JSONSerialization.jsonObject(with: data))
    }

    private static func message(_ text: String) -> CodexMessage { CodexMessage.decode(Data(text.utf8)) }

    /// Conversazione già pronta: stretta di mano fatta e thread `t1` aperto.
    private func ready(_ options: LaunchOptions = LaunchOptions(folder: "/p", agent: .codex)) -> (CodexConversation, ChatState) {
        var c = CodexConversation(options: options)
        var state = ChatState(agent: .codex)
        _ = c.begin()
        _ = c.receive(Self.message(#"{"id":1,"result":{}}"#), state: &state, now: now)
        _ = c.receive(Self.message(#"{"id":2,"result":{"thread":{"id":"t1"},"model":"qwen","cwd":"/p"}}"#), state: &state, now: now)
        return (c, state)
    }

    @Test func handshakeStartsThreadAfterInitialize() {
        var c = CodexConversation(options: LaunchOptions(folder: "/p", agent: .codex, permission: .plan))
        var state = ChatState(agent: .codex)
        let first = c.begin().map(Self.object)
        #expect(first.map { $0["method"]?.stringValue } == ["initialize"])
        #expect(first[0]["params"]?["clientInfo"]?["name"]?.stringValue == "belvedere")
        let next = c.receive(Self.message(#"{"id":1,"result":{}}"#), state: &state, now: now).map(Self.object)
        #expect(next.map { $0["method"]?.stringValue } == ["initialized", "thread/start"])
        #expect(next[0]["id"] == nil)
        #expect(next[1]["params"]?["sandbox"]?.stringValue == "read-only")
        _ = c.receive(Self.message(#"{"id":2,"result":{"thread":{"id":"t1"},"model":"qwen","cwd":"/p"}}"#), state: &state, now: now)
        #expect(state.sessionID == "t1")
        #expect(state.model == "qwen")
        #expect(c.threadID == "t1")
    }

    /// Scritto prima che il thread esista, il messaggio parte appena il thread è pronto.
    @Test func queuesMessagesUntilThreadStarts() {
        var c = CodexConversation(options: LaunchOptions(folder: "/p", agent: .codex))
        var state = ChatState(agent: .codex)
        _ = c.begin()
        #expect(c.send("ciao").isEmpty)
        _ = c.receive(Self.message(#"{"id":1,"result":{}}"#), state: &state, now: now)
        let out = c.receive(Self.message(#"{"id":2,"result":{"thread":{"id":"t1"}}}"#), state: &state, now: now).map(Self.object)
        #expect(out.count == 1)
        #expect(out[0]["method"]?.stringValue == "turn/start")
        #expect(out[0]["params"]?["threadId"]?.stringValue == "t1")
        #expect(out[0]["params"]?["input"] == .array([.object(["type": .string("text"), "text": .string("ciao"), "text_elements": .array([])])]))
    }

    @Test func resumeUsesThreadResumeAndRestoresHistory() {
        var c = CodexConversation(options: LaunchOptions(folder: "/p", agent: .codex, resumeID: "t9"))
        var state = ChatState(agent: .codex, history: [.user(id: "vecchio", text: "dal file")])
        _ = c.begin()
        let out = c.receive(Self.message(#"{"id":1,"result":{}}"#), state: &state, now: now).map(Self.object)
        #expect(out[1]["method"]?.stringValue == "thread/resume")
        #expect(out[1]["params"]?["threadId"]?.stringValue == "t9")
        let resumed = #"{"id":2,"result":{"thread":{"id":"t9","turns":[{"id":"u","status":"completed","items":[{"type":"userMessage","id":"m0","content":[{"type":"text","text":"ciao"}]},{"type":"agentMessage","id":"m1","text":"salve"}]}]}}}"#
        _ = c.receive(Self.message(resumed), state: &state, now: now)
        #expect(state.items == [.user(id: "m0", text: "ciao"), .assistant(id: "m1", text: "salve")])
        #expect(state.sessionID == "t9")
    }

    @Test func turnLifecycleDrivesStatus() {
        var (c, state) = ready()
        state.userSent("ciao", now: now)
        _ = c.send("ciao")
        _ = c.receive(.turnStarted(turnID: "u1"), state: &state, now: now)
        #expect(state.status == .working)
        _ = c.receive(.itemStarted(Self.object(Data(#"{"type":"agentMessage","id":"m1","text":""}"#.utf8))), state: &state, now: now)
        _ = c.receive(.agentDelta(text: "ci"), state: &state, now: now)
        _ = c.receive(.agentDelta(text: "ao"), state: &state, now: now)
        #expect(state.streaming == "ciao")
        _ = c.receive(.itemCompleted(Self.object(Data(#"{"type":"agentMessage","id":"m1","text":"ciao"}"#.utf8))), state: &state, now: now)
        #expect(state.streaming == nil)
        #expect(state.items.last == .assistant(id: "m1", text: "ciao"))
        _ = c.receive(.turnCompleted(turnID: "u1", status: "completed", error: nil), state: &state, now: now)
        #expect(state.status == .done)
    }

    @Test func interruptSendsTurnAndEndsIdle() {
        var (c, state) = ready()
        _ = c.receive(.turnStarted(turnID: "u1"), state: &state, now: now)
        let out = c.interrupt().map(Self.object)
        #expect(out[0]["method"]?.stringValue == "turn/interrupt")
        #expect(out[0]["params"]?["turnId"]?.stringValue == "u1")
        _ = c.receive(.turnCompleted(turnID: "u1", status: "interrupted", error: nil), state: &state, now: now)
        #expect(state.status == .idle)
        #expect(state.items.contains { if case .note = $0 { true } else { false } })
        #expect(c.interrupt().isEmpty)
    }

    @Test func commandApprovalRoundTrip() throws {
        var (c, state) = ready()
        let request = #"{"method":"item/commandExecution/requestApproval","id":0,"params":{"itemId":"c1","command":"/bin/zsh -c 'touch uno.txt'","cwd":"/p","proposedExecpolicyAmendment":["touch","uno.txt"]}}"#
        _ = c.receive(Self.message(request), state: &state, now: now)
        let ask = try #require(state.asks.first)
        #expect(state.status == .waiting)
        #expect(ask.input["command"]?.stringValue == "touch uno.txt")
        #expect(ask.always?.title == "Sempre per questo comando")
        let reply = c.answer(ask.id, allow: true, always: false).map(Self.object)
        #expect(reply == [.object(["jsonrpc": .string("2.0"), "id": .number(0), "result": .object(["decision": .string("accept")])])])
        #expect(c.answer(ask.id, allow: true, always: false).isEmpty)
    }

    @Test func commandApprovalAlwaysSendsAmendmentAndDenyDeclines() throws {
        var (c, state) = ready()
        _ = c.receive(Self.message(#"{"method":"item/commandExecution/requestApproval","id":5,"params":{"command":"ls","proposedExecpolicyAmendment":["ls"]}}"#), state: &state, now: now)
        _ = c.receive(Self.message(#"{"method":"item/commandExecution/requestApproval","id":6,"params":{"command":"rm x"}}"#), state: &state, now: now)
        #expect(state.asks.count == 2)
        let always = c.answer(state.asks[0].id, allow: true, always: true).map(Self.object)
        #expect(always[0]["result"]?["decision"] == .object(["acceptWithExecpolicyAmendment": .object(["execpolicy_amendment": .array([.string("ls")])])]))
        #expect(state.asks[1].always == nil)
        let deny = c.answer(state.asks[1].id, allow: false, always: false).map(Self.object)
        #expect(deny[0]["id"] == .number(6))
        #expect(deny[0]["result"]?["decision"]?.stringValue == "decline")
    }

    @Test func fileChangeApprovalShowsPathsAndAllowsForSession() throws {
        var (c, state) = ready()
        let item = #"{"type":"fileChange","id":"f1","status":"inProgress","changes":[{"path":"/p/a.txt","kind":{"type":"add"},"diff":"+ciao\n"}]}"#
        _ = c.receive(.itemStarted(Self.object(Data(item.utf8))), state: &state, now: now)
        _ = c.receive(Self.message(#"{"method":"item/fileChange/requestApproval","id":"r2","params":{"itemId":"f1","reason":"scrive fuori"}}"#), state: &state, now: now)
        let ask = try #require(state.asks.first)
        #expect(ask.input["file_path"]?.stringValue == "/p/a.txt")
        #expect(ask.description == "scrive fuori")
        let reply = c.answer(ask.id, allow: true, always: true).map(Self.object)
        #expect(reply[0]["id"]?.stringValue == "r2")
        #expect(reply[0]["result"]?["decision"]?.stringValue == "acceptForSession")
    }

    @Test func questionsAnswerByQuestionID() throws {
        var (c, state) = ready()
        let request = #"{"method":"item/tool/requestUserInput","id":7,"params":{"itemId":"q","questions":[{"id":"colore","header":"Colore","question":"Quale colore?","isOther":false,"isSecret":false,"options":[{"label":"Blu","description":"freddo"},{"label":"Rosso","description":""}]}]}}"#
        _ = c.receive(Self.message(request), state: &state, now: now)
        let ask = try #require(state.asks.first)
        #expect(ask.isQuestion)
        #expect(ask.input["questions"]?.arrayFirst?["question"]?.stringValue == "Quale colore?")
        let reply = c.answer(ask.id, answers: ["Quale colore?": "Blu"]).map(Self.object)
        #expect(reply[0]["result"] == .object(["answers": .object(["colore": .object(["answers": .array([.string("Blu")])])])]))
    }

    @Test func unknownServerRequestGetsErrorAndNote() {
        var (c, state) = ready()
        let out = c.receive(Self.message(#"{"method":"mcpServer/elicitation/request","id":9,"params":{}}"#), state: &state, now: now).map(Self.object)
        #expect(out[0]["error"]?["code"] == .number(-32601))
        #expect(out[0]["id"] == .number(9))
        #expect(state.asks.isEmpty)
        #expect(state.items.contains { if case .note = $0 { true } else { false } })
    }

    @Test func failedTurnShowsErrorAndRetriesAreVisible() {
        var (c, state) = ready()
        _ = c.receive(.turnStarted(turnID: "u1"), state: &state, now: now)
        _ = c.receive(.error(message: "stream disconnected", willRetry: true), state: &state, now: now)
        #expect(state.lastError?.contains("stream disconnected") == true)
        #expect(state.status == .working)
        _ = c.receive(.turnCompleted(turnID: "u1", status: "failed", error: "no model"), state: &state, now: now)
        #expect(state.status == .done)
        #expect(state.lastError == "no model")
    }

    @Test func threadStartFailureIsShown() {
        var c = CodexConversation(options: LaunchOptions(folder: "/p", agent: .codex, resumeID: "t9"))
        var state = ChatState(agent: .codex)
        _ = c.begin()
        _ = c.receive(Self.message(#"{"id":1,"result":{}}"#), state: &state, now: now)
        _ = c.receive(Self.message(#"{"id":2,"error":{"code":-32600,"message":"thread not found"}}"#), state: &state, now: now)
        #expect(state.lastError?.contains("thread not found") == true)
    }

    /// Per i modelli locali la finestra dichiarata da Codex è finta: vale quella di LM Studio.
    @Test func contextWindowPrefersLocalModel() {
        let local = LaunchOptions(folder: "/p", agent: .codex, local: LocalModelChoice(id: "qwen", contextLength: 32768))
        var (c, state) = ready(local)
        _ = c.receive(.tokenUsage(contextTokens: 8993, window: 258400), state: &state, now: now)
        #expect(state.contextTokens == 8993)
        #expect(state.contextWindow == 32768)
        var (cloud, cloudState) = ready()
        _ = cloud.receive(.tokenUsage(contextTokens: 10, window: 258400), state: &cloudState, now: now)
        #expect(cloudState.contextWindow == 258400)
    }

    @Test func modelOverrideGoesWithNextTurn() {
        var (c, state) = ready()
        c.setModel("gpt-5", state: &state)
        #expect(state.model == "gpt-5")
        let out = c.send("ciao").map(Self.object)
        #expect(out[0]["params"]?["model"]?.stringValue == "gpt-5")
        #expect(c.send("ancora").map(Self.object)[0]["params"]?["model"] == nil)
    }

    /// `/clear`: nuovo thread nello stesso processo, la chat riparte vuota.
    @Test func newThreadStartsFresh() {
        var (c, state) = ready()
        state.userSent("ciao", now: now)
        let out = c.newThread(state: &state).map(Self.object)
        #expect(out[0]["method"]?.stringValue == "thread/start")
        #expect(state.items.isEmpty)
        #expect(state.sessionID == nil)
        #expect(c.threadID == nil)
        let id = out[0]["id"]!
        let started = #"{"id":\#(Int(id.numberValue!)),"result":{"thread":{"id":"t2"}}}"#
        _ = c.receive(Self.message(started), state: &state, now: now)
        #expect(state.sessionID == "t2")
    }
}

private extension JSONValue {
    var arrayFirst: JSONValue? {
        if case .array(let a) = self { return a.first }
        return nil
    }
}
