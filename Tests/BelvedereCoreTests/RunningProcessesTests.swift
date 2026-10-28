import Foundation
import Testing
@testable import BelvedereCore

@Suite struct RunningProcessesTests {
    @Test func findsTheFolderOfALiveProcess() throws {
        let tmp = TempDir()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sleep")
        p.arguments = ["5"]
        p.currentDirectoryURL = tmp.url
        try p.run()
        defer { p.terminate() }
        let folder = RunningProcesses.canonical(tmp.url.path)
        #expect(RunningProcesses.folders(named: "sleep", excluding: []).contains(folder))
        #expect(!RunningProcesses.folders(named: "sleep", excluding: [p.processIdentifier]).contains(folder))
    }
}
