import Foundation
import Testing
@testable import BelvedereCore

@Suite struct LocalCommandTests {
    private let dir = TempDir()
    private var config: String { dir.url.appendingPathComponent("config").path }
    private var project: String { dir.url.appendingPathComponent("progetto").path }

    private func report(_ command: LocalCommand, state: ChatState = ChatState()) -> String {
        command.report(state, folder: project, configDir: config)
    }

    @Test func routesTheScreensOfTheTerminal() {
        for command in LocalCommand.allCases {
            #expect(SlashRoute.route("/\(command.rawValue)", terminalCommands: []) == .local(command))
        }
        #expect(SlashRoute.route("/tasks", terminalCommands: []) == .send("/list-agents"))
        #expect(SlashRoute.route("/theme", terminalCommands: []) == .theme(nil))
        #expect(SlashRoute.route("/theme scuro", terminalCommands: []) == .theme("scuro"))
        for name in LocalCommand.allCases.map(\.rawValue) + ["tasks", "theme"] {
            #expect(SlashRoute.nativeCommands.contains { $0.name == name }, "\(name)")
        }
    }

    @Test func permissionsListRulesPerFile() {
        _ = dir.file("config/settings.json", #"{"permissions":{"allow":["Bash(ls)"],"deny":["Read(.env)"]}}"#)
        _ = dir.file("progetto/.claude/settings.local.json", "non json")
        var state = ChatState()
        state.permissionMode = "plan"
        let text = report(.permissions, state: state)
        #expect(text.contains("Modalità: `plan`"))
        #expect(text.contains("- Consenti: `Bash(ls)`"))
        #expect(text.contains("- Nega: `Read(.env)`"))
        #expect(text.contains("JSON non valido"))
    }

    @Test func hooksShowEventAndCommand() {
        _ = dir.file("config/settings.json", #"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"say fine"}]}]}}"#)
        #expect(report(.hooks).contains("- Stop: `say fine`"))
    }

    @Test func memoryListsOnlyFilesThatExist() {
        _ = dir.file("config/CLAUDE.md")
        _ = dir.file("progetto/CLAUDE.local.md")
        let slug = project.replacingOccurrences(of: "[^a-zA-Z0-9]", with: "-", options: .regularExpression)
        _ = dir.file("config/projects/\(slug)/memory/MEMORY.md")
        let text = report(.memory)
        #expect(text.contains("CLAUDE.local.md"))
        #expect(text.contains("MEMORY.md"))
        #expect(!text.contains(".claude/CLAUDE.md"))
    }

    @Test func skillsPreferTheInitListAndKeepDescriptions() {
        var state = ChatState()
        state.commands = [SlashCommand(name: "pdf", description: "Lavora sui PDF", argumentHint: ""),
                          SlashCommand(name: "clear", description: "", argumentHint: "")]
        #expect(report(.skills, state: state).contains("`clear`"))
        state.skills = ["pdf"]
        let text = report(.skills, state: state)
        #expect(text.contains("- `pdf`: Lavora sui PDF"))
        #expect(!text.contains("clear"))
    }

    @Test func statusAndStatusLine() {
        var state = ChatState()
        state.model = "claude-opus-5-5"
        state.mcpServers = [MCPServerInfo(name: "ado", status: "connected")]
        let status = report(.status, state: state)
        #expect(status.contains("`claude-opus-5-5`") && status.contains("MCP `ado`: connected"))
        #expect(report(.statusline).contains("Nessuna configurata"))
        _ = dir.file("config/settings.json", #"{"statusLine":{"type":"command","command":"mio.sh"}}"#)
        #expect(report(.statusline).contains("`mio.sh`"))
    }

    @Test func localReplyShowsAQuestionAndAnAnswerWithoutStartingATurn() {
        var state = ChatState()
        state.addLocalReply(command: "/status", text: "ok")
        #expect(state.items.count == 2)
        #expect(state.status == .idle)
    }
}
