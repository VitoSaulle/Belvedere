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
