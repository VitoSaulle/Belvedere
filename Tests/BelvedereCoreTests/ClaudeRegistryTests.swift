import Foundation
import Testing
@testable import BelvedereCore

@Suite struct ClaudeRegistryTests {
    private func entry(pid: Int, id: String = "s1", status: String = "idle", entrypoint: String = "cli") -> Data {
        Data(#"{"pid":\#(pid),"sessionId":"\#(id)","cwd":"/work","status":"\#(status)","entrypoint":"\#(entrypoint)","kind":"interactive"}"#.utf8)
    }

    @Test func readsOnlyLiveProcesses() throws {
        let tmp = TempDir()
        let dir = tmp.url.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try entry(pid: 10, id: "alive").write(to: dir.appendingPathComponent("10.json"))
        try entry(pid: 11, id: "dead").write(to: dir.appendingPathComponent("11.json"))
        try Data("non json".utf8).write(to: dir.appendingPathComponent("12.json"))
        try Data("segreto".utf8).write(to: dir.appendingPathComponent("10.abc.key"))
        let live = ClaudeRegistry.live(configDirs: [tmp.url.path], isAlive: { $0 == 10 })
        #expect(live.map(\.sessionID) == ["alive"])
        #expect(live.first?.cwd == "/work")
    }

    @Test func aMissingFolderIsEmpty() {
        #expect(ClaudeRegistry.live(configDirs: ["/non/esiste"], isAlive: { _ in true }).isEmpty)
    }

    @Test func onlyTheCLICanBeHandedOver() throws {
        #expect(try #require(ClaudeRegistry.parse(entry(pid: 1))).canHandOver)
        #expect(try !#require(ClaudeRegistry.parse(entry(pid: 1, entrypoint: "sdk-cli"))).canHandOver)
        #expect(try !#require(ClaudeRegistry.parse(entry(pid: 1, entrypoint: "claude-vscode"))).canHandOver)
    }

    @Test func aTurnInProgressIsNotBetweenTurns() throws {
        #expect(try #require(ClaudeRegistry.parse(entry(pid: 1))).isBetweenTurns)
        #expect(try !#require(ClaudeRegistry.parse(entry(pid: 1, status: "busy"))).isBetweenTurns)
        #expect(try !#require(ClaudeRegistry.parse(entry(pid: 1, status: "sconosciuto"))).isBetweenTurns)
    }

    @Test func aBackgroundShellIsBetweenTurnsButFlagged() throws {
        let process = try #require(ClaudeRegistry.parse(entry(pid: 1, status: "shell")))
        #expect(process.isBetweenTurns)
        #expect(process.hasBackgroundShell)
        #expect(try !#require(ClaudeRegistry.parse(entry(pid: 1))).hasBackgroundShell)
    }

    @Test func aReusedPIDIsNotAClaudeProcess() {
        let own = ProcessInfo.processInfo.processIdentifier
        #expect(!RunningProcesses.isRunning(own, named: "claude"))
    }
}

@Suite struct ClaudeAccountTests {
    @Test func readsTheAccountWithoutAnythingElse() throws {
        let data = Data(#"{"oauthAccount":{"accountUuid":"a1","emailAddress":"io@example.com"},"numStartups":3}"#.utf8)
        #expect(ClaudeAccount.parse(data) == ClaudeAccount(id: "a1", email: "io@example.com"))
    }

    @Test func noLoginMeansNoAccount() {
        #expect(ClaudeAccount.parse(Data(#"{"numStartups":3}"#.utf8)) == nil)
    }

    @Test func theDefaultProfileReadsFromHome() throws {
        let tmp = TempDir()
        let config = tmp.url.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        try Data(#"{"oauthAccount":{"accountUuid":"home","emailAddress":"h@example.com"}}"#.utf8)
            .write(to: tmp.url.appendingPathComponent(".claude.json"))
        try Data(#"{"oauthAccount":{"accountUuid":"dir","emailAddress":"d@example.com"}}"#.utf8)
            .write(to: config.appendingPathComponent(".claude.json"))
        let main = Profile(name: "P", agent: .claude, configDir: config.path, isDefault: true)
        let other = Profile(name: "A", agent: .claude, configDir: config.path)
        #expect(ClaudeAccount.read(profile: main, home: tmp.url)?.id == "home")
        #expect(ClaudeAccount.read(profile: other, home: tmp.url)?.id == "dir")
    }
}

@Suite struct AccountLimitsTests {
    @Test func limitsFollowTheAccountAcrossLogins() {
        var store = LiveSessionStore()
        let profile = UUID()
        let first = PlanLimits(fiveHour: LimitWindow(usedPercent: 90, resetsAt: nil), weekly: nil, observedAt: Date())
        store.apply(claudeLimits: first, profile: profile)
        store.switchAccount(profile: profile, from: "a", to: "b")
        #expect(store.claudeLimits[profile] == nil)
        store.switchAccount(profile: profile, from: "b", to: "a")
        #expect(store.claudeLimits[profile] == first)
    }
}
