import Foundation
import Testing
@testable import BelvedereCore

/// Prova manuale sui log veri: `BELVEDERE_REAL=1 swift test -c release --filter RealLogsTests`.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["BELVEDERE_REAL"] == "1"))
struct RealLogsTests {
    @Test func indexesRealLogs() async throws {
        let tmp = TempDir()
        let cache = tmp.url.appendingPathComponent("index.json")
        let index = TranscriptIndex(roots: .default, cacheURL: cache)
        let clock = ContinuousClock()
        let cold = await clock.measure { _ = await index.refreshAll(progress: nil) }
        try await index.save()
        let warmIndex = TranscriptIndex(roots: .default, cacheURL: cache)
        let warm = await clock.measure { _ = await warmIndex.refreshAll(progress: nil) }
        let sessions = await index.sessions
        let buckets = await index.buckets
        let size = (try? FileManager.default.attributesOfItem(atPath: cache.path)[.size] as? Int) ?? 0
        print("REAL cold=\(cold) warm=\(warm) sessions=\(sessions.count) buckets=\(buckets.count) cache=\(size / 1024)KB")
        for s in sessions.prefix(6) {
            print("REAL \(s.agent) \(s.status) \(s.displayName.prefix(40)) model=\(s.model ?? "-") ctx=\(s.contextTokens ?? 0)/\(s.contextWindow ?? 0) out=\(s.tokens.output) cost=\(s.costUSD ?? 0)")
        }
        print("REAL codexLimits=\(String(describing: await index.latestCodexLimits))")
    }
}

/// Prova end-to-end: scrive le impostazioni di Belvedere in un file a scelta, mai in ~/.claude.
/// `BELVEDERE_E2E_SETTINGS=<file> BELVEDERE_E2E_HELPERS=<cartella> swift test --filter E2ESettings`
@Suite(.enabled(if: ProcessInfo.processInfo.environment["BELVEDERE_E2E_SETTINGS"] != nil))
struct E2ESettings {
    @Test func writeProjectSettings() throws {
        let env = ProcessInfo.processInfo.environment
        let target = URL(fileURLWithPath: env["BELVEDERE_E2E_SETTINGS"]!)
        #expect(!target.path.hasPrefix(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude").path))
        let helpers = URL(fileURLWithPath: env["BELVEDERE_E2E_HELPERS"]!)
        let settings = ClaudeSettingsInstaller.install(into: [:], helpers: helpers, port: Belvedere.defaultPort,
                                                       permissionTimeout: 590)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            .write(to: target)
    }
}

/// Collega e scollega su una COPIA delle impostazioni reali e verifica che tornino identiche.
/// `BELVEDERE_E2E_ROUNDTRIP=<copia di settings.json> swift test --filter E2ERoundTrip`
@Suite(.enabled(if: ProcessInfo.processInfo.environment["BELVEDERE_E2E_ROUNDTRIP"] != nil))
struct E2ERoundTrip {
    @Test func installThenUninstallRestores() throws {
        let copy = URL(fileURLWithPath: ProcessInfo.processInfo.environment["BELVEDERE_E2E_ROUNDTRIP"]!)
        #expect(copy.path != FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json").path)
        let file = SettingsFile(url: copy)
        let original = try file.read()
        let helpers = URL(fileURLWithPath: "/tmp/helpers")
        try file.writeWithBackup(ClaudeSettingsInstaller.install(into: original, helpers: helpers, port: 47615, permissionTimeout: 590))
        #expect(ClaudeSettingsInstaller.isInstalled(try file.read(), port: 47615))
        try file.writeWithBackup(ClaudeSettingsInstaller.uninstall(from: try file.read(), port: 47615))
        #expect(NSDictionary(dictionary: try file.read()).isEqual(to: original))
    }
}
