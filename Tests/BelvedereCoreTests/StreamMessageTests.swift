import Foundation
import Testing
@testable import BelvedereCore

@Suite struct StreamMessageTests {
    private func messages(_ name: String) -> [StreamMessage] { Fixture.lines(name).map(StreamMessage.decode) }

    @Test func decodesInit() throws {
        let info = try #require(messages("stream-allow.jsonl").lazy.compactMap { m -> StreamInit? in
            if case .initialized(let i) = m { return i } else { return nil }
        }.first)
        #expect(!info.sessionID.isEmpty)
        #expect(info.model == "claude-haiku-5-5")
        #expect(info.permissionMode == "default")
        #expect(info.terminalCommands.contains("doctor"))
        #expect(info.mcpServers.contains { $0.name == "tracker" && !$0.status.isEmpty })
        #expect(info.cwd.hasPrefix("/tmp/progetto/"))
    }

    @Test func decodesInitializeCommands() throws {
        let commands = try #require(messages("stream-allow.jsonl").lazy.compactMap { m -> [SlashCommand]? in
            if case .commands(let c) = m { return c } else { return nil }
        }.first)
        #expect(!commands.isEmpty)
        #expect(commands.allSatisfy { !$0.name.isEmpty })
        #expect(commands.contains { !$0.description.isEmpty })
    }

    @Test func decodesCanUseTool() throws {
        let ask = try #require(messages("stream-allow.jsonl").lazy.compactMap { m -> PermissionAsk? in
            if case .permission(let a) = m { return a } else { return nil }
        }.first)
        #expect(ask.toolName == "Bash")
        #expect(ask.input["command"]?.stringValue == "touch spike-ok")
        #expect(ask.toolUseID?.hasPrefix("toolu_") == true)
        #expect(!ask.id.isEmpty)
        #expect(ask.alwaysRules.count == 1)
        #expect(ask.isQuestion == false)
    }

    @Test func decodesAskUserQuestion() throws {
        let ask = try #require(messages("stream-ask.jsonl").lazy.compactMap { m -> PermissionAsk? in
            if case .permission(let a) = m { return a } else { return nil }
        }.first)
        #expect(ask.isQuestion)
        guard case .array(let questions)? = ask.input["questions"] else { Issue.record("atteso un array"); return }
        #expect(questions.count == 1)
    }

    @Test func decodesRateLimits() throws {
        let limits = try #require(messages("stream-allow.jsonl").lazy.compactMap { m -> PlanLimits? in
            if case .rateLimits(let l) = m { return l } else { return nil }
        }.first)
        #expect(limits.fiveHour?.usedPercent == 17)
        #expect(limits.weekly?.usedPercent == 16)
        #expect(limits.fiveHour?.resetsAt == Date(timeIntervalSince1970: 1793191800))
    }

    @Test func decodesResult() throws {
        let result = try #require(messages("stream-allow.jsonl").lazy.compactMap { m -> TurnResult? in
            if case .result(let r) = m { return r } else { return nil }
        }.first)
        #expect(result.isError == false)
        #expect(result.subtype == "success")
        #expect((result.costUSD ?? 0) > 0)
        #expect(result.contextWindow == 1_000_000)
        #expect(result.contextTokens == 2 + 29460 + 3205)
    }

    @Test func decodesInterruptAndTextDelta() {
        let all = messages("stream-mixed.jsonl")
        #expect(all.contains(.interrupted))
        let delta = StreamMessage.decode(Data(#"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Ciao"}}}"#.utf8))
        #expect(delta == .textDelta("Ciao"))
    }

    @Test func assistantAndUserLinesPassThrough() {
        let lines = messages("stream-allow.jsonl").filter { if case .line = $0 { true } else { false } }
        #expect(lines.count >= 3)
    }

    @Test func garbageIsOther() {
        #expect(StreamMessage.decode(Data("non json".utf8)) == .other)
        #expect(StreamMessage.decode(Data(#"{"type":"system","subtype":"status"}"#.utf8)) == .other)
    }
}
