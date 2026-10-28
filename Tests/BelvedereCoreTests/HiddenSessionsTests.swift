import Foundation
import Testing
@testable import BelvedereCore

@Suite struct HiddenSessionsTests {
    private func session(_ id: String, _ status: SessionStatus, ago: TimeInterval, now: Date) -> SessionSnapshot {
        var s = SessionSnapshot(id: id, agent: .claude, cwd: "/p")
        s.status = status
        s.lastActivity = now.addingTimeInterval(-ago)
        return s
    }

    @Test func hiddenUntilNewActivity() {
        let now = Date()
        var hidden = HiddenSessions()
        hidden.hide("a", at: now)
        #expect(hidden.isHidden(session("a", .done, ago: 3600, now: now)))
        #expect(!hidden.isHidden(session("a", .working, ago: -60, now: now)))
        #expect(!hidden.isHidden(session("b", .done, ago: 3600, now: now)))
    }

    @Test func unhideShowsAgain() {
        let now = Date()
        var hidden = HiddenSessions()
        hidden.hide("a", at: now)
        hidden.unhide("a")
        #expect(!hidden.isHidden(session("a", .done, ago: 3600, now: now)))
    }

    @Test func staleIDsPickOnlyQuietOldSessions() {
        let now = Date()
        let day: TimeInterval = 86_400
        let sessions = [
            session("old-done", .done, ago: 8 * day, now: now),
            session("old-idle", .idle, ago: 30 * day, now: now),
            session("old-ended", .ended, ago: 9 * day, now: now),
            session("old-working", .working, ago: 8 * day, now: now),
            session("old-waiting", .waiting, ago: 8 * day, now: now),
            session("recent", .done, ago: 2 * day, now: now),
        ]
        #expect(Set(HiddenSessions.staleIDs(sessions, olderThanDays: 7, now: now)) == ["old-done", "old-idle", "old-ended"])
    }

    @Test func roundTripsThroughJSON() throws {
        var hidden = HiddenSessions()
        hidden.hide("a", at: Date(timeIntervalSince1970: 1_000))
        let back = try JSONDecoder().decode(HiddenSessions.self, from: JSONEncoder().encode(hidden))
        #expect(back == hidden)
    }
}
