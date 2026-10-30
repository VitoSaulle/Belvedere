import Foundation
import Testing
@testable import BelvedereCore

@Suite struct SlashRouteTests {
    @Test func clearAndModel() {
        #expect(SlashRoute.route("/clear", terminalCommands: []) == .clear)
        #expect(SlashRoute.route("  /clear  ", terminalCommands: []) == .clear)
        #expect(SlashRoute.route("/model sonnet", terminalCommands: []) == .setModel("sonnet"))
        #expect(SlashRoute.route("/model", terminalCommands: []) == .send("/model"))
    }

    @Test func terminalOnlyFromInit() {
        #expect(SlashRoute.route("/doctor", terminalCommands: ["doctor"]) == .terminalOnly("doctor"))
    }

    @Test func accountCommandsAreTerminalOnly() {
        for name in ["login", "logout", "exit", "quit"] {
            #expect(SlashRoute.route("/\(name) x", terminalCommands: []) == .terminalOnly(name))
        }
    }

    @Test func resumeOpensThePicker() {
        #expect(SlashRoute.route("/resume", terminalCommands: []) == .resume(query: nil))
        #expect(SlashRoute.route("/resume bug login", terminalCommands: ["resume"]) == .resume(query: "bug login"))
    }

    @Test func plainTextAndCustomCommandsAreSent() {
        #expect(SlashRoute.route("ciao /clear", terminalCommands: []) == .send("ciao /clear"))
        #expect(SlashRoute.route("/superpowers:brainstorming idea", terminalCommands: ["doctor"])
                == .send("/superpowers:brainstorming idea"))
        #expect(SlashRoute.route("/context", terminalCommands: []) == .send("/context"))
    }

    @Test func slashCompletionsRankPrefixFirst() {
        let commands = ["review", "code-review", "compact", "context", "cost"].map {
            SlashCommand(name: $0, description: "", argumentHint: "")
        }
        #expect(Completions.slash("co", in: commands).map(\.name) == ["code-review", "compact", "context", "cost"])
        #expect(Completions.slash("rev", in: commands).map(\.name) == ["review", "code-review"])
        #expect(Completions.slash("", in: commands).map(\.name) == ["code-review", "compact", "context", "cost", "review"])
        let many = (0..<30).map { SlashCommand(name: "c\($0)", description: "", argumentHint: "") }
        #expect(Completions.slash("c", in: many).count == 12)
    }

    @Test func fileCompletionsSkipIgnoredFolders() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        for path in ["src/App.swift", "node_modules/app.js", ".git/HEAD", "build/app.o", ".hidden/app.txt", "docs/note.md"] {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: url)
        }
        #expect(Completions.files("app", root: root) == ["src/App.swift"])
        #expect(Completions.files("", root: root, limit: 1).count == 1)
    }

    /// `/plugin` apre il pannello nativo, anche con argomenti (`/plugin install x`).
    @Test func pluginOpensThePanel() {
        #expect(SlashRoute.route("/plugin", terminalCommands: []) == .plugins)
        #expect(SlashRoute.route("/plugins install x", terminalCommands: ["plugin"]) == .plugins)
    }
}
