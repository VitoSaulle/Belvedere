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
        #expect(store.planLimits == saved)
        #expect(store.claudeLimits == saved)
    }

    @Test func planLimitsPickNewestAndDropExpired() throws {
        var store = LiveSessionStore()
        let now = Date()
        store.apply(codexLimits: PlanLimits(fiveHour: LimitWindow(usedPercent: 10, resetsAt: now.addingTimeInterval(3600)),
                                            weekly: nil, observedAt: now.addingTimeInterval(-600)))
        #expect(store.planLimits?.fiveHour?.usedPercent == 10)
        let json = #"{"session_id":"s1","rate_limits":{"five_hour":{"used_percentage":62,"resets_at":\#(Int(now.timeIntervalSince1970) - 10)},"seven_day":{"used_percentage":30,"resets_at":\#(Int(now.timeIntervalSince1970) + 86400)}}}"#
        store.apply(try StatusLinePayload.decode(Data(json.utf8), now: now))
        store.tick(now: now)
        let limits = try #require(store.planLimits)
        #expect(limits.fiveHour == nil)
        #expect(limits.weekly?.usedPercent == 30)
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
