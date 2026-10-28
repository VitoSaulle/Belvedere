import Foundation
import Testing
@testable import BelvedereCore

@Suite(.serialized) struct StreamProcessTests {
    private func fake() -> StreamProcess {
        StreamProcess(executable: "/bin/sh", arguments: [Fixture.url("fake-claude.sh").path],
                      environment: ProcessInfo.processInfo.environment, directory: NSTemporaryDirectory())
    }

    private func line(_ text: String) -> Data { Data((text + "\n").utf8) }

    @Test func echoesLines() async throws {
        let process = fake()
        let events = try process.start()
        try process.send(line("uno"))
        try process.send(line("due"))
        var got: [String] = []
        for await event in events {
            if case .line(let data) = event,
               let o = try JSONSerialization.jsonObject(with: data) as? [String: Any] { got.append(o["got"] as? String ?? "") }
            if got.count == 2 { break }
        }
        #expect(got == ["uno", "due"])
        await process.stop()
    }

    @Test func bigLineArrivesWhole() async throws {
        let process = fake()
        let events = try process.start()
        let clock = ContinuousClock()
        var size = 0
        let elapsed = try await clock.measure {
            try process.send(line("big"))
            for await event in events {
                if case .line(let data) = event { size = data.count; break }
            }
        }
        #expect(size == 5_000_000 + #"{"type":"big","data":""}"#.utf8.count)
        #expect(elapsed < .seconds(3))
        await process.stop()
    }

    @Test func exitReportsCodeAndStderr() async throws {
        let process = fake()
        let events = try process.start()
        try process.send(line("die"))
        var exit: (Int32, String)?
        for await event in events {
            if case .exited(let code, let stderr) = event { exit = (code, stderr) }
        }
        #expect(exit?.0 == 3)
        #expect(exit?.1.contains("Invalid API key") == true)
    }

    @Test func stopTerminatesChild() async throws {
        let process = fake()
        _ = try process.start()
        try process.send(line("hang"))
        try await Task.sleep(for: .milliseconds(200))
        let pid = try #require(process.pid)
        let clock = ContinuousClock()
        let elapsed = await clock.measure { await process.stop(grace: .milliseconds(300)) }
        #expect(elapsed < .seconds(3))
        #expect(kill(pid, 0) != 0)
    }

    @Test func missingExecutableThrows() {
        let process = StreamProcess(executable: "/nonexistent/claude", arguments: [], environment: [:], directory: "/")
        #expect(throws: (any Error).self) { _ = try process.start() }
    }
}
