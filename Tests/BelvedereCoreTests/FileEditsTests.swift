import Foundation
import Testing
@testable import BelvedereCore

@Suite struct FileEditsTests {
    private func load(_ lines: [String], file: String = "/p/a.txt") throws -> [[DiffLine]] {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("edits-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        return try FileEdits.load(transcript: url.path, file: file)
    }

    private func use(_ id: String, _ name: String, _ input: String) -> String {
        #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"\#(id)","name":"\#(name)","input":\#(input)}]}}"#
    }

    private func result(_ id: String, error: Bool = false, extra: String = "") -> String {
        #"{"type":"user"\#(extra),"message":{"content":[{"type":"tool_result","tool_use_id":"\#(id)","is_error":\#(error),"content":"ok"}]}}"#
    }

    @Test func usesTheRealPatchWithLineNumbers() throws {
        let patch = #","toolUseResult":{"structuredPatch":[{"oldStart":10,"oldLines":3,"newStart":12,"newLines":3,"lines":[" prima","-vecchia","+nuova"," dopo","\\ No newline at end of file"]}]}"#
        let hunks = try load([use("e", "Edit", #"{"file_path":"/p/a.txt","old_string":"vecchia","new_string":"nuova"}"#),
                              result("e", extra: patch)])
        #expect(hunks == [[DiffLine(kind: .context, number: 12, text: "prima"),
                           DiffLine(kind: .removed, number: 11, text: "vecchia"),
                           DiffLine(kind: .added, number: 13, text: "nuova"),
                           DiffLine(kind: .context, number: 14, text: "dopo")]])
    }

    @Test func fallsBackToTheToolInput() throws {
        let hunks = try load([use("e", "Edit", #"{"file_path":"/p/a.txt","old_string":"x","new_string":"y\nz"}"#), result("e"),
                              use("w", "Write", #"{"file_path":"/p/a.txt","content":"uno\ndue"}"#), result("w", extra: #","toolUseResult":{"structuredPatch":[]}"#),
                              use("m", "MultiEdit", #"{"file_path":"/p/a.txt","edits":[{"old_string":"a","new_string":"b"},{"old_string":"c","new_string":"d"}]}"#), result("m")])
        #expect(hunks.count == 4)
        #expect(hunks[0].map(\.kind) == [.removed, .added, .added])
        #expect(hunks[0][2] == DiffLine(kind: .added, number: nil, text: "z"))
        #expect(hunks[1] == [DiffLine(kind: .added, number: 1, text: "uno"), DiffLine(kind: .added, number: 2, text: "due")])
    }

    @Test func onlySuccessfulEditsOfThatFile() throws {
        let hunks = try load([use("no", "Write", #"{"file_path":"/p/a.txt","content":"negato"}"#), result("no", error: true),
                              use("altro", "Write", #"{"file_path":"/p/b.txt","content":"altro"}"#), result("altro"),
                              use("attesa", "Write", #"{"file_path":"/p/a.txt","content":"senza esito"}"#),
                              "riga non json"])
        #expect(hunks.isEmpty)
    }
}
