import Foundation
import Testing
@testable import BelvedereCore

@Suite struct ClaudeCommandTests {
    @Test func baseFlagsAlwaysFirst() {
        let args = ClaudeCommand.arguments(LaunchOptions(folder: "/p"), isGitRepository: false)
        #expect(args == ClaudeCommand.baseArguments)
        #expect(ClaudeCommand.baseArguments == ["-p", "--input-format", "stream-json", "--output-format", "stream-json",
                                                "--verbose", "--include-partial-messages", "--replay-user-messages",
                                                "--permission-prompt-tool", "stdio"])
        for choice in PermissionChoice.allCases {
            #expect(!ClaudeCommand.arguments(LaunchOptions(folder: "/p", permission: choice), isGitRepository: true).contains("--bare"))
        }
    }

    private func contains(_ args: [String], _ pair: [String]) -> Bool {
        args.indices.contains { i in Array(args[i..<min(args.count, i + pair.count)]) == pair }
    }

    @Test func permissionModes() {
        func args(_ c: PermissionChoice) -> [String] { ClaudeCommand.arguments(LaunchOptions(folder: "/p", permission: c), isGitRepository: false) }
        #expect(contains(args(.acceptEdits), ["--permission-mode", "acceptEdits"]))
        #expect(contains(args(.auto), ["--permission-mode", "auto"]))
        #expect(contains(args(.plan), ["--permission-mode", "plan"]))
        #expect(args(.skip).contains("--dangerously-skip-permissions"))
        #expect(!args(.skip).contains("--permission-mode"))
        #expect(!args(.ask).contains("--permission-mode"))
        #expect(!args(.ask).contains("--dangerously-skip-permissions"))
        #expect(PermissionChoice.allCases.map(\.label) == ["Chiedi", "Accetta modifiche", "Auto", "Solo piano", "Salta permessi"])
    }

    @Test func modelResumeNameWorktree() {
        let o = LaunchOptions(folder: "/p", model: "sonnet", worktree: true, resumeID: "abc", name: "Prova")
        let args = ClaudeCommand.arguments(o, isGitRepository: true)
        #expect(contains(args, ["--model", "sonnet"]))
        #expect(contains(args, ["--resume", "abc"]))
        #expect(contains(args, ["--name", "Prova"]))
        #expect(args.contains("--worktree"))
        #expect(!ClaudeCommand.arguments(o, isGitRepository: false).contains("--worktree"))
    }

    @Test func localModelEnvironment() {
        let o = LaunchOptions(folder: "/p", local: LocalModelChoice(id: "qwen3-coder-30b", contextLength: 32768))
        let base = ["PATH": "/usr/bin", "HOME": "/Users/u", "CLAUDECODE": "1", "CLAUDE_CODE_ENTRYPOINT": "cli",
                    "CLAUDE_CODE_SESSION_ID": "x", "CLAUDE_PID": "9", "CLAUDE_EFFORT": "high"]
        let env = ClaudeCommand.environment(o, base: base)
        #expect(env["ANTHROPIC_BASE_URL"] == "http://localhost:1234")
        #expect(env["ANTHROPIC_AUTH_TOKEN"] == "lmstudio")
        #expect(env["ANTHROPIC_MODEL"] == "qwen3-coder-30b")
        #expect(env["ANTHROPIC_SMALL_FAST_MODEL"] == "qwen3-coder-30b")
        #expect(env["ANTHROPIC_DEFAULT_HAIKU_MODEL"] == "qwen3-coder-30b")
        #expect(env["CLAUDE_CODE_ATTRIBUTION_HEADER"] == "0")
        for key in ["CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_SESSION_ID", "CLAUDE_PID", "CLAUDE_EFFORT"] {
            #expect(env[key] == nil, "\(key)")
        }
        #expect(env["PATH"] == "/usr/bin")
        #expect(env["HOME"] == "/Users/u")
        #expect(contains(ClaudeCommand.arguments(o, isGitRepository: false), ["--model", "qwen3-coder-30b"]))
    }

    @Test func userSettingsSurviveParentSessionCleanup() {
        let base = ["CLAUDE_CODE_USE_BEDROCK": "1", "CLAUDE_CODE_MAX_OUTPUT_TOKENS": "8000",
                    "CLAUDE_CODE_SSE_PORT": "1", "CLAUDE_CODE_EXECPATH": "/x", "CLAUDE_CODE_CHILD_SESSION": "1",
                    "CLAUDE_CODE_SESSION_ATTENDED": "1", "CLAUDE_CODE_BRIDGE_SESSION_ID": "b",
                    "CLAUDE_CODE_MESSAGING_SOCKET": "/s", "CLAUDE_CODE_MESSAGING_TOKEN": "t"]
        let env = ClaudeCommand.environment(LaunchOptions(folder: "/p"), base: base)
        #expect(env == ["CLAUDE_CODE_USE_BEDROCK": "1", "CLAUDE_CODE_MAX_OUTPUT_TOKENS": "8000"])
    }

    @Test func cloudEnvironmentHasNoAnthropicOverrides() {
        let env = ClaudeCommand.environment(LaunchOptions(folder: "/p"), base: ["PATH": "/bin", "ANTHROPIC_LOG": "debug"])
        #expect(env == ["PATH": "/bin", "ANTHROPIC_LOG": "debug"])
    }

    /// Una sessione genitore in modalità bare non deve passarla al figlio: Belvedere non lancia mai `--bare`.
    @Test func bareModeIsNotInherited() {
        let env = ClaudeCommand.environment(LaunchOptions(folder: "/p"), base: ["PATH": "/bin", "CLAUDE_CODE_SIMPLE": "1"])
        #expect(env == ["PATH": "/bin"])
    }

    @Test func skipNeverCarriedOver() {
        let next = LaunchOptions(folder: "/p", permission: .skip, resumeID: "x").forNextLaunch
        #expect(next.permission == .ask)
        #expect(next.resumeID == nil)
        #expect(next.folder == "/p")
    }

    @Test func previewQuotesSpaces() {
        let o = LaunchOptions(folder: "/Users/u/Il mio progetto", model: "sonnet")
        let preview = ClaudeCommand.preview(o, isGitRepository: false)
        #expect(preview.hasPrefix("cd '/Users/u/Il mio progetto' && claude "))
        #expect(preview.contains("--model sonnet"))
        #expect(!preview.contains("stream-json"))
    }

    @Test func locatesBinaryInOrder() {
        let home = "/Users/u"
        let all: Set<String> = ["/Users/u/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude",
                                "/Users/u/.claude/local/claude", "/custom/claude"]
        func locate(_ available: Set<String>) -> String? {
            ClaudeCommand.locateBinary(home: home, path: "/custom:/bin", isExecutable: { available.contains($0) })
        }
        #expect(locate(all) == "/Users/u/.local/bin/claude")
        #expect(locate(all.subtracting(["/Users/u/.local/bin/claude"])) == "/opt/homebrew/bin/claude")
        #expect(locate(["/usr/local/bin/claude", "/custom/claude"]) == "/usr/local/bin/claude")
        #expect(locate(["/Users/u/.claude/local/claude", "/custom/claude"]) == "/Users/u/.claude/local/claude")
        #expect(locate(["/custom/claude"]) == "/custom/claude")
        #expect(locate([]) == nil)
    }

    @Test func gitRepositoryWalksUp() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let sub = root.appendingPathComponent("a/b")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(!GitInfo.isRepository(sub.path))
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)
        #expect(GitInfo.isRepository(sub.path))
    }

    @Test func contextWarning() {
        let warning = LaunchAdvice.contextWarning(32768)
        #expect(warning?.contains("32.768") == true)
        #expect(warning?.contains("20k") == true)
        #expect(LaunchAdvice.contextWarning(131072) == nil)
        #expect(LaunchAdvice.contextWarning(nil) == nil)
    }

    @Test func handoffScriptQuotes() {
        let script = TerminalHandoff.script(cwd: "/p/l'app", sessionID: "abc", binary: "/opt/homebrew/bin/claude",
                                            pidFile: "/s/abc.pid")
        #expect(script.hasPrefix("#!/bin/zsh\n"))
        #expect(script.contains("echo $$ > '/s/abc.pid'"))
        #expect(script.contains("cd '/p/l'\\''app'"))
        #expect(script.contains("exec '/opt/homebrew/bin/claude' '--resume' 'abc'"))
    }

    @Test func handoffIsRunningWhileItsProcessLives() throws {
        let tmp = TempDir()
        let file = tmp.url.appendingPathComponent("abc.pid")
        #expect(!TerminalHandoff.isRunning(pidFile: file))
        try "\(getpid())\n".write(to: file, atomically: true, encoding: .utf8)
        #expect(TerminalHandoff.isRunning(pidFile: file))
        try "999999".write(to: file, atomically: true, encoding: .utf8)
        #expect(!TerminalHandoff.isRunning(pidFile: file))
    }

    @Test func terminalHandoffKeepsSkippedPermissions() {
        let script = TerminalHandoff.script(cwd: "/p", sessionID: "abc", binary: "/b/claude", permission: .skip, pidFile: "/t/a.pid")
        #expect(script.contains("'--resume' 'abc' '--dangerously-skip-permissions'"))
    }

    @Test func resumingLeavesTheWorktreeWhereItIs() {
        let o = LaunchOptions(folder: "/repo", permission: .acceptEdits, worktree: true)
        let r = o.resuming("abc", cwd: "/repo/.claude/worktrees/x")
        #expect(r.folder == "/repo/.claude/worktrees/x")
        #expect(r.worktree == false)
        #expect(r.resumeID == "abc")
        #expect(r.permission == .acceptEdits)
    }

    @Test func resumingALocalSessionStaysLocal() {
        var s = SessionSnapshot(id: "abc", agent: .claude, cwd: "/p")
        s.model = "qwen3-coder"
        s.isLocalModel = true
        s.contextWindow = 32768
        let o = LaunchOptions.resuming(s)
        #expect(o.local == LocalModelChoice(id: "qwen3-coder", contextLength: 32768))
        #expect(o.resumeID == "abc")
        #expect(o.folder == "/p")
    }

    @Test func handoffKeepsTheLocalModel() {
        let script = TerminalHandoff.script(cwd: "/p", sessionID: "abc", binary: "/b/claude", pidFile: "/s/abc.pid",
                                            environment: ["ANTHROPIC_BASE_URL": "http://localhost:1234"])
        #expect(script.contains("export ANTHROPIC_BASE_URL='http://localhost:1234'"))
    }

    @Test func presetsStoreSafeOptions() {
        let preset = LaunchPreset(name: "Svelto", options: LaunchOptions(folder: "/p", permission: .skip, resumeID: "x"))
        #expect(preset.options.permission == .ask)
        #expect(preset.options.resumeID == nil)
    }

    // MARK: - Profili

    static let extra = Profile(name: "L", agent: .claude, configDir: "/Users/v/.claude-l")
    static let main = Profile(name: "Principale", agent: .claude, configDir: "/Users/v/.claude", isDefault: true)

    @Test func profileEnvironment() {
        let base = ["CLAUDE_CONFIG_DIR": "/x", "PATH": "/bin"]
        let o = LaunchOptions(folder: "/p")
        #expect(ClaudeCommand.environment(o, base: base, profile: Self.extra)["CLAUDE_CONFIG_DIR"] == "/Users/v/.claude-l")
        #expect(ClaudeCommand.environment(o, base: base, profile: Self.main)["CLAUDE_CONFIG_DIR"] == nil)
        #expect(ClaudeCommand.environment(o, base: base, profile: nil)["CLAUDE_CONFIG_DIR"] == nil)
        #expect(ClaudeCommand.environment(o, base: base, profile: Self.extra)["PATH"] == "/bin")
    }

    @Test func previewShowsProfile() {
        let p = Profile(name: "A", agent: .claude, configDir: "/tmp/a b")
        let preview = ClaudeCommand.preview(LaunchOptions(folder: "/p"), isGitRepository: false, profile: p)
        #expect(preview.hasPrefix("cd '/p' && CLAUDE_CONFIG_DIR='/tmp/a b' claude"))
        #expect(!ClaudeCommand.preview(LaunchOptions(folder: "/p"), isGitRepository: false, profile: Self.main).contains("CLAUDE_CONFIG_DIR"))
    }

    @Test func loginScript() {
        let script = TerminalHandoff.loginScript(profile: Self.extra, binary: "/bin/claude")
        #expect(script.hasPrefix("#!/bin/zsh\n"))
        #expect(script.contains("export CLAUDE_CONFIG_DIR='/Users/v/.claude-l'"))
        #expect(script.hasSuffix("exec '/bin/claude' '/login'\n"))
        #expect(!TerminalHandoff.loginScript(profile: Self.main, binary: "/bin/claude").contains("export"))
    }
}
