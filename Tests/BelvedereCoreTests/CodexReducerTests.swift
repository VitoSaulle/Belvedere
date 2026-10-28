import Foundation
import Testing
@testable import BelvedereCore

@Suite struct CodexReducerTests {
    private let path = "/tmp/rollout-2026-10-27T10-00-00-01a1494b-8ccc-7553-99cb-df33363f95a1.jsonl"
    private var all: [Data] { Fixture.lines("codex-sample.jsonl") }
    private func reduced(_ lines: [Data]) -> CodexReducer {
        var r = CodexReducer(transcriptPath: path)
        for line in lines { r.consume(line) }
        return r
    }

    @Test func idFromFileName() {
        #expect(reduced([]).snapshot.id == "01a1494b-8ccc-7553-99cb-df33363f95a1")
        #expect(reduced([]).snapshot.agent == .codex)
    }

    @Test func tokensAreCumulativeNotSummed() {
        #expect(reduced(all).snapshot.tokens == TokenTotals(input: 2000, output: 150, cacheRead: 1000, cacheWrite: 0))
    }

    @Test func contextFromLastUsage() {
        let s = reduced(all).snapshot
        #expect(s.contextTokens == 500)
        #expect(s.contextWindow == 32768)
    }

    @Test func localProviderDetected() {
        let s = reduced(all).snapshot
        #expect(s.isLocalModel)
        #expect(s.model == "qwen3.8:27b")
        #expect(s.cwd == "/Users/v/app")
        #expect(s.gitBranch == "main")
        #expect(CodexReducer.isLocalProvider("lmstudio-local"))
        #expect(CodexReducer.isLocalProvider("oss"))
        #expect(!CodexReducer.isLocalProvider("openai"))
    }

    @Test func statusFromTaskEvents() {
        #expect(reduced(Array(all.prefix(2))).snapshot.status == .working)
        #expect(reduced(Array(all.prefix(4))).snapshot.lastText == "exec_command: npm test")
        let done = reduced(all).snapshot
        #expect(done.status == .done)
        #expect(done.lastText == "Test verdi.")
        var r = reduced(all)
        r.consume(Data(#"{"timestamp":"2026-10-28T09:00:00.000Z","type":"event_msg","payload":{"type":"turn_aborted","reason":"interrupted"}}"#.utf8))
        #expect(r.snapshot.status == .idle)
    }

    @Test func planLimitsMapping() throws {
        #expect(reduced(Array(all.prefix(7))).planLimits == nil)
        let limits = try #require(reduced(all).planLimits)
        #expect(limits.fiveHour == LimitWindow(usedPercent: 21, resetsAt: Date(timeIntervalSince1970: 1793180000)))
        #expect(limits.weekly?.usedPercent == 40.5)
        #expect(limits.observedAt == TranscriptDate.parse("2026-10-28T08:00:00.000Z"))
    }

    @Test func bucketsUseDeltas() {
        var r = reduced(all)
        let buckets = r.drainUsage().sorted { $0.day < $1.day }
        #expect(buckets.map(\.day) == ["2026-10-27", "2026-10-28"])
        #expect(buckets[0].tokens == TokenTotals(input: 1600, output: 120, cacheRead: 900, cacheWrite: 0))
        #expect(buckets[0].toolCounts == ["exec_command": 1])
        #expect(buckets[0].isLocal)
        #expect(buckets[1].tokens == TokenTotals(input: 400, output: 30, cacheRead: 100, cacheWrite: 0))
        #expect(r.drainUsage().isEmpty)
    }

    @Test func ignoresGarbage() {
        var r = reduced(all)
        let before = r.snapshot
        r.consume(Data("{oops".utf8))
        r.consume(Data(#"{"type":"event_msg","payload":7}"#.utf8))
        r.consume(Data(#"{"type":"event_msg","payload":{"type":"token_count","info":null}}"#.utf8))
        #expect(r.snapshot == before)
    }
}
