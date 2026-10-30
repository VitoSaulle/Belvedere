import Foundation
import Testing
@testable import BelvedereCore

@Suite struct LaunchOptionsTests {
    /// I preset salvati prima di Codex non hanno `agent`: restano sessioni Claude.
    @Test func decodesOldPresetsAsClaude() throws {
        let json = Data(#"{"folder":"/p","permission":"ask","worktree":false}"#.utf8)
        let options = try JSONDecoder().decode(LaunchOptions.self, from: json)
        #expect(options.agent == .claude)
        #expect(options.folder == "/p")
    }

    @Test func roundTripsAgent() throws {
        let options = LaunchOptions(folder: "/p", agent: .codex)
        let back = try JSONDecoder().decode(LaunchOptions.self, from: JSONEncoder().encode(options))
        #expect(back.agent == .codex)
    }

    @Test func resumingKeepsThePermissionModeOfTheSession() {
        var s = SessionSnapshot(id: "a", agent: .claude, cwd: "/p")
        s.permissionMode = "bypassPermissions"
        let o = LaunchOptions.resuming(s)
        #expect(o.permission == .skip)
        #expect(ClaudeCommand.arguments(o, isGitRepository: false).contains("--dangerously-skip-permissions"))
        s.permissionMode = "acceptEdits"
        #expect(LaunchOptions.resuming(s).permission == .acceptEdits)
    }

    @Test func anUnknownModeGrantsNothing() {
        #expect(PermissionChoice(claudeMode: "default") == .ask)
        #expect(PermissionChoice(claudeMode: "nuova") == .ask)
        #expect(PermissionChoice(claudeMode: nil) == .ask)
    }

    @Test func resumingSnapshotKeepsAgent() {
        let s = SessionSnapshot(id: "t1", agent: .codex, cwd: "/p")
        #expect(LaunchOptions.resuming(s).agent == .codex)
    }

    @Test func chatStateSnapshotCarriesAgent() {
        var state = ChatState(agent: .codex)
        state.sessionID = "t1"
        #expect(state.snapshot(launchedAt: nil)?.agent == .codex)
    }

    @Test func exitMessageNamesTheAgent() {
        var state = ChatState(agent: .codex)
        state.processExited(code: 1, stderr: "", now: Date())
        #expect(state.lastError == "Codex si è chiuso con il codice 1.")
        #expect(AgentKind.claude.productName == "Claude Code")
    }

    @Test func profileIDRoundTripAndLegacy() throws {
        let id = UUID()
        let o = LaunchOptions(folder: "/p", profileID: id)
        #expect(try JSONDecoder().decode(LaunchOptions.self, from: JSONEncoder().encode(o)).profileID == id)
        let old = Data(#"{"folder":"/p","permission":"ask","worktree":false}"#.utf8)
        #expect(try JSONDecoder().decode(LaunchOptions.self, from: old).profileID == nil)
        var s = SessionSnapshot(id: "t1", agent: .claude, cwd: "/p")
        s.profileID = id
        #expect(LaunchOptions.resuming(s).profileID == id)
    }
}
