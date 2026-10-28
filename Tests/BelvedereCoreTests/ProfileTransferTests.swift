import Foundation
import Testing
@testable import BelvedereCore

@Suite struct ProfileTransferTests {
    let tmp = TempDir()
    let fm = FileManager.default

    private func profile(_ name: String, _ agent: AgentKind = .claude) -> Profile {
        Profile(name: name, agent: agent, configDir: tmp.url.appendingPathComponent(name).path)
    }

    private func exists(_ rel: String) -> Bool { fm.fileExists(atPath: tmp.url.appendingPathComponent(rel).path) }

    @Test func claudePathsWithSidecarFolder() throws {
        let file = tmp.file("A/projects/-p/s1.jsonl", "{}\n")
        _ = tmp.file("A/projects/-p/s1/subagents/a.jsonl", "{}\n")
        let t = try ProfileTransfer.begin(transcriptPath: file.path, sessionID: "s1", agent: .claude,
                                          from: profile("A"), to: profile("B"))
        #expect(exists("B/projects/-p/s1.jsonl"))
        #expect(exists("B/projects/-p/s1/subagents/a.jsonl"))
        #expect(exists("A/projects/-p/s1.jsonl"))
        #expect(t.copiedPaths.count == 2)
        #expect(t.sourcePaths.count == 2)
    }

    @Test func codexPathKeepsDatedLayout() throws {
        let file = tmp.file("A/sessions/2026/10/28/rollout-x.jsonl", "{}\n")
        _ = try ProfileTransfer.begin(transcriptPath: file.path, sessionID: "x", agent: .codex,
                                      from: profile("A", .codex), to: profile("B", .codex))
        #expect(exists("B/sessions/2026/10/28/rollout-x.jsonl"))
    }

    @Test func confirmDeletesSource() throws {
        let file = tmp.file("A/projects/-p/s1.jsonl", "{}\n")
        _ = tmp.file("A/projects/-p/s1/subagents/a.jsonl", "{}\n")
        let t = try ProfileTransfer.begin(transcriptPath: file.path, sessionID: "s1", agent: .claude,
                                          from: profile("A"), to: profile("B"))
        try ProfileTransfer.confirm(t)
        #expect(!exists("A/projects/-p/s1.jsonl"))
        #expect(!exists("A/projects/-p/s1"))
        #expect(exists("B/projects/-p/s1.jsonl"))
    }

    @Test func rollbackDeletesCopyOnly() throws {
        let file = tmp.file("A/projects/-p/s1.jsonl", "{}\n")
        let t = try ProfileTransfer.begin(transcriptPath: file.path, sessionID: "s1", agent: .claude,
                                          from: profile("A"), to: profile("B"))
        ProfileTransfer.rollback(t)
        #expect(!exists("B/projects/-p/s1.jsonl"))
        #expect(exists("A/projects/-p/s1.jsonl"))
    }

    /// L'origine è già stata cancellata (conferma a metà): annullare non deve togliere l'unica copia rimasta.
    @Test func rollbackKeepsCopyWhenSourceIsGone() throws {
        let file = tmp.file("A/projects/-p/s1.jsonl", "{}\n")
        let t = try ProfileTransfer.begin(transcriptPath: file.path, sessionID: "s1", agent: .claude,
                                          from: profile("A"), to: profile("B"))
        try ProfileTransfer.confirm(t)
        ProfileTransfer.rollback(t)
        #expect(exists("B/projects/-p/s1.jsonl"))
    }

    @Test func destinationExistsThrows() throws {
        let file = tmp.file("A/projects/-p/s1.jsonl", "{}\n")
        _ = tmp.file("B/projects/-p/s1.jsonl", "altro\n")
        #expect(throws: ProfileTransfer.Failure.destinationExists) {
            try ProfileTransfer.begin(transcriptPath: file.path, sessionID: "s1", agent: .claude,
                                      from: profile("A"), to: profile("B"))
        }
        #expect(try String(contentsOf: tmp.url.appendingPathComponent("B/projects/-p/s1.jsonl"), encoding: .utf8) == "altro\n")
    }

    @Test func pathOutsideSourceRootIsNil() {
        #expect(ProfileTransfer.destination(for: "/altrove/s1.jsonl", from: profile("A"), to: profile("B")) == nil)
        #expect(ProfileTransfer.destination(for: tmp.url.appendingPathComponent("A/projects/-p/s1.jsonl").path,
                                            from: profile("A"), to: profile("B"))
                == tmp.url.appendingPathComponent("B/projects/-p/s1.jsonl").standardizedFileURL.path)
    }

    /// Belvedere chiuso a metà: all'avvio la copia sparisce e l'origine resta.
    @Test func persistedTransfersRoundTrip() throws {
        let file = tmp.file("A/projects/-p/s1.jsonl", "{}\n")
        let t = try ProfileTransfer.begin(transcriptPath: file.path, sessionID: "s1", agent: .claude,
                                          from: profile("A"), to: profile("B"))
        let store = tmp.url.appendingPathComponent("transfers.json")
        try ProfileTransfer.save([t], to: store)
        let loaded = ProfileTransfer.load(from: store)
        #expect(loaded == [t])
        loaded.forEach { ProfileTransfer.rollback($0) }
        #expect(!exists("B/projects/-p/s1.jsonl"))
        #expect(exists("A/projects/-p/s1.jsonl"))
    }
}
