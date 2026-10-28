import Testing
@testable import BelvedereCore

struct FencedBlocksTests {
    @Test func codeFenceKeepsItsLines() {
        let parts = FencedBlocks.split("Ecco:\n\n```\nuno\ndue\n```\nFine.")
        #expect(parts == [.text("Ecco:\n\n"), .code("uno\ndue"), .text("Fine.")])
    }

    @Test func languageTagIsDropped() {
        #expect(FencedBlocks.split("```swift\nlet a = 1\n```") == [.code("let a = 1")])
    }

    @Test func unclosedFenceRunsToTheEnd() {
        #expect(FencedBlocks.split("a\n```\nb\nc") == [.text("a\n"), .code("b\nc")])
    }

    @Test func plainTextIsOnePart() {
        #expect(FencedBlocks.split("solo `inline` qui") == [.text("solo `inline` qui")])
    }

    @Test func tableBecomesAlignedColumns() {
        let parts = FencedBlocks.split("Uso:\n| Voce | Token |\n|---|---|\n| Sistema | 3.3k |\n| MCP | 32k |\nFine.")
        #expect(parts == [.text("Uso:\n"), .code("Voce     Token\nSistema  3.3k\nMCP      32k"), .text("Fine.")])
    }

    @Test func headingBecomesBold() {
        #expect(FencedBlocks.split("### MCP Tools\naltro") == [.text("**MCP Tools**\naltro")])
    }
}
