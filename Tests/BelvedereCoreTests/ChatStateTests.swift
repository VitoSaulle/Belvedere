import Foundation
import Testing
@testable import BelvedereCore

@Suite struct ChatStateTests {
    private let now = Date()

    private func replay(_ name: String, answering: Bool = true) -> ChatState {
        var state = ChatState()
        for line in Fixture.lines(name) {
            let message = StreamMessage.decode(line)
            state.apply(message, now: now)
            if answering, case .permission(let ask) = message { state.answered(ask.id) }
        }
        return state
    }

    private func ask(_ name: String) throws -> PermissionAsk {
        try #require(Fixture.lines(name).lazy.compactMap { line -> PermissionAsk? in
            if case .permission(let a) = StreamMessage.decode(line) { return a } else { return nil }
        }.first)
    }

    @Test func resumedSessionIsKnownBeforeTheFirstTurn() {
        let state = ChatState(resuming: "abc", folder: "/tmp/progetto")
        let snapshot = state.snapshot(launchedAt: now)
        #expect(snapshot?.id == "abc")
        #expect(snapshot?.cwd == "/tmp/progetto")
    }

    @Test func allowFlowBuildsConversation() {
        let state = replay("stream-allow.jsonl")
        #expect(state.items.contains { if case .tool(_, "Bash", _, _, _) = $0 { true } else { false } })
        #expect(state.items.last == .assistant(id: state.items.last!.id, text: "fatto"))
        #expect(state.status == .done)
        #expect(state.asks.isEmpty)
        #expect((state.costUSD ?? 0) > 0)
        #expect(state.contextWindow == 1_000_000)
        #expect(state.limits?.fiveHour?.usedPercent == 17)
        #expect(state.sessionID != nil)
        #expect(state.model == "claude-haiku-5-5")
        #expect(!state.commands.isEmpty)
    }

    @Test func permissionMakesWaiting() throws {
        var state = ChatState()
        state.apply(.initialized(StreamInit(sessionID: "s1", model: "m", permissionMode: "default", cwd: "/p",
                                            slashCommands: [], terminalCommands: [], mcpServers: [])), now: now)
        state.userSent("ciao", now: now)
        let a = try ask("stream-allow.jsonl")
        state.apply(.permission(a), now: now)
        #expect(state.status == .waiting)
        let pending = try #require(state.snapshot(launchedAt: now)?.pending)
        #expect(pending.kind == .permission)
        #expect(pending.id == a.id)
        #expect(pending.summary == "touch spike-ok")
        state.answered(a.id)
        #expect(state.status == .working)
        #expect(state.snapshot(launchedAt: now)?.pending == nil)
    }

    @Test func questionIsQuestion() throws {
        var state = ChatState()
        state.apply(.initialized(StreamInit(sessionID: "s1", model: "m", permissionMode: "default", cwd: "/p",
                                            slashCommands: [], terminalCommands: [], mcpServers: [])), now: now)
        state.apply(.permission(try ask("stream-ask.jsonl")), now: now)
        let pending = try #require(state.snapshot(launchedAt: now)?.pending)
        #expect(pending.kind == .question)
        #expect(pending.summary == "Preferisci il rosso o il blu?")
    }

    @Test func streamingTextClearsOnAssistantLine() {
        var state = ChatState()
        state.apply(.textDelta("Ciao "), now: now)
        state.apply(.textDelta("mondo"), now: now)
        #expect(state.streaming == "Ciao mondo")
        #expect(state.status == .working)
        let line = #"{"type":"assistant","uuid":"u1","message":{"id":"m1","content":[{"type":"text","text":"Ciao mondo"}]}}"#
        state.apply(StreamMessage.decode(Data(line.utf8)), now: now)
        #expect(state.streaming == nil)
        #expect(state.items.last == .assistant(id: "m1#text", text: "Ciao mondo"))
    }

    @Test func sameMessageIDUpdatesText() {
        var state = ChatState()
        for text in ["Prima parte", "Seconda parte"] {
            let line = #"{"type":"assistant","uuid":"u","message":{"id":"m1","content":[{"type":"text","text":"\#(text)"}]}}"#
            state.apply(StreamMessage.decode(Data(line.utf8)), now: now)
        }
        #expect(state.items == [.assistant(id: "m1#text", text: "Seconda parte")])
    }

    @Test func userMessageWhileWorkingStaysWorking() {
        var state = ChatState()
        state.userSent("primo", now: now)
        state.apply(.textDelta("sto lavorando"), now: now)
        state.userSent("secondo", now: now)
        #expect(state.status == .working)
        #expect(state.items.filter { if case .user = $0 { true } else { false } }.count == 2)
        #expect(state.streaming == "sto lavorando")
    }

    @Test func interruptEndsTurn() {
        var state = ChatState()
        state.userSent("dormi", now: now)
        state.apply(.textDelta("…"), now: now)
        state.apply(.interrupted, now: now)
        state.apply(.result(TurnResult(isError: true, subtype: "error_during_execution", costUSD: nil,
                                       contextTokens: nil, contextWindow: nil)), now: now)
        #expect(state.status == .idle)
        #expect(state.streaming == nil)
        #expect(state.lastError == nil)
    }

    @Test func processExitStopsWorking() throws {
        var state = ChatState()
        state.userSent("ciao", now: now)
        state.apply(.permission(try ask("stream-allow.jsonl")), now: now)
        state.processExited(code: 1, stderr: "Invalid API key · Please run /login\n", now: now)
        #expect(state.status == .ended)
        #expect(state.lastError?.contains("Invalid API key") == true)
        #expect(state.asks.isEmpty)
    }

    @Test func turnErrorShowsTheCLIText() {
        var state = ChatState()
        let line = Data(#"{"type":"result","subtype":"success","is_error":true,"result":"Invalid API key · Please run /login"}"#.utf8)
        state.apply(StreamMessage.decode(line), now: now)
        #expect(state.lastError == "Invalid API key · Please run /login")
    }

    @Test func failedSendDoesNotLookWorking() {
        var state = ChatState()
        state.userSent("ciao", now: now)
        state.sendFailed("Claude Code non trovato.", now: now)
        #expect(state.status == .ended)
        #expect(state.lastError == "Claude Code non trovato.")
    }

    @Test func longStderrKeepsTheLastMeaningfulLines() {
        var state = ChatState()
        let stderr = """
        node:internal/process: warning
        Error: boom
            at foo (/x.js:1:1)
            at bar (/x.js:2:2)
        Riga utile uno
        Riga utile due

        Messaggio finale
        """
        state.processExited(code: 1, stderr: stderr, now: now)
        #expect(state.lastError == "Riga utile uno\nRiga utile due\nMessaggio finale")
        #expect(state.errorDetail == stderr)
    }

    @Test func shortStderrHasNoDetail() {
        var state = ChatState()
        state.processExited(code: 1, stderr: "Invalid API key\n", now: now)
        #expect(state.lastError == "Invalid API key")
        #expect(state.errorDetail == nil)
    }

    /// Un messaggio scritto durante un turno parte subito dopo: niente «conclusa» in mezzo.
    @Test func queuedMessageKeepsWorkingBetweenTurns() {
        var state = ChatState()
        let success = Data(#"{"type":"result","subtype":"success","is_error":false,"result":"ok"}"#.utf8)
        state.userSent("poesia", now: now)
        state.userSent("DUE", now: now)
        state.apply(StreamMessage.decode(success), now: now)
        #expect(state.status == .working)
        state.apply(StreamMessage.decode(success), now: now)
        #expect(state.status == .done)
    }

    /// `/model` è una richiesta di controllo: non apre un turno e non ha un `result` che lo chiuda.
    @Test func modelChangeDuringATurnIsNotAQueuedTurn() {
        var state = ChatState()
        let success = Data(#"{"type":"result","subtype":"success","is_error":false,"result":"ok"}"#.utf8)
        state.userSent("poesia", now: now)
        state.modelChanged("claude-haiku-5-5")
        state.apply(StreamMessage.decode(success), now: now)
        #expect(state.status == .done)
    }

    @Test func modelChangeWhileIdleStaysIdle() {
        var state = ChatState()
        state.modelChanged("claude-haiku-5-5")
        #expect(state.status != .working)
        #expect(state.items.count == 1)
    }

    /// Dopo «Ferma» la CLI esegue comunque i messaggi in coda.
    @Test func queuedMessageRunsAfterInterrupt() {
        var state = ChatState()
        let interrupted = Data(#"{"type":"result","subtype":"error_during_execution","is_error":true}"#.utf8)
        state.userSent("poesia", now: now)
        state.userSent("DUE", now: now)
        state.apply(StreamMessage.decode(interrupted), now: now)
        #expect(state.status == .working)
    }

    @Test func cleanExitHasNoError() {
        var state = ChatState()
        state.processExited(code: 0, stderr: "", now: now)
        #expect(state.status == .ended)
        #expect(state.lastError == nil)
    }

    @Test func slashOutputShowsAsAssistant() {
        let state = replay("stream-mixed.jsonl")
        #expect(state.items.contains { if case .assistant(_, let t) = $0 { t.hasPrefix("## Context Usage") } else { false } })
        #expect(state.items.contains { if case .assistant(_, let t) = $0 { t.contains("Set model to") } else { false } })
        #expect(state.status == .idle)
    }

    @Test func historySeedsItems() {
        let state = ChatState(history: [.user(id: "a", text: "vecchio")])
        #expect(state.items.count == 1)
        #expect(state.status == .idle)
    }
}
