import Testing
@testable import BelvedereCore

@Suite struct SmokeTests {
    @Test func defaultPort() {
        #expect(Belvedere.defaultPort == 47615)
        #expect(Belvedere.supportDirectory.path.hasSuffix("Application Support/Belvedere"))
    }
}
