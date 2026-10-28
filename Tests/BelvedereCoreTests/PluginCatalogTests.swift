import Foundation
import Testing
@testable import BelvedereCore

@Suite struct PluginCatalogTests {
    private let listing = #"""
    {"installed":[
      {"id":"superpowers@claude-plugins-official","version":"7.0.0","scope":"user","enabled":true,"installPath":"/x","projectEnabled":false},
      {"id":"superpowers@claude-plugins-official","version":"7.0.0","scope":"project","enabled":false,"projectPath":"/Users/u/work/ASMB","projectEnabled":false}
    ],"available":[
      {"pluginId":"frontend-design@claude-plugins-official","name":"frontend-design","description":"Interfacce curate","marketplaceName":"claude-plugins-official","installCount":120},
      {"pluginId":"superpowers@claude-plugins-official","name":"superpowers","description":"Skill","marketplaceName":"claude-plugins-official","installCount":9000},
      {"pluginId":"zeta@altro","name":"zeta","marketplaceName":"altro"}
    ]}
    """#

    @Test func decodesInstalledAndAvailable() throws {
        let catalog = try PluginCatalog.decode(Data(listing.utf8))
        #expect(catalog.installed.count == 2)
        #expect(catalog.installed[1].scope == "project")
        #expect(catalog.installed[1].projectPath == "/Users/u/work/ASMB")
        #expect(catalog.installed[0].name == "superpowers")
        #expect(catalog.installed[0].marketplace == "claude-plugins-official")
        #expect(catalog.installed[0].id != catalog.installed[1].id)
        #expect(catalog.available.map(\.id) == ["frontend-design@claude-plugins-official", "superpowers@claude-plugins-official", "zeta@altro"])
        #expect(catalog.available[2].description == "")
    }

    /// Nella ricerca i già installati restano fuori e vince il più installato.
    @Test func searchSkipsInstalledAndSortsByPopularity() throws {
        let catalog = try PluginCatalog.decode(Data(listing.utf8))
        #expect(catalog.search("").map(\.name) == ["frontend-design", "zeta"])
        #expect(catalog.search("CURATE").map(\.name) == ["frontend-design"])
    }

    @Test func commandArguments() {
        #expect(PluginCommand.arguments(.install, plugin: "a@m", scope: "user") == ["plugin", "install", "a@m", "--json", "-s", "user"])
        #expect(PluginCommand.arguments(.disable, plugin: "a@m", scope: "project") == ["plugin", "disable", "a@m", "--json", "-s", "project"])
        #expect(PluginCommand.arguments(.update, plugin: "a@m", scope: "user") == ["plugin", "update", "a@m", "--json", "-s", "user"])
        #expect(PluginCommand.listArguments == ["plugin", "list", "--available", "--json"])
    }

    @Test func resultLine() {
        let done = PluginResult.decode(Data(#"{"command":"enable","outcome":"enabled","plugin":"a@m","message":"ok"}"#.utf8), exitCode: 0)
        #expect(done.succeeded)
        let already = PluginResult.decode(Data(#"{"command":"enable","outcome":"failed","plugin":"a@m","message":"già","alreadyInGoalState":true}"#.utf8), exitCode: 1)
        #expect(already.succeeded)
        let failed = PluginResult.decode(Data("✘ boom\n".utf8), exitCode: 1)
        #expect(!failed.succeeded)
        #expect(failed.message == "✘ boom")
        // Un plugin che si installa eseguendo un comando del marketplace: va confermato da una persona, nel terminale.
        let command = PluginResult.decode(Data(#"{"command":"install","outcome":"failed","plugin":"a@m","message":"conferma","shownCommand":{"sha256":"abc","command":"curl x | sh"}}"#.utf8), exitCode: 1)
        #expect(command.needsTerminal)
        #expect(!command.succeeded)
    }
}
