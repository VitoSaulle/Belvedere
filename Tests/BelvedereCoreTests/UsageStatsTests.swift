import Foundation
import Testing
@testable import BelvedereCore

@Suite struct UsageStatsTests {
    var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Rome")!
        return c
    }
    var now: Date { calendar.date(from: DateComponents(year: 2026, month: 10, day: 28, hour: 12))! }

    func bucket(_ day: String, _ session: String, _ agent: AgentKind, _ project: String, local: Bool = false,
                input: Int, cacheRead: Int = 0, output: Int = 0, tools: [String: Int] = [:]) -> UsageBucket {
        UsageBucket(day: day, sessionID: session, agent: agent, project: project, model: local ? "qwen" : "m",
                    isLocal: local, tokens: TokenTotals(input: input, output: output, cacheRead: cacheRead),
                    toolCounts: tools)
    }

    var buckets: [UsageBucket] {
        [
            bucket("2026-10-12", "old", .claude, "/a", input: 500),              // periodo precedente (14 giorni)
            bucket("2026-10-26", "c1", .claude, "/a", input: 100, cacheRead: 300, output: 100, tools: ["Bash": 3]),
            bucket("2026-10-27", "c1", .claude, "/a", input: 100, tools: ["Edit": 1, "Bash": 1]),
            bucket("2026-10-27", "x1", .codex, "/b", input: 200, output: 0, tools: ["exec_command": 2]),
            bucket("2026-10-28", "l1", .claude, "/b", local: true, input: 200),
        ]
    }

    func session(_ id: String, _ agent: AgentKind, cost: Double?) -> SessionSnapshot {
        var s = SessionSnapshot(id: id, agent: agent, cwd: "/a")
        s.costUSD = cost
        return s
    }

    @Test func fourteenDaySummary() {
        let sessions = [session("c1", .claude, cost: 2.5), session("old", .claude, cost: 9)]
        let s = UsageStats.summarize(buckets: buckets, sessions: sessions, range: .days14, project: nil, now: now, calendar: calendar)
        #expect(s.totalTokens == 1000)
        #expect(s.previousPeriodTokens == 500)
        #expect(s.sessions == 3)
        #expect(s.sessionsByAgent == [.claude: 2, .codex: 1])
        #expect(s.localSessions == 1)
        #expect(s.costUSD == 2.5)
        #expect(s.localShare == 0.2)
        #expect(s.days.count == 14)
        #expect(s.days.first?.day == "2026-10-15")
        #expect(s.days.last == DayUsage(day: "2026-10-28", claude: 0, codex: 0, local: 200))
        #expect(s.days.first { $0.day == "2026-10-27" } == DayUsage(day: "2026-10-27", claude: 100, codex: 200, local: 0))
        #expect(s.topTools.map(\.name) == ["Bash", "exec_command", "Edit"])
        #expect(s.topTools.first?.count == 4)
    }

    @Test func projectsBreakdown() throws {
        let s = UsageStats.summarize(buckets: buckets, sessions: [], range: .days14, project: nil, now: now, calendar: calendar)
        #expect(s.projects.map(\.project) == ["/a", "/b"])
        let a = try #require(s.projects.first)
        #expect(a.tokens == 600)
        #expect(a.sessions == 1)
        #expect(a.cacheRatio == 0.6)
        #expect(a.claudeShare == 1)
        let b = try #require(s.projects.last)
        #expect(b.codexShare == 0.5)
        #expect(b.localShare == 0.5)
        #expect(b.costUSD == nil)
        #expect(s.costUSD == nil)
    }

    @Test func projectFilterAndToday() {
        let a = UsageStats.summarize(buckets: buckets, sessions: [], range: .days30, project: "/a", now: now, calendar: calendar)
        #expect(a.totalTokens == 1100)
        #expect(a.days.count == 30)
        let today = UsageStats.summarize(buckets: buckets, sessions: [], range: .today, project: nil, now: now, calendar: calendar)
        #expect(today.totalTokens == 200)
        #expect(today.previousPeriodTokens == 300)
        #expect(today.days.map(\.day) == ["2026-10-28"])
    }
}
