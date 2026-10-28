import Foundation
import Testing
@testable import BelvedereCore

@Suite struct StatusLinePayloadTests {
    let now = Date(timeIntervalSince1970: 1_793_170_000)

    @Test func decodesDocumentedExample() throws {
        let p = try StatusLinePayload.decode(Data(contentsOf: Fixture.url("statusline-sample.json")), now: now)
        #expect(p.sessionID == "abc123")
        #expect(p.modelDisplayName == "Opus 5.5")
        #expect(p.cwd == "/current/working/directory")
        #expect(p.contextUsedPercent == 8.2)
        #expect(p.contextWindowSize == 200_000)
        #expect(p.costUSD == 0.01234)
        #expect(p.limits?.fiveHour == LimitWindow(usedPercent: 23.5, resetsAt: Date(timeIntervalSince1970: 1_793_180_000)))
        #expect(p.limits?.weekly?.usedPercent == 41.2)
        #expect(p.limits?.observedAt == now)
    }

    @Test func missingRateLimits() throws {
        let p = try StatusLinePayload.decode(Data(#"{"session_id":"x","rate_limits":{}}"#.utf8), now: now)
        #expect(p.limits == nil)
        #expect(p.modelDisplayName == nil)
        let partial = try StatusLinePayload.decode(Data(#"{"session_id":"x","rate_limits":{"seven_day":{"used_percentage":5}}}"#.utf8), now: now)
        #expect(partial.limits?.fiveHour == nil)
        #expect(partial.limits?.weekly?.usedPercent == 5)
    }

    @Test func decodesTranscriptPath() throws {
        let p = try StatusLinePayload.decode(Data(contentsOf: Fixture.url("statusline-sample.json")), now: now)
        #expect(p.transcriptPath == "/path/to/transcript.json")
    }

    @Test func rejectsInvalid() {
        #expect(throws: (any Error).self) { try StatusLinePayload.decode(Data("[]".utf8), now: now) }
        #expect(throws: (any Error).self) { try StatusLinePayload.decode(Data("{}".utf8), now: now) }
    }

    @Test func rendersCompactLine() throws {
        let p = try StatusLinePayload.decode(Data(contentsOf: Fixture.url("statusline-sample.json")), now: now)
        #expect(StatusLineText.render(p) == "Opus 5.5 · ctx 8% · 5h 24%")
        let bare = try StatusLinePayload.decode(Data(#"{"session_id":"x"}"#.utf8), now: now)
        #expect(StatusLineText.render(bare) == "Belvedere")
    }
}
