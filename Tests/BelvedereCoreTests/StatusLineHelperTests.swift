import Foundation
import Testing

@Suite struct StatusLineHelperTests {
    /// Il comando avvolto non legge lo stdin: il helper non deve morire per SIGPIPE.
    @Test func wrappedCommandThatIgnoresInput() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let helper = root.appendingPathComponent(".build/debug/belvedere-statusline")
        try #require(FileManager.default.isExecutableFile(atPath: helper.path))
        let p = Process()
        p.executableURL = helper
        p.arguments = ["--wrap", Data("exec echo ciao".utf8).base64EncodedString()]
        p.environment = ["BELVEDERE_PORT": "1"]
        let input = Pipe(), output = Pipe()
        p.standardInput = input
        p.standardOutput = output
        try p.run()
        try input.fileHandleForWriting.write(contentsOf: Data(repeating: 0x20, count: 2_000_000))
        try input.fileHandleForWriting.close()
        p.waitUntilExit()
        #expect(p.terminationReason == .exit)
        #expect(p.terminationStatus == 0)
        #expect(String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) == "ciao\n")
    }
}
