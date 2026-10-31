import Foundation
import Testing
@testable import BelvedereCore

@Suite struct LinkingURLsTests {
    private func links(_ markdown: String) throws -> [String] {
        let text = FencedBlocks.linkingURLs(try AttributedString(markdown: markdown))
        return text.runs.compactMap { $0.link?.absoluteString }
    }

    @Test func bareAddressBecomesALink() throws {
        #expect(try links("Pronto: https://claude.ai/artifact/Qo1LZNM") == ["https://claude.ai/artifact/Qo1LZNM"])
    }

    @Test func leavesMarkdownLinksAndFileNamesAlone() throws {
        #expect(try links("[qui](https://a.it/x) e README.md") == ["https://a.it/x"])
    }
}
