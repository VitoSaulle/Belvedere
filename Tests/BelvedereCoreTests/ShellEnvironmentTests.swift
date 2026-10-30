import Foundation
import Testing
@testable import BelvedereCore

@Suite struct ShellEnvironmentTests {
    private func fakeShell(_ body: String) throws -> String {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("fake-shell-\(UUID().uuidString)")
        try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    @Test func shellValuesReachTheChildrenButNotTerminalState() {
        let base = ["PATH": "/usr/bin:/bin", "HOME": "/Users/u", "XPC_SERVICE_NAME": "x"]
        let shell = ["PATH": "/opt/homebrew/bin:/usr/bin", "ADO_TOKEN": "t", "PWD": "/tmp", "OLDPWD": "/", "SHLVL": "2",
                     "TERM": "dumb", "_": "/usr/bin/env"]
        let env = ShellEnvironment.merged(base: base, shell: shell, home: "/Users/u")
        #expect(env["ADO_TOKEN"] == "t")
        #expect(env["HOME"] == "/Users/u")
        #expect(env["XPC_SERVICE_NAME"] == "x")
        #expect(env["PATH"]?.hasPrefix("/opt/homebrew/bin:/usr/bin") == true)
        for key in ["PWD", "OLDPWD", "SHLVL", "TERM", "_"] { #expect(env[key] == nil, "\(key)") }
    }

    /// La shell può non rispondere: gli strumenti installati nei posti soliti si trovano lo stesso.
    @Test func usualFoldersAreOnThePathEvenWithoutAShell() {
        let env = ShellEnvironment.merged(base: ["PATH": "/usr/bin:/bin"], shell: nil, home: "/Users/u")
        #expect(env["PATH"] == "/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin:/Users/u/.local/bin")
        let again = ShellEnvironment.merged(base: env, shell: nil, home: "/Users/u")
        #expect(again["PATH"] == env["PATH"])
    }

    @Test func readsTheEnvironmentPastNoiseFromTheRcFiles() throws {
        let shell = try fakeShell(#"echo "benvenuto A=1"; exec /bin/sh -c "$2" sh"#)
        let env = ShellEnvironment.read(shell: shell, home: NSTemporaryDirectory())
        #expect(env?["PATH"] != nil)
        #expect(env?["A"] == nil)
    }

    @Test func aDaemonHoldingStdoutDoesNotDelayTheRead() throws {
        let shell = try fakeShell(#"sleep 30 & exec /bin/sh -c "$2" sh"#)
        let start = Date()
        #expect(ShellEnvironment.read(shell: shell, home: NSTemporaryDirectory())?["PATH"] != nil)
        #expect(Date().timeIntervalSince(start) < 2)
    }

    @Test func keepsValuesWithNewlines() {
        let data = Data("rumore\(ShellEnvironment.marker)A=uno\ndue\0B=x=y\0".utf8)
        #expect(ShellEnvironment.parse(data) == ["A": "uno\ndue", "B": "x=y"])
        #expect(ShellEnvironment.parse(Data("niente".utf8)) == nil)
    }

    @Test func aShellThatFailsGivesNothing() throws {
        #expect(ShellEnvironment.read(shell: try fakeShell("exit 1"), home: NSTemporaryDirectory()) == nil)
        #expect(ShellEnvironment.read(shell: "/nonesiste", home: NSTemporaryDirectory()) == nil)
    }

    @Test func aHungShellIsKilledInTime() throws {
        let shell = try fakeShell("trap '' TERM\nsleep 30")
        let start = Date()
        #expect(ShellEnvironment.read(shell: shell, home: NSTemporaryDirectory(), timeout: .milliseconds(200)) == nil)
        #expect(Date().timeIntervalSince(start) < 5)
    }
}
