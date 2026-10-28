import Foundation
import Testing
@testable import BelvedereCore

@Suite struct LiveSessionStoreTests {
    private func hook(_ name: String, session: String = "s1", _ extra: String = "") -> HookEvent {
        let json = #"{"session_id":"\#(session)","cwd":"/p","transcript_path":"/t/\#(session).jsonl""# + extra + "}"
        return try! HookEvent.decode(name: name, body: Data(json.utf8))
    }

    private func logSnapshot(_ id: String = "s1", status: SessionStatus, at date: Date = Date()) -> SessionSnapshot {
        var s = SessionSnapshot(id: id, agent: .claude, cwd: "/p", transcriptPath: "/t/\(id).jsonl")
        s.status = status
        s.lastActivity = date
        s.contextTokens = 50_000
        s.contextWindow = 200_000
        return s
    }

    @Test func permissionRequestWaitsUntilPostToolUse() throws {
        var store = LiveSessionStore()
        store.apply(IndexUpdate(changed: [logSnapshot(status: .working)], newBuckets: []))
        store.apply(hook("PermissionRequest", #","tool_name":"Bash","tool_use_id":"t1","tool_input":{"command":"rm -rf x"}"#), origin: nil)
        let waiting = try #require(store.sessions.first)
        #expect(waiting.status == .waiting)
        #expect(waiting.pending?.id == "t1")
        #expect(store.waitingCount == 1)
        let removed = store.apply(hook("PostToolUse", #","tool_name":"Bash","tool_use_id":"t1","tool_input":{"command":"rm -rf x"}"#), origin: nil)
        #expect(store.sessions.first?.status == .working)
        #expect(store.sessions.first?.pending == nil)
        #expect(removed == ["t1"])
    }

    private let bash = #","tool_name":"Bash","tool_input":{"command":"rm -rf x"}"#

    @Test func postToolUseOfAnotherToolKeepsPermission() {
        var store = LiveSessionStore()
        store.apply(hook("PermissionRequest", bash), origin: nil)
        let removed = store.apply(hook("PostToolUse", #","tool_name":"Read","tool_use_id":"r1","tool_input":{"file_path":"/a"}"#), origin: nil)
        #expect(removed.isEmpty)
        #expect(store.sessions.first?.pending?.toolName == "Bash")
        #expect(store.sessions.first?.status == .waiting)
    }

    @Test func twoRequestsInOneSessionAreAnsweredSeparately() throws {
        var store = LiveSessionStore()
        store.apply(hook("PermissionRequest", bash), origin: nil)
        store.apply(hook("PermissionRequest", #","tool_name":"Write","tool_input":{"file_path":"/b"}"#), origin: nil)
        let first = try #require(store.sessions.first?.pending)
        #expect(first.summary == "rm -rf x")
        store.clearPending(requestID: first.id)
        #expect(store.sessions.first?.pending?.summary == "/b")
        #expect(store.sessions.first?.status == .waiting)
    }

    /// Il hook chiuso dal terminale chiude la richiesta: la sessione non aspetta più l'utente.
    @Test func closingLastRequestStopsWaiting() throws {
        var store = LiveSessionStore()
        store.apply(hook("PermissionRequest", bash), origin: nil)
        store.apply(hook("Notification", #","notification_type":"permission_prompt""#), origin: nil)
        let id = try #require(store.sessions.first?.pending?.id)
        store.clearPending(requestID: id)
        #expect(store.sessions.first?.status == .idle)
        #expect(store.waitingCount == 0)
    }

    /// I hook globali girano anche nelle sessioni lanciate da Belvedere: la richiesta arriva già dalla chat.
    @Test func hostedSessionIgnoresHookPermission() {
        var store = LiveSessionStore()
        store.setHosted(["s1"])
        let removed = store.apply(hook("PermissionRequest", bash), origin: nil)
        #expect(removed.isEmpty)
        #expect(store.sessions.first?.pending == nil)
        store.apply(hook("PermissionRequest", session: "s2", bash), origin: nil)
        #expect(store.sessions.first { $0.id == "s2" }?.pending != nil)
    }

    @Test func exitedHostedSessionStaysStopped() {
        var store = LiveSessionStore()
        store.apply(IndexUpdate(changed: [logSnapshot(status: .working)], newBuckets: []))
        var ended = SessionSnapshot(id: "s1", agent: .claude, cwd: "/p")
        ended.status = .ended
        ended.lastActivity = Date().addingTimeInterval(-10)
        store.setHosted([], exited: ["s1"])
        store.apply(hosted: ended)
        #expect(store.sessions.first?.status == .ended)
    }

    @Test func laterHookBeatsAnExitedHostedSession() {
        var store = LiveSessionStore()
        var ended = SessionSnapshot(id: "s1", agent: .claude, cwd: "/p")
        ended.status = .ended
        ended.lastActivity = Date().addingTimeInterval(-10)
        store.setHosted([], exited: ["s1"])
        store.apply(hosted: ended)
        store.apply(hook("PermissionRequest", bash), origin: nil)
        #expect(store.sessions.first?.status == .waiting)
        #expect(store.sessions.first?.pending != nil)
    }

    /// La CLI calcola `total_cost_usd` con i prezzi di Claude anche su un modello locale: non è un costo.
    @Test func localSessionsHaveNoCost() throws {
        var store = LiveSessionStore()
        store.apply(IndexUpdate(changed: [logSnapshot(status: .done)], newBuckets: []))
        var hosted = SessionSnapshot(id: "s1", agent: .claude, cwd: "/p")
        hosted.isLocalModel = true
        hosted.costUSD = 0.06
        hosted.lastActivity = Date()
        store.setHosted(["s1"])
        store.apply(hosted: hosted)
        #expect(try #require(store.sessions.first).costUSD == nil)
        var state = ChatState(isLocal: true)
        state.sessionID = "s2"
        #expect(state.snapshot(launchedAt: nil)?.isLocalModel == true)
    }

    /// Anche una sessione locale vista solo dal log (`cost-state` scritto dalla CLI) non ha un costo.
    @Test func localSessionFromLogHasNoCost() throws {
        var store = LiveSessionStore()
        var log = logSnapshot(status: .done)
        log.isLocalModel = true
        log.costUSD = 0.12
        store.apply(IndexUpdate(changed: [log], newBuckets: []))
        #expect(try #require(store.sessions.first).costUSD == nil)
    }

    @Test func hostedOverlayWins() throws {
        var store = LiveSessionStore()
        var log = logSnapshot(status: .done)
        log.title = "Titolo dal log"
        store.apply(IndexUpdate(changed: [log], newBuckets: []))
        var hosted = SessionSnapshot(id: "s1", agent: .claude, cwd: "/p")
        hosted.status = .waiting
        hosted.pending = PendingRequest(id: "r1", kind: .permission, toolName: "Bash", summary: "ls", receivedAt: Date())
        hosted.origin = SessionOrigin(appName: "Belvedere", bundleID: nil, pid: nil)
        hosted.contextTokens = 1234
        hosted.lastActivity = Date()
        store.setHosted(["s1"])
        store.apply(hosted: hosted)
        store.tick(now: Date())
        let s = try #require(store.sessions.first)
        #expect(s.status == .waiting)
        #expect(s.pending?.id == "r1")
        #expect(s.origin?.appName == "Belvedere")
        #expect(s.contextTokens == 1234)
        #expect(s.title == "Titolo dal log")
        store.setHosted([])
        #expect(store.sessions.first?.status == .done)
        #expect(store.sessions.first?.pending == nil)
    }

    @Test func hostedSessionWithoutLogAppears() {
        var store = LiveSessionStore()
        var hosted = SessionSnapshot(id: "nuova", agent: .claude, cwd: "/p")
        hosted.status = .working
        hosted.lastActivity = Date()
        store.setHosted(["nuova"])
        store.apply(hosted: hosted)
        store.tick(now: Date())
        #expect(store.sessions.map(\.id) == ["nuova"])
    }

    /// Negata nel terminale con Esc: nessun PostToolUse né Stop, il primo evento è il prompt successivo.
    @Test func newPromptClearsRequestDeniedInTerminal() throws {
        var store = LiveSessionStore()
        store.apply(hook("PermissionRequest", bash), origin: nil)
        let id = try #require(store.sessions.first?.pending?.id)
        let removed = store.apply(hook("UserPromptSubmit"), origin: nil)
        #expect(removed == [id])
        #expect(store.sessions.first?.pending == nil)
        #expect(store.sessions.first?.status == .working)
    }

    @Test func orphanPendingExpires() {
        var store = LiveSessionStore()
        store.apply(hook("PermissionRequest", #","tool_use_id":"t1""#), origin: nil)
        #expect(store.waitingCount == 1)
        store.tick(now: Date().addingTimeInterval(11 * 60))
        #expect(store.waitingCount == 0)
        #expect(store.sessions.first?.pending == nil)
    }

    @Test func recentHookBeatsLogs() {
        var store = LiveSessionStore()
        store.apply(hook("Notification", #","notification_type":"permission_prompt""#), origin: nil)
        store.apply(IndexUpdate(changed: [logSnapshot(status: .done)], newBuckets: []))
        #expect(store.sessions.first?.status == .waiting)
        store.tick(now: Date().addingTimeInterval(11 * 60))
        #expect(store.sessions.first?.status != .waiting)
    }

    @Test func staleWorkingBecomesIdle() {
        var store = LiveSessionStore()
        store.apply(hook("UserPromptSubmit"), origin: nil)
        #expect(store.sessions.first?.status == .working)
        store.tick(now: Date().addingTimeInterval(6 * 60))
        #expect(store.sessions.first?.status == .idle)
    }

    @Test func oldDoneBecomesIdle() {
        var store = LiveSessionStore()
        store.apply(IndexUpdate(changed: [logSnapshot(status: .done, at: Date().addingTimeInterval(-31 * 60))], newBuckets: []))
        store.tick(now: Date())
        #expect(store.sessions.first?.status == .idle)
    }

    @Test func hookOnlySessionAppears() throws {
        var store = LiveSessionStore()
        let origin = SessionOrigin(appName: "IntelliJ", bundleID: "com.jetbrains.intellij", pid: 9)
        store.apply(hook("SessionStart", session: "new", #","belvedere_ppid":9"#), origin: origin)
        let s = try #require(store.sessions.first)
        #expect(s.id == "new")
        #expect(s.cwd == "/p")
        #expect(s.origin == origin)
        store.apply(IndexUpdate(changed: [logSnapshot("new", status: .working)], newBuckets: []))
        #expect(store.sessions.count == 1)
        #expect(store.sessions.first?.origin == origin)
    }

    @Test func sessionEndMarksEnded() {
        var store = LiveSessionStore()
        store.apply(IndexUpdate(changed: [logSnapshot(status: .working)], newBuckets: []))
        store.apply(hook("SessionEnd"), origin: nil)
        #expect(store.sessions.first?.status == .ended)
    }

    @Test func statusLineContextWhenNewer() throws {
        var store = LiveSessionStore()
        store.apply(IndexUpdate(changed: [logSnapshot(status: .working, at: Date().addingTimeInterval(-60))], newBuckets: []))
        let payload = try StatusLinePayload.decode(Data(#"{"session_id":"s1","context_window":{"used_percentage":25,"context_window_size":1000000}}"#.utf8), now: Date())
        store.apply(payload)
        #expect(store.sessions.first?.contextWindow == 1_000_000)
        #expect(store.sessions.first?.contextTokens == 250_000)
    }

    /// Il log non dice la finestra: quella vista per lo stesso modello in un'altra sessione vale anche qui,
    /// per esempio per una sessione ripresa in Belvedere prima del suo primo turno.
    @Test func knownModelWindowAppliesBeforeFirstTurn() throws {
        var store = LiveSessionStore()
        var first = logSnapshot("a", status: .done)
        first.model = "claude-haiku-5-5"
        var second = logSnapshot("b", status: .done)
        second.model = "claude-haiku-5-5"
        var other = logSnapshot("c", status: .done)
        other.model = "claude-opus-5-5"
        store.apply(IndexUpdate(changed: [first, second, other], newBuckets: []))
        var hosted = SessionSnapshot(id: "a", agent: .claude, cwd: "/p")
        hosted.model = "claude-haiku-5-5"
        hosted.contextWindow = 1_000_000
        hosted.lastActivity = Date()
        store.setHosted(["a"])
        store.apply(hosted: hosted)
        let byID = Dictionary(uniqueKeysWithValues: store.sessions.map { ($0.id, $0) })
        #expect(byID["b"]?.contextWindow == 1_000_000)
        #expect(byID["c"]?.contextWindow == 200_000)
        #expect(store.knownWindows == ["claude-haiku-5-5": 1_000_000])

        var restored = LiveSessionStore()
        restored.restore(knownWindows: store.knownWindows)
        restored.apply(IndexUpdate(changed: [second], newBuckets: []))
        #expect(restored.sessions.first?.contextWindow == 1_000_000)
    }

    @Test func statusLineTeachesTheModelWindow() throws {
        var store = LiveSessionStore()
        var log = logSnapshot(status: .working, at: Date().addingTimeInterval(-60))
        log.model = "claude-opus-5-5"
        store.apply(IndexUpdate(changed: [log], newBuckets: []))
        store.apply(try StatusLinePayload.decode(Data(#"{"session_id":"s1","model":{"id":"claude-opus-5-5"},"context_window":{"used_percentage":25,"context_window_size":1000000}}"#.utf8), now: Date()))
        #expect(store.knownWindows == ["claude-opus-5-5": 1_000_000])
    }

    /// La variante da 1M ha un suo id (`…[1m]`): non vale per i log del modello da 200k.
    @Test func oneMillionVariantDoesNotWidenPlainLogs() throws {
        var store = LiveSessionStore()
        var log = logSnapshot(status: .done, at: Date().addingTimeInterval(-60))
        log.model = "claude-opus-5-5"
        store.apply(IndexUpdate(changed: [log], newBuckets: []))
        store.apply(try StatusLinePayload.decode(Data(#"{"session_id":"s1","model":{"id":"claude-opus-5-5[1m]"},"context_window":{"context_window_size":1000000}}"#.utf8), now: Date().addingTimeInterval(-120)))
        var other = logSnapshot("s2", status: .done, at: Date())
        other.model = "claude-opus-5-5"
        store.apply(IndexUpdate(changed: [other], newBuckets: []))
        #expect(store.sessions.first { $0.id == "s2" }?.contextWindow == 200_000)
    }

    /// Dopo `/model` la status line parla del modello nuovo, non di quello scritto nel log.
    @Test func statusLineTeachesItsOwnModel() throws {
        var store = LiveSessionStore()
        var log = logSnapshot(status: .working, at: Date().addingTimeInterval(-60))
        log.model = "claude-opus-5-5"
        store.apply(IndexUpdate(changed: [log], newBuckets: []))
        store.apply(try StatusLinePayload.decode(Data(#"{"session_id":"s1","model":{"id":"claude-haiku-5-5"},"context_window":{"context_window_size":1000000}}"#.utf8), now: Date()))
        #expect(store.knownWindows == ["claude-haiku-5-5": 1_000_000])
    }

    /// Lo stesso modello visto con due finestre diverse: non si sa quale valga per un log, resta la stima.
    @Test func conflictingWindowsAreNotApplied() throws {
        var store = LiveSessionStore()
        store.restore(knownWindows: ["claude-opus-5-5": 1_000_000])
        var log = logSnapshot(status: .working, at: Date().addingTimeInterval(-60))
        log.model = "claude-opus-5-5"
        store.apply(IndexUpdate(changed: [log], newBuckets: []))
        store.apply(try StatusLinePayload.decode(Data(#"{"session_id":"s1","model":{"id":"claude-opus-5-5"},"context_window":{"context_window_size":200000}}"#.utf8), now: Date().addingTimeInterval(-120)))
        var other = logSnapshot("s2", status: .done, at: Date())
        other.model = "claude-opus-5-5"
        store.apply(IndexUpdate(changed: [other], newBuckets: []))
        #expect(store.sessions.first { $0.id == "s2" }?.contextWindow == 200_000)
    }

    @Test func sortsWaitingThenWorkingThenRecent() {
        var store = LiveSessionStore()
        let now = Date()
        store.apply(IndexUpdate(changed: [
            logSnapshot("a", status: .done, at: now),
            logSnapshot("b", status: .working, at: now.addingTimeInterval(-30)),
            logSnapshot("c", status: .done, at: now.addingTimeInterval(-20)),
        ], newBuckets: []))
        store.apply(hook("PermissionRequest", session: "c", #","tool_use_id":"t""#), origin: nil)
        #expect(store.sessions.map(\.id) == ["c", "b", "a"])
    }

    @Test func restoredClaudeLimitsAreUsed() {
        var store = LiveSessionStore()
        let now = Date()
        let saved = PlanLimits(fiveHour: LimitWindow(usedPercent: 13, resetsAt: now.addingTimeInterval(3600)),
                               weekly: nil, observedAt: now.addingTimeInterval(-300))
        store.apply(claudeLimits: saved)
        store.tick(now: now)
        #expect(store.planLimits(.claude) == saved)
        #expect(store.claudeLimits == saved)
    }

    /// Claude e Codex sono due piani diversi: i limiti restano separati, anche se quelli di Codex sono più recenti.
    @Test func planLimitsStaySeparateAndDropExpired() throws {
        var store = LiveSessionStore()
        let now = Date()
        store.apply(codexLimits: PlanLimits(fiveHour: LimitWindow(usedPercent: 10, resetsAt: now.addingTimeInterval(3600)),
                                            weekly: nil, observedAt: now))
        #expect(store.planLimits(.claude) == nil)
        #expect(store.planLimits(.codex)?.fiveHour?.usedPercent == 10)
        let json = #"{"session_id":"s1","rate_limits":{"five_hour":{"used_percentage":62,"resets_at":\#(Int(now.timeIntervalSince1970) - 10)},"seven_day":{"used_percentage":30,"resets_at":\#(Int(now.timeIntervalSince1970) + 86400)}}}"#
        store.apply(try StatusLinePayload.decode(Data(json.utf8), now: now.addingTimeInterval(-60)))
        store.tick(now: now)
        let limits = try #require(store.planLimits(.claude))
        #expect(limits.fiveHour == nil)
        #expect(limits.weekly?.usedPercent == 30)
        #expect(store.planLimits(.codex)?.fiveHour?.usedPercent == 10)
    }
}

@Suite struct ActivityFeedTests {
    @Test func transitionsProduceEvents() {
        var a = SessionSnapshot(id: "s1", agent: .claude, cwd: "/p/app")
        a.status = .working
        var b = a
        b.status = .waiting
        b.pending = PendingRequest(id: "t", kind: .permission, toolName: "Bash", summary: "rm -rf x", receivedAt: Date())
        var c = b
        c.status = .done
        c.pending = nil
        let now = Date()
        #expect(ActivityFeed.events(from: [], to: [a], now: now).map(\.text) == ["app · nuova sessione"])
        #expect(ActivityFeed.events(from: [a], to: [b], now: now).map(\.text) == ["app · chiede il permesso: Bash"])
        #expect(ActivityFeed.events(from: [b], to: [c], now: now).map(\.text) == ["app · completata"])
        #expect(ActivityFeed.events(from: [c], to: [c], now: now).isEmpty)
    }
}
