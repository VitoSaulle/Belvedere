import Foundation
import Testing
@testable import BelvedereCore

@Suite struct TranscriptMessagesTests {
    @Test func claudeConversation() throws {
        let items = try TranscriptMessages.load(path: Fixture.url("claude-sample.jsonl").path, agent: .claude)
        #expect(items == [
            .user(id: "u1", text: "Aggiungi l'export CSV"),
            .assistant(id: "m1#text", text: "Parto dal servizio dei report."),
            .tool(id: "t1", name: "Edit", detail: "/Users/v/proj/Report.java", added: 3, removed: 1),
            .tool(id: "t2", name: "Bash", detail: "./gradlew test", added: nil, removed: nil),
            .assistant(id: "m3#text", text: "Fatto, export pronto."),
        ])
    }

    @Test func claudeDedupAndFilters() throws {
        let tmp = TempDir()
        let lines = [
            #"{"type":"user","uuid":"a","isMeta":true,"message":{"role":"user","content":"meta nascosto"}}"#,
            #"{"type":"user","uuid":"b","message":{"role":"user","content":"<command-name>/clear</command-name>"}}"#,
            #"{"type":"user","uuid":"c","message":{"role":"user","content":[{"type":"text","text":"Da blocchi"}]}}"#,
            #"{"type":"assistant","message":{"id":"m","content":[{"type":"text","text":"Una volta"}]}}"#,
            #"{"type":"assistant","message":{"id":"m","content":[{"type":"text","text":"Una volta"}]}}"#,
            #"{"type":"system","subtype":"turn_duration","durationMs":5}"#,
        ]
        let url = tmp.file("s.jsonl", lines.joined(separator: "\n") + "\n")
        let items = try TranscriptMessages.load(path: url.path, agent: .claude)
        #expect(items == [.user(id: "c", text: "Da blocchi"), .assistant(id: "m#text", text: "Una volta")])
    }

    @Test func limitKeepsLatest() throws {
        let items = try TranscriptMessages.load(path: Fixture.url("claude-sample.jsonl").path, agent: .claude, limit: 2)
        #expect(items.map(\.id) == ["t2", "m3#text"])
    }

    @Test func codexConversation() throws {
        let tmp = TempDir()
        let lines = [
            #"{"type":"response_item","payload":{"type":"message","role":"developer","content":[{"type":"input_text","text":"istruzioni"}]}}"#,
            #"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"<environment_context>x</environment_context>"}]}}"#,
            #"{"type":"response_item","payload":{"type":"message","id":"u1","role":"user","content":[{"type":"input_text","text":"Sistema i test"}]}}"#,
            #"{"type":"response_item","payload":{"type":"function_call","name":"exec_command","arguments":"{\"cmd\":\"npm test\"}","call_id":"c1"}}"#,
            #"{"type":"response_item","payload":{"type":"message","id":"a1","role":"assistant","content":[{"type":"output_text","text":"Fatto."}]}}"#,
        ]
        let url = tmp.file("rollout.jsonl", lines.joined(separator: "\n") + "\n")
        let items = try TranscriptMessages.load(path: url.path, agent: .codex)
        #expect(items == [
            .user(id: "u1", text: "Sistema i test"),
            .tool(id: "c1", name: "exec_command", detail: "npm test", added: nil, removed: nil),
            .assistant(id: "a1", text: "Fatto."),
        ])
    }
}
