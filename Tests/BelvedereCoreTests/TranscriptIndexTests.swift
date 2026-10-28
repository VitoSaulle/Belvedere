import Foundation
import Testing
@testable import BelvedereCore

@Suite struct TranscriptIndexTests {
    let tmp = TempDir()
    let roots: TranscriptRoots
    init() {
        roots = TranscriptRoots([
            TranscriptRoot(profileID: UUID(), agent: .claude, url: tmp.url.appendingPathComponent("claude")),
            TranscriptRoot(profileID: UUID(), agent: .codex, url: tmp.url.appendingPathComponent("codex")),
        ])
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
        #expect(await index.latestCodexLimits(profile: roots.roots[1].profileID)?.fiveHour?.usedPercent == 21)
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

    /// Un file sparito e ricomparso (riscrittura atomica, spostamento) non si riconta da capo.
    @Test func reappearingFileIsNotCountedTwice() async throws {
        let files = seed()
        let index = TranscriptIndex(roots: roots, cacheURL: cacheURL)
        _ = await index.refreshAll(progress: nil)
        let total = await index.buckets.reduce(0) { $0 + $1.tokens.output }
        let saved = try Data(contentsOf: files.claude)
        try FileManager.default.removeItem(at: files.claude)
        _ = await index.refresh(paths: [files.claude.path])
        #expect(await index.sessions.allSatisfy { $0.id != "s1" })
        try saved.write(to: files.claude)
        let update = await index.refresh(paths: [files.claude.path])
        #expect(update.changed.map(\.id) == ["s1"])
        #expect(update.newBuckets.isEmpty)
        #expect(await index.buckets.reduce(0) { $0 + $1.tokens.output } == total)
        #expect(await index.sessions.contains { $0.id == "s1" })
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

extension TranscriptIndexTests {
    /// Eliminare una sessione cancella il log, la cartella dei subagenti e l'entrata dell'indice,
    /// ma non il consumo già contato nelle statistiche.
    @Test func deleteRemovesFilesButKeepsStats() async throws {
        let files = seed()
        let line = #"{"type":"assistant","sessionId":"s1","cwd":"/Users/v/proj","timestamp":"2026-10-28T09:30:00.000Z","message":{"id":"sub1","model":"claude-haiku-5-5","stop_reason":"end_turn","content":[],"usage":{"input_tokens":7,"output_tokens":3}}}"#
        let sub = tmp.file("claude/-Users-v-proj/s1/subagents/agent-a1.jsonl", line + "\n")
        let index = TranscriptIndex(roots: roots, cacheURL: cacheURL)
        _ = await index.refreshAll(progress: nil)
        let buckets = await index.buckets.count
        let codexID = try #require(await index.sessions.first { $0.agent == .codex }).id

        let deleted = await index.delete(sessionIDs: ["s1", codexID])

        #expect(Set(deleted) == ["s1", codexID])
        for url in [files.claude, files.codex, sub.deletingLastPathComponent().deletingLastPathComponent()] {
            #expect(!FileManager.default.fileExists(atPath: url.path))
        }
        #expect(FileManager.default.fileExists(atPath: tmp.url.appendingPathComponent("claude/-Users-v-proj").path))
        #expect(await index.sessions.isEmpty)
        #expect(await index.buckets.count == buckets)
        // Gli eventi FSEvents che arrivano dopo non la fanno ricomparire come «chiusa».
        #expect(await index.refresh(paths: [files.claude.path, files.codex.path]).changed.isEmpty)
        #expect(await index.refreshAll(progress: nil).changed.isEmpty)
    }

    @Test func deleteIgnoresUnknownIDs() async {
        let files = seed()
        let index = TranscriptIndex(roots: roots, cacheURL: cacheURL)
        _ = await index.refreshAll(progress: nil)
        #expect(await index.delete(sessionIDs: ["nope"]).isEmpty)
        #expect(FileManager.default.fileExists(atPath: files.claude.path))
        #expect(await index.sessions.count == 2)
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

extension TranscriptIndexTests {
    // MARK: - Profili

    static let pA = UUID(), pB = UUID(), pX = UUID(), pY = UUID()

    private func profileRoots(claude2: URL? = nil, withB: Bool = true, codex2: Bool = false) -> TranscriptRoots {
        var list = [TranscriptRoot(profileID: Self.pA, agent: .claude, url: tmp.url.appendingPathComponent("claude"))]
        if withB { list.append(TranscriptRoot(profileID: Self.pB, agent: .claude, url: claude2 ?? tmp.url.appendingPathComponent("claude2"))) }
        list.append(TranscriptRoot(profileID: Self.pX, agent: .codex, url: tmp.url.appendingPathComponent("codex")))
        if codex2 { list.append(TranscriptRoot(profileID: Self.pY, agent: .codex, url: tmp.url.appendingPathComponent("codex2"))) }
        return TranscriptRoots(list)
    }

    @Test func snapshotsCarryProfile() async {
        _ = seed()
        _ = tmp.file("claude2/-Users-v-proj/s2.jsonl", text("claude-sample.jsonl").replacingOccurrences(of: "\"s1\"", with: "\"s2\""))
        let index = TranscriptIndex(roots: profileRoots(), cacheURL: cacheURL)
        let update = await index.refreshAll(progress: nil)
        let byID = Dictionary(uniqueKeysWithValues: await index.sessions.map { ($0.id, $0.profileID) })
        #expect(byID["s1"] == Self.pA)
        #expect(byID["s2"] == Self.pB)
        #expect(byID["01a1494b-8ccc-7553-99cb-df33363f95a1"] == Self.pX)
        #expect(update.changed.allSatisfy { $0.profileID != nil })
    }

    @Test func symlinkedRootIsClassified() async throws {
        _ = seed()
        _ = tmp.file("real2/-Users-v-proj/s2.jsonl", text("claude-sample.jsonl").replacingOccurrences(of: "\"s1\"", with: "\"s2\""))
        let link = tmp.url.appendingPathComponent("claude2")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: tmp.url.appendingPathComponent("real2"))
        let index = TranscriptIndex(roots: profileRoots(), cacheURL: cacheURL)
        _ = await index.refreshAll(progress: nil)
        #expect(await index.sessions.first { $0.id == "s2" }?.profileID == Self.pB)
    }

    @Test func setRootsRemovesAndAdds() async {
        _ = seed()
        _ = tmp.file("claude2/-Users-v-proj/s2.jsonl", text("claude-sample.jsonl").replacingOccurrences(of: "\"s1\"", with: "\"s2\""))
        let index = TranscriptIndex(roots: profileRoots(), cacheURL: cacheURL)
        _ = await index.refreshAll(progress: nil)
        let total = await index.buckets.reduce(0) { $0 + $1.tokens.total }
        let removed = await index.setRoots(profileRoots(withB: false))
        #expect(removed.changed.first { $0.id == "s2" }?.status == .ended)
        #expect(await index.sessions.allSatisfy { $0.id != "s2" })
        #expect(await index.buckets.reduce(0) { $0 + $1.tokens.total } == total)
        _ = await index.setRoots(profileRoots())
        #expect(await index.sessions.first { $0.id == "s2" }?.profileID == Self.pB)
        #expect(await index.buckets.reduce(0) { $0 + $1.tokens.total } == total)
    }

    @Test func duplicateIDKeepsNewestAndCountsOnce() async throws {
        _ = seed()
        let single = TranscriptIndex(roots: profileRoots(withB: false), cacheURL: tmp.url.appendingPathComponent("single.json"))
        _ = await single.refreshAll(progress: nil)
        let once = await single.buckets.reduce(0) { $0 + $1.tokens.total }
        let copy = tmp.file("claude2/-Users-v-proj/s1.jsonl", text("claude-sample.jsonl"))
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: copy.path)
        let index = TranscriptIndex(roots: profileRoots(), cacheURL: cacheURL)
        _ = await index.refreshAll(progress: nil)
        let s1 = await index.sessions.filter { $0.id == "s1" }
        #expect(s1.count == 1)
        #expect(s1.first?.profileID == Self.pB)
        #expect(await index.buckets.reduce(0) { $0 + $1.tokens.total } == once)
        #expect(await index.duplicateCount == 1)
    }

    @Test func codexLimitsPerProfile() async {
        _ = seed()
        let index = TranscriptIndex(roots: profileRoots(codex2: true), cacheURL: cacheURL)
        _ = await index.refreshAll(progress: nil)
        #expect(await index.latestCodexLimits(profile: Self.pX)?.fiveHour?.usedPercent == 21)
        #expect(await index.latestCodexLimits(profile: Self.pY) == nil)
    }

    private func transferFixture() async throws -> (TranscriptIndex, PendingTransfer, Int) {
        _ = seed()
        _ = tmp.file("claude/-Users-v-proj/s1/subagents/agent-a1.jsonl", #"{"type":"assistant","sessionId":"s1","cwd":"/Users/v/proj","timestamp":"2026-10-28T09:30:00.000Z","message":{"id":"sub1","model":"claude-haiku-5-5","stop_reason":"end_turn","content":[],"usage":{"input_tokens":7,"output_tokens":3}}}"# + "\n")
        let index = TranscriptIndex(roots: profileRoots(), cacheURL: cacheURL)
        _ = await index.refreshAll(progress: nil)
        let total = await index.buckets.reduce(0) { $0 + $1.tokens.total }
        // Le radici dei test non finiscono in `projects`: i percorsi si calcolano a mano.
        let src = tmp.url.appendingPathComponent("claude/-Users-v-proj").standardizedFileURL
        let dst = tmp.url.appendingPathComponent("claude2/-Users-v-proj").standardizedFileURL
        try FileManager.default.createDirectory(at: dst, withIntermediateDirectories: true)
        for name in ["s1.jsonl", "s1"] {
            try FileManager.default.copyItem(at: src.appendingPathComponent(name), to: dst.appendingPathComponent(name))
        }
        let t = PendingTransfer(sessionID: "s1", agent: .claude, from: Self.pA, to: Self.pB,
                                sourcePaths: [src.appendingPathComponent("s1.jsonl").path, src.appendingPathComponent("s1").path],
                                copiedPaths: [dst.appendingPathComponent("s1.jsonl").path, dst.appendingPathComponent("s1").path])
        return (index, t, total)
    }

    @Test func transferDoesNotDoubleCount() async throws {
        let (index, t, total) = try await transferFixture()
        let begun = await index.beginTransfer(t)
        #expect(begun.changed.first { $0.id == "s1" }?.profileID == Self.pB)
        #expect(begun.changed.first { $0.id == "s1" }?.transcriptPath == t.copiedPaths[0])
        _ = await index.refreshAll(progress: nil)
        #expect(await index.sessions.filter { $0.id == "s1" }.map(\.profileID) == [Self.pB])
        #expect(await index.buckets.reduce(0) { $0 + $1.tokens.total } == total)
        for path in t.sourcePaths { try FileManager.default.removeItem(atPath: path) }
        _ = await index.endTransfer(t, confirmed: true)
        _ = await index.refreshAll(progress: nil)
        #expect(await index.sessions.filter { $0.id == "s1" }.map(\.profileID) == [Self.pB])
        #expect(await index.buckets.reduce(0) { $0 + $1.tokens.total } == total)
    }

    @Test func rollbackRestoresSource() async throws {
        let (index, t, total) = try await transferFixture()
        _ = await index.beginTransfer(t)
        _ = await index.refreshAll(progress: nil)
        for path in t.copiedPaths { try FileManager.default.removeItem(atPath: path) }
        let ended = await index.endTransfer(t, confirmed: false)
        #expect(ended.changed.first { $0.id == "s1" }?.profileID == Self.pA)
        _ = await index.refreshAll(progress: nil)
        #expect(await index.sessions.filter { $0.id == "s1" }.map(\.profileID) == [Self.pA])
        #expect(await index.buckets.reduce(0) { $0 + $1.tokens.total } == total)
    }
}
