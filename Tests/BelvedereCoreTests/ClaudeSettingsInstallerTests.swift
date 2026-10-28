import Foundation
import Testing
@testable import BelvedereCore

@Suite struct ClaudeSettingsInstallerTests {
    let helpers = URL(fileURLWithPath: "/Users/v/Library/Application Support/Belvedere/bin")
    let port: UInt16 = 47615

    var original: [String: Any] {
        [
            "model": "opus",
            "permissions": ["allow": ["Bash(npm test)"], "deny": []],
            "hooks": ["PreToolUse": [["matcher": "Bash", "hooks": [["type": "command", "command": "~/bin/guard.sh"]]]]],
        ]
    }

    private func install(_ s: [String: Any]) -> [String: Any] {
        ClaudeSettingsInstaller.install(into: s, helpers: helpers, port: port, permissionTimeout: 590)
    }

    private func groups(_ s: [String: Any], _ event: String) -> [[String: Any]] {
        (s["hooks"] as? [String: Any])?[event] as? [[String: Any]] ?? []
    }

    @Test func preservesForeignKeys() {
        let s = install(original)
        #expect(s["model"] as? String == "opus")
        #expect(NSDictionary(dictionary: s["permissions"] as! [String: Any]).isEqual(to: original["permissions"] as! [String: Any]))
        let pre = groups(s, "PreToolUse")
        #expect(pre.count == 2)
        #expect(pre.first?["matcher"] as? String == "Bash")
        #expect(ClaudeSettingsInstaller.isInstalled(s, port: port))
        #expect(!ClaudeSettingsInstaller.isInstalled(original, port: port))
    }

    @Test func writesExpectedHooks() {
        let s = install(original)
        let stop = groups(s, "Stop").first?["hooks"] as? [[String: Any]]
        #expect(stop?.first?["type"] as? String == "http")
        #expect(stop?.first?["url"] as? String == "http://127.0.0.1:47615/hooks/Stop")
        let perm = groups(s, "PermissionRequest").first?["hooks"] as? [[String: Any]]
        #expect(perm?.first?["timeout"] as? Int == 600)
        let start = groups(s, "SessionStart").first?["hooks"] as? [[String: Any]]
        #expect(start?.first?["type"] as? String == "command")
        #expect(start?.first?["command"] as? String == "'/Users/v/Library/Application Support/Belvedere/bin/belvedere-hook' SessionStart")
        for event in ClaudeSettingsInstaller.httpEvents + ClaudeSettingsInstaller.commandEvents {
            #expect(!groups(s, event).isEmpty, "\(event)")
        }
        let line = s["statusLine"] as? [String: Any]
        #expect(line?["command"] as? String == "'/Users/v/Library/Application Support/Belvedere/bin/belvedere-statusline'")
    }

    @Test func idempotent() {
        let once = install(original)
        #expect(NSDictionary(dictionary: install(once)).isEqual(to: once))
    }

    @Test func wrapsExistingStatusLine() {
        var s = original
        s["statusLine"] = ["type": "command", "command": "~/bin/my-line.sh", "padding": 1]
        let installed = install(s)
        let line = installed["statusLine"] as? [String: Any]
        let encoded = Data("~/bin/my-line.sh".utf8).base64EncodedString()
        #expect(line?["command"] as? String == "'/Users/v/Library/Application Support/Belvedere/bin/belvedere-statusline' --wrap \(encoded)")
        #expect(line?["padding"] as? Int == 1)
        let restored = ClaudeSettingsInstaller.uninstall(from: installed, port: port)
        #expect(NSDictionary(dictionary: restored).isEqual(to: s))
    }

    @Test func uninstallRemovesOnlyOurs() {
        let restored = ClaudeSettingsInstaller.uninstall(from: install(original), port: port)
        #expect(NSDictionary(dictionary: restored).isEqual(to: original))
        let fromEmpty = ClaudeSettingsInstaller.uninstall(from: install([:]), port: port)
        #expect(fromEmpty.isEmpty)
    }

    @Test func backupWritten() throws {
        let tmp = TempDir()
        let url = tmp.file("settings.json", #"{"model":"opus"}"#)
        let file = SettingsFile(url: url)
        #expect(try file.read()["model"] as? String == "opus")
        let backup = try #require(try file.writeWithBackup(["model": "sonnet"]))
        #expect(backup.lastPathComponent.hasPrefix("settings.json.belvedere-"))
        #expect(backup.pathExtension == "bak")
        #expect(try String(contentsOf: backup, encoding: .utf8) == #"{"model":"opus"}"#)
        #expect(try file.read()["model"] as? String == "sonnet")
        #expect(try SettingsFile(url: tmp.url.appendingPathComponent("none.json")).read().isEmpty)
    }

    @Test func backupsInSameSecondDoNotOverwrite() throws {
        let tmp = TempDir()
        let url = tmp.file("settings.json", #"{"v":1}"#)
        let file = SettingsFile(url: url)
        let now = Date()
        let first = try #require(try file.writeWithBackup(["v": 2], now: now))
        let second = try #require(try file.writeWithBackup(["v": 3], now: now))
        #expect(first != second)
        #expect(try String(contentsOf: first, encoding: .utf8) == #"{"v":1}"#)
        #expect(try SettingsFile(url: second).read()["v"] as? Int == 2)
    }

    @Test func installsHelpersFromBundle() throws {
        let tmp = TempDir()
        _ = tmp.file("Fake.app/Contents/Helpers/belvedere-hook", "#!/bin/sh\n")
        _ = tmp.file("Fake.app/Contents/Helpers/belvedere-statusline", "#!/bin/sh\n")
        let bundle = try #require(Bundle(url: tmp.url.appendingPathComponent("Fake.app")))
        let bin = try ClaudeSettingsInstaller.installHelpers(from: bundle, to: tmp.url.appendingPathComponent("bin"))
        for name in ["belvedere-hook", "belvedere-statusline"] {
            let path = bin.appendingPathComponent(name).path
            #expect(FileManager.default.isExecutableFile(atPath: path), "\(name)")
        }
    }
}
