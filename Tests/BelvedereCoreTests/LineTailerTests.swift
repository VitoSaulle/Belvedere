import Foundation
import Testing
@testable import BelvedereCore

@Suite struct LineTailerTests {
    @Test func readsCompleteLinesOnly() throws {
        let dir = TempDir()
        let f = dir.file("a.jsonl", "a\nb\nc")
        var tailer = LineTailer()
        #expect(try tailer.readNewLines(from: f).strings == ["a", "b"])
        #expect(tailer.offset == 4)
        append("d\n", to: f)
        #expect(try tailer.readNewLines(from: f).strings == ["cd"])
    }

    @Test func restartsWhenFileShrinks() throws {
        let dir = TempDir()
        let f = dir.file("a.jsonl", "x\ny\n")
        var tailer = LineTailer(offset: 500)
        #expect(try tailer.readNewLines(from: f).strings == ["x", "y"])
        #expect(tailer.offset == 4)
    }

    @Test func emptyLinesAreSkipped() throws {
        let dir = TempDir()
        let f = dir.file("a.jsonl", "a\n\nb\n")
        var tailer = LineTailer()
        #expect(try tailer.readNewLines(from: f).strings == ["a", "b"])
    }

    @Test func readsAcrossChunkBoundaries() throws {
        let dir = TempDir()
        let long = String(repeating: "z", count: 3 * 1024 * 1024)
        let f = dir.file("big.jsonl", "\(long)\nfine\n")
        var tailer = LineTailer()
        let lines = try tailer.readNewLines(from: f)
        #expect(lines.count == 2)
        #expect(lines[0].count == long.utf8.count)
        #expect(lines.strings[1] == "fine")
    }
}
