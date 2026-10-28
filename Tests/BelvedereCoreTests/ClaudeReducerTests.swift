import Foundation
import Testing
@testable import BelvedereCore

@Suite struct ClaudeReducerTests {
    private func reduced(_ lines: [Data]) -> ClaudeReducer {
        var r = ClaudeReducer(transcriptPath: "/tmp/s1.jsonl")
        for line in lines { r.consume(line) }
        return r
    }
    private var all: [Data] { Fixture.lines("claude-sample.jsonl") }

    /// Fuori da un repository Claude Code scrive `gitBranch: "HEAD"`: non è un ramo da mostrare.
    @Test func ignoresHeadAsBranch() {
        let line = Data(#"{"type":"user","sessionId":"s1","cwd":"/p","gitBranch":"HEAD","timestamp":"2026-10-28T10:00:00.000Z","message":{"role":"user","content":"ciao"}}"#.utf8)
        #expect(reduced([line]).snapshot.gitBranch == nil)
    }

    /// Un subagente «fork» comincia con la copia del messaggio della madre che lo ha lanciato:
    /// quei token sono già contati nella madre.
    @Test func forkCopyOfParentMessageIsNotCounted() {
        let lines = [
            #"{"type":"fork-context-ref","agentId":"a1","parentSessionId":"p","parentLastUuid":"u0","contextLength":2}"#,
            #"{"type":"assistant","timestamp":"2026-10-28T10:00:00.000Z","message":{"id":"msg_parent","model":"claude-opus-5-5","usage":{"input_tokens":5,"output_tokens":7,"cache_read_input_tokens":100,"cache_creation_input_tokens":0},"content":[{"type":"tool_use","id":"t1","name":"Agent","input":{}}]}}"#,
            #"{"type":"user","timestamp":"2026-10-28T10:00:01.000Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"Fork started"}]}}"#,
            #"{"type":"assistant","timestamp":"2026-10-28T10:00:02.000Z","message":{"id":"msg_fork","model":"claude-opus-5-5","usage":{"input_tokens":1,"output_tokens":2,"cache_read_input_tokens":10,"cache_creation_input_tokens":0},"content":[{"type":"text","text":"ok"}]}}"#,
        ].map { Data($0.utf8) }
        var r = reduced(lines)
        #expect(r.snapshot.tokens == TokenTotals(input: 1, output: 2, cacheRead: 10, cacheWrite: 0))
        #expect(r.drainUsage().reduce(TokenTotals()) { $0 + $1.tokens } == TokenTotals(input: 1, output: 2, cacheRead: 10, cacheWrite: 0))
    }

    @Test func countsEachMessageOnce() {
        let s = reduced(all).snapshot
        #expect(s.tokens == TokenTotals(input: 18, output: 90, cacheRead: 4500, cacheWrite: 650))
        #expect(s.id == "s1")
        #expect(s.agent == .claude)
    }

    @Test func contextIsLastInputFootprint() {
        let s = reduced(all).snapshot
        #expect(s.contextTokens == 3 + 2000 + 50)
        #expect(s.contextWindow == 200_000)
    }

    @Test func readsTitleCostBranchModel() {
        let s = reduced(all).snapshot
        #expect(s.title == "Export CSV dei report")
        // Token × listino di Opus 5.5, non il `cost-state` della CLI (4,18), che riparte da zero dopo una compattazione.
        #expect(abs((s.costUSD ?? 0) - 0.007972) < 1e-9)
        #expect(s.gitBranch == "feat/csv")
        #expect(s.model == "claude-opus-5-5")
        #expect(s.isLocalModel == false)
        #expect(s.cwd == "/Users/v/proj")
        #expect(s.lastText == "Fatto, export pronto.")
    }

    @Test func toolCountsAndFiles() {
        let s = reduced(all).snapshot
        #expect(s.toolCounts == ["Edit": 1, "Bash": 1])
        #expect(s.filesChanged.map(\.path) == ["/Users/v/proj/Report.java"])
        #expect(s.filesChanged.first?.added == 3)
        #expect(s.filesChanged.first?.removed == 1)
    }

    @Test func statusFromLastLine() {
        let midway = reduced(Array(all.prefix(6))).snapshot
        #expect(midway.status == .working)
        #expect(midway.lastText == "Bash: ./gradlew test")
        #expect(reduced(all).snapshot.status == .done)
    }

    @Test func localCommandDoesNotLeaveTheSessionWorking() {
        let command = Data(#"{"type":"user","message":{"role":"user","content":"<command-name>/context</command-name>\n<command-message>context</command-message>"},"timestamp":"2026-10-28T11:00:00Z"}"#.utf8)
        let output = Data(#"{"type":"user","message":{"role":"user","content":"<local-command-stdout>ok</local-command-stdout>"},"timestamp":"2026-10-28T11:00:01Z"}"#.utf8)
        #expect(reduced(all + [command, output]).snapshot.status == .done)
    }

    @Test func interruptionEndsTheTurn() {
        let line = Data(#"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user for tool use]"}]},"timestamp":"2026-10-28T11:00:00Z"}"#.utf8)
        #expect(reduced(all + [line]).snapshot.status == .idle)
    }

    @Test func cwdIsWhereTheSessionStarted() {
        let moved = Data(#"{"type":"user","cwd":"/Users/v/proj/sub","message":{"role":"user","content":"ancora"},"timestamp":"2026-10-28T11:00:00Z"}"#.utf8)
        #expect(reduced(all + [moved]).snapshot.cwd == "/Users/v/proj")
    }

    @Test func ignoresGarbage() {
        var r = reduced(all)
        let before = r.snapshot
        r.consume(Data("{broken".utf8))
        r.consume(Data(#"{"type":"assistant","message":42}"#.utf8))
        #expect(r.snapshot == before)
    }

    @Test func bucketsByDay() {
        var r = reduced(all)
        let buckets = r.drainUsage().sorted { $0.day < $1.day }
        #expect(buckets.map(\.day) == ["2026-10-27", "2026-10-28"])
        #expect(buckets[0].tokens == TokenTotals(input: 15, output: 50, cacheRead: 2500, cacheWrite: 600))
        #expect(buckets[0].toolCounts == ["Edit": 1, "Bash": 1])
        #expect(buckets[1].tokens == TokenTotals(input: 3, output: 40, cacheRead: 2000, cacheWrite: 50))
        #expect(buckets[0].sessionID == "s1")
        #expect(buckets[0].project == "/Users/v/proj")
        #expect(r.drainUsage().isEmpty)
    }

    @Test func stateSurvivesEncoding() throws {
        var r = reduced(Array(all.prefix(4)))
        _ = r.drainUsage()
        let restored = try JSONDecoder().decode(ClaudeReducer.self, from: JSONEncoder().encode(r))
        var r2 = restored
        for line in all.dropFirst(4) { r2.consume(line) }
        #expect(r2.snapshot.tokens == TokenTotals(input: 18, output: 90, cacheRead: 4500, cacheWrite: 650))
    }

    @Test func largeContextWidensWindow() {
        let line = #"{"type":"assistant","sessionId":"s1","cwd":"/p","timestamp":"2026-10-27T10:00:00.000Z","message":{"id":"big","model":"claude-opus-5-5","stop_reason":"end_turn","content":[],"usage":{"input_tokens":5,"output_tokens":1,"cache_read_input_tokens":340000}}}"#
        var r = reduced(all)
        r.consume(Data(line.utf8))
        #expect(r.snapshot.contextTokens == 340_005)
        #expect(r.snapshot.contextWindow == 1_000_000)
    }

    @Test func localModelDetected() {
        let line = #"{"type":"assistant","sessionId":"s9","cwd":"/p","timestamp":"2026-10-27T10:00:00.000Z","message":{"id":"x","model":"qwen3-coder-30b","stop_reason":"end_turn","content":[],"usage":{"input_tokens":1,"output_tokens":1}}}"#
        var r = ClaudeReducer(transcriptPath: "/tmp/s9.jsonl")
        r.consume(Data(line.utf8))
        #expect(r.snapshot.isLocalModel)
        #expect(ModelInfo.isLocal(claudeModel: "claude-sonnet-5-5") == false)
    }

    @Test func modelDisplayNames() {
        #expect(ModelInfo.displayName("claude-opus-5-5") == "Opus 5.5")
        #expect(ModelInfo.displayName("claude-sonnet-4-5-20250929") == "Sonnet 4.5")
        #expect(ModelInfo.displayName("claude-haiku-5-5") == "Haiku 5.5")
        #expect(ModelInfo.displayName("qwen3-coder-30b") == "qwen3-coder-30b")
    }
}
