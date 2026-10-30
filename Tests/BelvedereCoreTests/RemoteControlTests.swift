import Foundation
import Testing
@testable import BelvedereCore

/// Righe riprese dalla CLI 2.1.312 con `claude -p` in stream-json.
@Suite struct RemoteControlTests {
    private let now = Date()
    private let url = "https://claude.ai/code/session_abc"

    private func decode(_ json: String) -> StreamMessage { StreamMessage.decode(Data(json.utf8)) }

    private func enabled(_ id: String = "rc") -> StreamMessage {
        decode(#"{"type":"control_response","response":{"subtype":"success","request_id":"\#(id)","response":{"session_url":"\#(url)","environment_id":""}}}"#)
    }

    private func bridge(_ state: String, detail: String? = nil) -> StreamMessage {
        let extra = detail.map { #","detail":"\#($0)""# } ?? ""
        return decode(#"{"type":"system","subtype":"bridge_state","state":"\#(state)"\#(extra),"session_id":"s"}"#)
    }

    private func active() -> ChatState {
        var state = ChatState()
        state.remoteControlRequested("rc", enabling: true)
        state.apply(enabled(), now: now)
        return state
    }

    @Test func routesAliasesAndName() {
        #expect(SlashRoute.route("/rc", terminalCommands: []) == .remoteControl(name: nil))
        #expect(SlashRoute.route("/remote-control", terminalCommands: []) == .remoteControl(name: nil))
        #expect(SlashRoute.route("/rc mio telefono", terminalCommands: []) == .remoteControl(name: "mio telefono"))
    }

    @Test func routesPlan() {
        #expect(SlashRoute.route("/plan", terminalCommands: []) == .plan(prompt: nil))
        #expect(SlashRoute.route("/plan rifai il login", terminalCommands: []) == .plan(prompt: "rifai il login"))
    }

    @Test func requestCarriesEnabledAndName() throws {
        let start = try JSONSerialization.jsonObject(with: StreamInput.remoteControl(requestID: "r", enabled: true, name: "x")) as? [String: Any]
        let request = try #require(start?["request"] as? [String: Any])
        #expect(request["subtype"] as? String == "remote_control")
        #expect(request["enabled"] as? Bool == true)
        #expect(request["name"] as? String == "x")
        let stop = try JSONSerialization.jsonObject(with: StreamInput.remoteControl(requestID: "r", enabled: false)) as? [String: Any]
        #expect((stop?["request"] as? [String: Any])?["name"] == nil)
    }

    @Test func enablingShowsTheLink() {
        let state = active()
        #expect(state.remoteControl == RemoteControl(url: url, isReconnecting: false))
    }

    @Test func otherResponsesDoNotEnableIt() {
        var state = ChatState()
        state.remoteControlRequested("rc", enabling: true)
        state.apply(enabled("altra"), now: now)
        #expect(state.remoteControl == nil)
    }

    @Test func disablingClearsTheLink() {
        var state = active()
        state.remoteControlRequested("off", enabling: false)
        state.apply(decode(#"{"type":"control_response","response":{"subtype":"success","request_id":"off"}}"#), now: now)
        #expect(state.remoteControl == nil)
    }

    @Test func refusalIsShownAsAnError() {
        var state = ChatState()
        state.remoteControlRequested("rc", enabling: true)
        state.apply(decode(#"{"type":"control_response","response":{"subtype":"error","request_id":"rc","error":"Disabilitato dall'organizzazione"}}"#), now: now)
        #expect(state.remoteControl == nil)
        #expect(state.lastError?.contains("Disabilitato dall'organizzazione") == true)
    }

    @Test func connectionStatesFollowTheBridge() {
        var state = active()
        state.apply(bridge("reconnecting"), now: now)
        #expect(state.remoteControl?.isReconnecting == true)
        state.apply(bridge("connected"), now: now)
        #expect(state.remoteControl?.isReconnecting == false)
        state.apply(bridge("failed", detail: "sessione scaduta"), now: now)
        #expect(state.remoteControl == nil)
        #expect(state.lastError?.contains("sessione scaduta") == true)
    }

    @Test func bridgeStatesWithoutAnActiveLinkAreIgnored() {
        var state = ChatState()
        state.apply(bridge("connected"), now: now)
        #expect(state.remoteControl == nil)
        #expect(state.lastError == nil)
    }

    @Test func endsWithTheProcess() {
        var state = active()
        state.processExited(code: 0, stderr: "", now: now)
        #expect(state.remoteControl == nil)
    }

    /// Un permesso approvato dal telefono: la CLI ritira la richiesta e la card non deve restare aperta.
    @Test func cancelledRequestClosesTheCard() {
        var state = ChatState()
        state.apply(decode(#"{"type":"control_request","request_id":"p1","request":{"subtype":"can_use_tool","tool_name":"Bash","input":{}}}"#), now: now)
        #expect(state.status == .waiting)
        state.apply(decode(#"{"type":"control_cancel_request","request_id":"p1"}"#), now: now)
        #expect(state.asks.isEmpty)
        #expect(state.status == .working)
    }

    private func echo(_ id: String, _ text: String, extra: String = "") -> StreamMessage {
        decode(#"{"type":"user","uuid":"\#(id)","isReplay":true\#(extra),"message":{"role":"user","content":"\#(text)"}}"#)
    }

    @Test func messageFromThePhoneAppearsInTheChat() {
        var state = ChatState()
        state.apply(echo("u1", "scritto dal telefono"), now: now)
        #expect(state.items == [.user(id: "u1", text: "scritto dal telefono")])
        #expect(state.status == .working)
    }

    @Test func echoOfALocalMessageIsNotDuplicated() {
        var state = ChatState()
        state.userSent("foto.png ciao", id: "u1", now: now)
        state.apply(echo("u1", "ciao"), now: now)
        #expect(state.items == [.user(id: "u1", text: "foto.png ciao")])
    }

    private let turnEnd = #"{"type":"result","subtype":"success","is_error":false,"num_turns":2,"result":"ok"}"#

    /// La CLI può unire il messaggio in coda al turno in corso: arriva un solo `result`.
    @Test func queuedMessageAbsorbedByTheTurnEndsIt() {
        var state = ChatState()
        state.userSent("primo", id: "u1", now: now)
        state.userSent("secondo", id: "u2", now: now)
        state.apply(echo("u1", "primo"), now: now)
        #expect(state.queuedTurn)
        state.apply(echo("u2", "secondo"), now: now)
        state.apply(decode(turnEnd), now: now)
        #expect(state.status == .done)
    }

    /// In coda per il turno dopo: l'eco arriva dopo il `result` e la sessione resta al lavoro.
    @Test func queuedMessageForTheNextTurnKeepsWorking() {
        var state = ChatState()
        state.userSent("primo", id: "u1", now: now)
        state.userSent("secondo", id: "u2", now: now)
        state.apply(echo("u1", "primo"), now: now)
        state.apply(decode(turnEnd), now: now)
        #expect(state.status == .working)
        state.apply(echo("u2", "secondo"), now: now)
        #expect(state.status == .working)
    }

    @Test func phoneMessageDoesNotHideAPermissionCard() {
        var state = ChatState()
        state.apply(decode(#"{"type":"control_request","request_id":"p1","request":{"subtype":"can_use_tool","tool_name":"Bash","input":{}}}"#), now: now)
        state.apply(echo("u1", "intanto questo"), now: now)
        #expect(state.status == .waiting)
    }

    @Test func compactSummaryIsNotAUserMessage() {
        var state = ChatState()
        state.apply(decode(#"{"type":"user","uuid":"u1","isReplay":false,"isSynthetic":true,"message":{"role":"user","content":"This session is being continued"}}"#), now: now)
        #expect(state.items.isEmpty)
    }

    @Test func commandEchoStaysHidden() {
        var state = ChatState()
        state.apply(echo("u1", "<command-name>/compact</command-name>"), now: now)
        #expect(state.items.isEmpty)
    }

    @Test func messageCarriesItsID() throws {
        let object = try JSONSerialization.jsonObject(with: StreamInput.user("ciao", id: "u1")) as? [String: Any]
        #expect(object?["uuid"] as? String == "u1")
    }

    @Test func unavailableCommandOffersTheTerminal() {
        var state = ChatState()
        state.userSent("/hooks", now: now)
        state.apply(decode(#"{"type":"result","subtype":"success","is_error":false,"num_turns":0,"result":"/hooks isn't available in this environment."}"#), now: now)
        #expect(state.unavailableCommand == "hooks")
        state.userSent("ciao", now: now)
        #expect(state.unavailableCommand == nil)
    }

    @Test func ordinaryRepliesAreNotUnavailableCommands() {
        var state = ChatState()
        state.apply(decode(#"{"type":"result","subtype":"success","is_error":false,"num_turns":3,"result":"/hooks isn't available in this environment."}"#), now: now)
        state.apply(decode(#"{"type":"result","subtype":"success","is_error":false,"num_turns":0,"result":"Fatto."}"#), now: now)
        #expect(state.unavailableCommand == nil)
    }
}
