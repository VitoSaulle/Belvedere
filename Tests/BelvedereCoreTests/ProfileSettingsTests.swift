import Foundation
import Testing
@testable import BelvedereCore

@Suite struct ProfileSettingsTests {
    let tmp = TempDir()
    let port: UInt16 = 47615
    let helpers = URL(fileURLWithPath: "/Users/v/Library/Application Support/Belvedere/bin")

    private func profile(_ name: String, _ agent: AgentKind = .claude, isDefault: Bool = false) -> Profile {
        Profile(name: name, agent: agent, configDir: tmp.url.appendingPathComponent(name).path, isDefault: isDefault)
    }

    @Test func filtersCredentialsAndBelvedere() {
        let user: [String: Any] = [
            "apiKeyHelper": "~/bin/key.sh",
            "forceLoginMethod": "claudeai",
            "env": ["ANTHROPIC_API_KEY": "sk", "MY_TOKEN": "t", "ANTHROPIC_BASE_URL": "http://x", "EDITOR": "vim"],
            "permissions": ["allow": ["Bash(ls)"]],
            "statusLine": ["type": "command", "command": "~/bin/line.sh"],
        ]
        let installed = ClaudeSettingsInstaller.install(into: user, helpers: helpers, port: port, permissionTimeout: nil)
        let out = ProfileSettings.filteredClaudeSettings(installed, port: port)
        #expect(Set(out.keys) == ["env", "permissions", "statusLine"])
        #expect(out["env"] as? [String: String] == ["EDITOR": "vim"])
        #expect((out["statusLine"] as? [String: Any])?["command"] as? String == "~/bin/line.sh")
        #expect(!ClaudeSettingsInstaller.isInstalled(out, port: port))
    }

    @Test func emptyEnvIsDropped() {
        let out = ProfileSettings.filteredClaudeSettings(["env": ["GITHUB_AUTH": "x", "ANTHROPIC_CUSTOM_HEADERS": "Authorization: Bearer t"],
                                                          "model": "opus"], port: port)
        #expect(Set(out.keys) == ["model"])
    }

    @Test func seedCopiesOnlyAllowedItems() throws {
        let main = profile("main", isDefault: true)
        _ = tmp.file("main/settings.json", #"{"model":"opus","apiKeyHelper":"x"}"#)
        _ = tmp.file("main/CLAUDE.md", "regole")
        _ = tmp.file("main/commands/x.md", "cmd")
        _ = tmp.file("main/projects/p/s.jsonl", "{}")
        _ = tmp.file("main/.credentials.json", "{}")
        _ = tmp.file("main/plugins/a.json", "{}")
        let work = profile("work")
        try ProfileSettings.seed(from: main, to: work, port: port)
        let fm = FileManager.default
        let dir = tmp.url.appendingPathComponent("work")
        #expect(fm.fileExists(atPath: dir.appendingPathComponent("CLAUDE.md").path))
        #expect(fm.fileExists(atPath: dir.appendingPathComponent("commands/x.md").path))
        #expect(!fm.fileExists(atPath: dir.appendingPathComponent("projects").path))
        #expect(!fm.fileExists(atPath: dir.appendingPathComponent(".credentials.json").path))
        #expect(!fm.fileExists(atPath: dir.appendingPathComponent("plugins").path))
        let settings = try SettingsFile(profile: work).read()
        #expect(settings["model"] as? String == "opus")
        #expect(settings["apiKeyHelper"] == nil)
    }

    @Test func seedCodexOnlyAgentsMD() throws {
        let main = profile("cmain", .codex, isDefault: true)
        _ = tmp.file("cmain/config.toml", "model = 'x'")
        _ = tmp.file("cmain/auth.json", "{}")
        _ = tmp.file("cmain/AGENTS.md", "regole")
        let work = profile("cwork", .codex)
        try ProfileSettings.seed(from: main, to: work, port: port)
        let names = try FileManager.default.contentsOfDirectory(atPath: tmp.url.appendingPathComponent("cwork").path)
        #expect(names == ["AGENTS.md"])
    }

    @Test func seedDoesNotOverwrite() throws {
        let main = profile("main", isDefault: true)
        _ = tmp.file("main/CLAUDE.md", "nuovo")
        _ = tmp.file("work/CLAUDE.md", "mio")
        try ProfileSettings.seed(from: main, to: profile("work"), port: port)
        #expect(try String(contentsOf: tmp.url.appendingPathComponent("work/CLAUDE.md"), encoding: .utf8) == "mio")
    }

    @Test func installIntoProfileFile() throws {
        let file = SettingsFile(profile: profile("work"))
        #expect(file.url.path == tmp.url.appendingPathComponent("work/settings.json").path)
        _ = tmp.file("work/settings.json", #"{"model":"opus"}"#)
        let updated = ClaudeSettingsInstaller.install(into: try file.read(), helpers: helpers, port: port, permissionTimeout: nil)
        let backup = try file.writeWithBackup(updated)
        #expect(ClaudeSettingsInstaller.isInstalled(try file.read(), port: port))
        #expect(backup?.deletingLastPathComponent().path == file.url.deletingLastPathComponent().path)
    }
}
