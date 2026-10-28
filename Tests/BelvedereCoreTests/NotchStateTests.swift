import Foundation
import Testing
@testable import BelvedereCore

@Suite struct NotchStateTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func session(_ id: String, _ status: SessionStatus, ago: TimeInterval, cwd: String = "/p/app",
                 pendingAgo: TimeInterval? = nil) -> SessionSnapshot {
        var s = SessionSnapshot(id: id, agent: .claude, cwd: cwd)
        s.status = status
        s.lastActivity = now.addingTimeInterval(-ago)
        s.startedAt = now.addingTimeInterval(-ago - 600)
        s.lastText = "Fatto \(id)"
        if let pendingAgo {
            s.pending = PendingRequest(id: "r-\(id)", kind: .permission, toolName: "Bash", summary: "npm test",
                                       receivedAt: now.addingTimeInterval(-pendingAgo))
        }
        return s
    }

    @Test func noActiveSessionsHides() {
        #expect(NotchStateMachine.next(sessions: [], previous: .hidden, now: now) == .hidden)
        #expect(NotchStateMachine.next(sessions: [session("a", .idle, ago: 9000)], previous: .hidden, now: now) == .hidden)
    }

    @Test func restingCountsActive() {
        let state = NotchStateMachine.next(sessions: [session("a", .done, ago: 120), session("b", .done, ago: 300)],
                                           previous: .hidden, now: now)
        #expect(state == .resting(active: 2))
    }

    @Test func workingShowsMostRecent() {
        let sessions = [session("a", .working, ago: 50, cwd: "/p/old"), session("b", .working, ago: 5, cwd: "/p/new")]
        let state = NotchStateMachine.next(sessions: sessions, previous: .hidden, now: now)
        #expect(state == .working(sessionID: "b", project: "new", since: now.addingTimeInterval(-605)))
    }

    @Test func needsYouWinsAndPicksOldest() {
        let sessions = [session("a", .waiting, ago: 1, pendingAgo: 10), session("b", .waiting, ago: 1, pendingAgo: 60),
                        session("c", .working, ago: 1), session("d", .done, ago: 1)]
        guard case .needsYou(let id, let request) = NotchStateMachine.next(sessions: sessions, previous: .hidden, now: now) else {
            Issue.record("atteso needsYou"); return
        }
        #expect(id == "b")
        #expect(request.id == "r-b")
    }

    @Test func finishedLastsSixSeconds() {
        let sessions = [session("a", .done, ago: 2), session("c", .working, ago: 30)]
        let first = NotchStateMachine.next(sessions: sessions, previous: .working(sessionID: "a", project: "app", since: now), now: now)
        #expect(first == .finished(sessionID: "a", project: "app", summary: "Fatto a", at: now.addingTimeInterval(-2)))
        let later = NotchStateMachine.next(sessions: sessions, previous: first, now: now.addingTimeInterval(3))
        #expect(later == first)
        let expired = NotchStateMachine.next(sessions: sessions, previous: first, now: now.addingTimeInterval(5))
        guard case .working = expired else { Issue.record("atteso working dopo 6 s, ottenuto \(expired)"); return }
    }
}
