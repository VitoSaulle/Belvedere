import Foundation
import Testing
@testable import BelvedereCore

@Suite struct CodexCommandTests {
    @Test func locatesHomebrewBinary() {
        let found = CodexCommand.locateBinary(home: "/Users/u", path: "/usr/bin") { $0 == "/opt/homebrew/bin/codex" }
        #expect(found == "/opt/homebrew/bin/codex")
        #expect(CodexCommand.locateBinary(home: "/Users/u", path: "/custom") { $0 == "/custom/codex" } == "/custom/codex")
    }

    @Test(arguments: [
        (PermissionChoice.ask, "untrusted", "workspace-write"),
        (.acceptEdits, "on-request", "workspace-write"),
        (.auto, "never", "workspace-write"),
        (.plan, "on-request", "read-only"),
        (.skip, "never", "danger-full-access"),
    ])
    func mapsPermissions(choice: PermissionChoice, approval: String, sandbox: String) {
        let params = CodexCommand.threadParams(LaunchOptions(folder: "/p", agent: .codex, permission: choice))
        #expect(params["approvalPolicy"]?.stringValue == approval)
        #expect(params["sandbox"]?.stringValue == sandbox)
        #expect(params["cwd"]?.stringValue == "/p")
    }

    /// Il modello locale passa per i parametri del thread, non per `~/.codex/config.toml`.
    @Test func localModelUsesBuiltInLMStudioProvider() {
        let o = LaunchOptions(folder: "/p", agent: .codex, local: LocalModelChoice(id: "qwen/qwen3-4b-2507", contextLength: 32768))
        let params = CodexCommand.threadParams(o)
        #expect(params["modelProvider"]?.stringValue == "lmstudio")
        #expect(params["model"]?.stringValue == "qwen/qwen3-4b-2507")
    }

    /// In cloud senza modello scelto vale la configurazione di Codex.
    @Test func cloudDefaultLeavesModelToCodex() {
        let params = CodexCommand.threadParams(LaunchOptions(folder: "/p", agent: .codex))
        #expect(params["model"] == nil)
        #expect(params["modelProvider"] == nil)
    }

    @Test func previewShowsEquivalentCommand() {
        let o = LaunchOptions(folder: "/p", agent: .codex, local: LocalModelChoice(id: "qwen", contextLength: nil))
        #expect(CodexCommand.preview(o) == "cd '/p' && codex --oss --local-provider lmstudio -m qwen -a untrusted -s workspace-write")
        var skip = LaunchOptions(folder: "/p", agent: .codex, model: "gpt-5", permission: .skip)
        #expect(CodexCommand.preview(skip) == "cd '/p' && codex -m gpt-5 --dangerously-bypass-approvals-and-sandbox")
        skip.resumeID = "t1"
        #expect(CodexCommand.terminalArguments(skip) == ["resume", "t1", "-m", "gpt-5", "--dangerously-bypass-approvals-and-sandbox"])
    }

    @Test func terminalScriptRunsCodexResume() {
        let script = TerminalHandoff.script(cwd: "/p", arguments: ["/opt/homebrew/bin/codex", "resume", "t1"], pidFile: "/s/t1.pid")
        #expect(script.hasSuffix("cd '/p' && exec '/opt/homebrew/bin/codex' 'resume' 't1'\n"))
        #expect(script.contains("echo $$ > '/s/t1.pid'"))
    }
}
