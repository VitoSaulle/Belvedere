import Foundation
import Testing
@testable import BelvedereCore

@Suite struct TranscriptIndexTests {
    let tmp = TempDir()
    var roots: TranscriptRoots {
        TranscriptRoots(claude: tmp.url.appendingPathComponent("claude"), codex: tmp.url.appendingPathComponent("codex"))
    }
    var cacheURL: URL { tmp.url.appendingPathComponent("index.json") }
    private func text(_ name: String) -> String { try! String(contentsOf: Fixture.url(name), encoding: .utf8) }

    private func seed() -> (claude: URL, codex: URL) {
        let c = tmp.file("claude/-Users-v-proj/s1.jsonl", text("claude-sample.jsonl"))
        let x = tmp.file("codex/2026/10/27/rollout-2026-10-27T10-00-00-01a1494b-8ccc-7553-99cb-df33363f95a1.jsonl",
                         text("codex-sample.jsonl"))
        return (c, x)
    }

    @Test func discoversBothAgents() async {
        _ = seed()
        let index = TranscriptIndex(roots: roots, cacheURL: cacheURL)
        let update = await index.refreshAll(progress: nil)
        let sessions = await index.sessions
        #expect(update.changed.count == 2)
        #expect(Set(sessions.map(\.agent)) == [.claude, .codex])
        #expect(await index.latestCodexLimits?.fiveHour?.usedPercent == 21)
        #expect(!(await index.buckets).isEmpty)
    }

    @Test func subagentsCountOnlyInStats() async {
        _ = seed()
        let line = #"{"type":"assistant","sessionId":"s1","cwd":"/Users/v/proj","timestamp":"2026-10-28T09:30:00.000Z","message":{"id":"sub1","model":"claude-haiku-5-5","stop_reason":"end_turn","content":[],"usage":{"input_tokens":7,"output_tokens":3}}}"#
        _ = tmp.file("claude/-Users-v-proj/s1/subagents/agent-a1.jsonl", line + "\n")
        let index = TranscriptIndex(roots: roots, cacheURL: cacheURL)
        _ = await index.refreshAll(progress: nil)
        #expect(await index.sessions.count == 2)
        let sub = await index.buckets.filter { $0.model == "claude-haiku-5-5" }
        #expect(sub.map(\.sessionID) == ["s1"])
        #expect(sub.first?.tokens.input == 7)
    }

    @Test func incrementalAppend() async throws {
        let files = seed()
        let index = TranscriptIndex(roots: roots, cacheURL: cacheURL)
        _ = await index.refreshAll(progress: nil)
        let before = try #require(await index.sessions.first { $0.id == "s1" }).tokens.output
        append(#"{"type":"assistant","sessionId":"s1","cwd":"/Users/v/proj","timestamp":"2026-10-28T09:10:00.000Z","message":{"id":"m9","model":"claude-opus-5-5","stop_reason":"end_turn","content":[{"type":"text","text":"Altro"}],"usage":{"input_tokens":1,"output_tokens":11}}}"# + "\n", to: files.claude)
        let update = await index.refresh(paths: [files.claude.path])
        #expect(update.changed.map(\.id) == ["s1"])
        #expect(update.changed.first?.tokens.output == before + 11)
        #expect(update.newBuckets.map(\.tokens.output) == [11])
    }

    @Test func missingFileEndsSession() async throws {
        let files = seed()
        let index = TranscriptIndex(roots: roots, cacheURL: cacheURL)
        _ = await index.refreshAll(progress: nil)
        try FileManager.default.removeItem(at: files.codex)
        let update = await index.refresh(paths: [files.codex.path])
        #expect(update.changed.map(\.status) == [.ended])
        #expect(await index.sessions.count == 1)
    }

    @Test func cacheRoundTrip() async throws {
        _ = seed()
        let first = TranscriptIndex(roots: roots, cacheURL: cacheURL)
        _ = await first.refreshAll(progress: nil)
        try await first.save()
        let second = TranscriptIndex(roots: roots, cacheURL: cacheURL)
        let update = await second.refreshAll(progress: nil)
        #expect(update.changed.isEmpty)
        #expect(update.newBuckets.isEmpty)
        #expect(await second.sessions == (await first.sessions))
        #expect(await second.buckets.count == (await first.buckets).count)
    }

    @Test func cacheFromOlderReducerIsRebuilt() async throws {
        _ = seed()
        let first = TranscriptIndex(roots: roots, cacheURL: cacheURL)
        _ = await first.refreshAll(progress: nil)
        try await first.save()
        let current = #""version":\#(TranscriptIndex.cacheVersion)"#
        let old = try String(contentsOf: cacheURL, encoding: .utf8).replacingOccurrences(of: current, with: #""version":1"#)
        try old.write(to: cacheURL, atomically: true, encoding: .utf8)
        let second = TranscriptIndex(roots: roots, cacheURL: cacheURL)
        #expect(await second.sessions.isEmpty)
        #expect(TranscriptIndex.cacheVersion > 1)
    }

    @Test func saveSkipsAnUnchangedIndex() async throws {
        _ = seed()
        let index = TranscriptIndex(roots: roots, cacheURL: cacheURL)
        _ = await index.refreshAll(progress: nil)
        try await index.save()
        try FileManager.default.removeItem(at: cacheURL)
        _ = await index.refreshAll(progress: nil)
        try await index.save()
        #expect(!FileManager.default.fileExists(atPath: cacheURL.path))
    }

    @Test func cacheIsReadWhenFirstNeeded() async throws {
        _ = seed()
        let later = TranscriptIndex(roots: roots, cacheURL: cacheURL)
        let first = TranscriptIndex(roots: roots, cacheURL: cacheURL)
        _ = await first.refreshAll(progress: nil)
        try await first.save()
        #expect(await later.sessions.count == (await first.sessions).count)
    }

    @Test func progressReachesOne() async {
        _ = seed()
        let seen = Locked<[Double]>([])
        _ = await TranscriptIndex(roots: roots, cacheURL: cacheURL).refreshAll { p in seen.withLock { $0.append(p) } }
        #expect(seen.withLock { $0.last } == 1)
    }

    @Test func largeLogPerformance() async {
        let blob = #"{"type":"api-request-blob","id":"b","body":""# + String(repeating: "x", count: 9_000) + "\"}\n"
        let assistant = #"{"parentUuid":"p","type":"assistant","sessionId":"big","cwd":"/p","timestamp":"2026-10-27T10:00:00.000Z","message":{"id":"ID","model":"claude-opus-5-5","stop_reason":"end_turn","content":[{"type":"text","text":""# + String(repeating: "y", count: 800) + #""}],"usage":{"input_tokens":1,"output_tokens":1}}}"# + "\n"
        var body = ""
        var n = 0
        while body.utf8.count < 50_000_000 {
            for _ in 0..<5 { body += blob }
            body += assistant.replacingOccurrences(of: "\"ID\"", with: "\"m\(n)\"")
            n += 1
        }
        _ = tmp.file("claude/-p/big.jsonl", body)
        let index = TranscriptIndex(roots: roots, cacheURL: cacheURL)
        let clock = ContinuousClock()
        let elapsed = await clock.measure { _ = await index.refreshAll(progress: nil) }
        #expect(await index.sessions.first?.tokens.output == n)
        #if !DEBUG
        #expect(elapsed < .milliseconds(1500), "refreshAll impiega \(elapsed)")
        #endif
    }
}

extension TranscriptIndexTests {
    /// Codex tiene aperto il file di sessione: FSEvents non segnala le scritture finché non lo chiude,
    /// quindi i file recenti si ricontrollano a intervalli.
    @Test func pollsOpenCodexRollouts() async throws {
        let day = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        let dir = String(format: "codex/%04d/%02d/%02d", day.year!, day.month!, day.day!)
        let lines = text("codex-sample.jsonl").split(separator: "\n", omittingEmptySubsequences: true)
        let half = lines.count / 2
        let file = tmp.file("\(dir)/rollout-2026-10-27T10-00-00-01a1494b-8ccc-7553-99cb-df33363f95a1.jsonl",
                            lines.prefix(half).joined(separator: "\n") + "\n")
        let index = TranscriptIndex(roots: roots, cacheURL: cacheURL)
        let first = await index.refreshAll(progress: nil)
        let before = try #require(first.changed.first).tokens.total
        #expect(await index.pollCodex(now: Date()).changed.isEmpty)
        let handle = try FileHandle(forWritingTo: file)
        handle.seekToEndOfFile()
        handle.write(Data((lines.dropFirst(half).joined(separator: "\n") + "\n").utf8))
        try handle.close()
        let polled = await index.pollCodex(now: Date().addingTimeInterval(1))
        #expect(polled.changed.count == 1)
        #expect(try #require(polled.changed.first).tokens.total > before)
    }

    /// Una sessione nata giorni fa ma ancora aperta: conta l'ultima modifica, non la cartella del giorno.
    @Test func pollsRecentlyModifiedOlderRollouts() async throws {
        let file = tmp.file("codex/2026/01/02/rollout-2026-01-02T10-00-00-01a1494b-8ccc-7553-99cb-df33363f95a1.jsonl",
                            text("codex-sample.jsonl"))
        let index = TranscriptIndex(roots: roots, cacheURL: cacheURL)
        _ = await index.refreshAll(progress: nil)
        let handle = try FileHandle(forWritingTo: file)
        handle.seekToEndOfFile()
        handle.write(Data("{\"type\":\"turn_context\",\"timestamp\":\"2026-01-02T10:05:00Z\",\"payload\":{\"model\":\"gpt-x\"}}\n".utf8))
        try handle.close()
        let polled = await index.pollCodex(now: Date().addingTimeInterval(1))
        #expect(polled.changed.first?.model == "gpt-x")
    }
}

@Suite struct DirectoryWatcherTests {
    @Test func reportsChangedFiles() async throws {
        let tmp = TempDir()
        let seen = Locked<[String]>([])
        let watcher = DirectoryWatcher(paths: [tmp.url], latency: 0.05) { paths in seen.withLock { $0 += paths } }
        watcher.start()
        defer { watcher.stop() }
        try await Task.sleep(for: .milliseconds(300))
        let f = tmp.file("a/b.jsonl", "{}\n")
        for _ in 0..<40 where !seen.withLock({ $0.contains { $0.hasSuffix("/a/b.jsonl") } }) {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(seen.withLock { $0.contains { ($0 as NSString).resolvingSymlinksInPath == (f.path as NSString).resolvingSymlinksInPath } })
    }
}
