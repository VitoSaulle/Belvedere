import Foundation
import Testing
@testable import BelvedereCore

@Suite struct ProfileTests {
    let home = URL(fileURLWithPath: "/Users/v", isDirectory: true)

    @Test func initialHasOneDefaultPerAgent() {
        let set = ProfileSet.initial(home: home)
        #expect(set.profiles.count == 2)
        #expect(set.profiles.allSatisfy { $0.isDefault && $0.name == "Principale" })
        #expect(set.active(.claude).configDir == "/Users/v/.claude")
        #expect(set.active(.codex).configDir == "/Users/v/.codex")
        #expect(!set.hasChoice(.claude))
    }

    @Test func transcriptRootsPerAgent() {
        let set = ProfileSet.initial(home: home)
        #expect(set.active(.claude).transcriptRoot.path == "/Users/v/.claude/projects")
        #expect(set.active(.codex).transcriptRoot.path == "/Users/v/.codex/sessions")
        #expect(set.active(.claude).environmentKey == "CLAUDE_CONFIG_DIR")
        #expect(set.active(.codex).environmentKey == "CODEX_HOME")
    }

    @Test func removeKeepsDefaultsAndResetsActive() {
        var set = ProfileSet.initial(home: home)
        let work = Profile(name: "Lavoro", agent: .claude, configDir: "/Users/v/.claude-lavoro")
        set.add(work)
        set.setActive(work.id)
        #expect(set.active(.claude) == work)
        #expect(set.hasChoice(.claude))
        set.remove(work.id)
        #expect(set.active(.claude).isDefault)
        let main = set.defaultProfile(.claude)
        set.remove(main.id)
        #expect(set.profiles.count == 2)
    }

    @Test func setActiveIsPerAgent() {
        var set = ProfileSet.initial(home: home)
        let codex = set.active(.codex)
        let work = Profile(name: "Lavoro", agent: .claude, configDir: "/Users/v/.claude-lavoro")
        set.add(work)
        set.setActive(work.id)
        #expect(set.active(.codex) == codex)
    }

    @Test func renameChangesOnlyName() {
        var set = ProfileSet.initial(home: home)
        let main = set.defaultProfile(.claude)
        set.rename(main.id, to: "Personale")
        #expect(set.profile(main.id)?.name == "Personale")
        #expect(set.profile(main.id)?.configDir == main.configDir)
    }

    @Test func suggestedFolderSlug() {
        #expect(ProfileSet.suggestedFolder(name: "Lavoro 2", agent: .claude, home: home) == "/Users/v/.claude-lavoro-2")
        #expect(ProfileSet.suggestedFolder(name: "Ä/b", agent: .codex, home: home) == "/Users/v/.codex-a-b")
    }

    @Test func codableRoundTrip() throws {
        var set = ProfileSet.initial(home: home)
        let work = Profile(name: "Lavoro", agent: .claude, configDir: "/Users/v/.claude-lavoro")
        set.add(work)
        set.setActive(work.id)
        let back = try JSONDecoder().decode(ProfileSet.self, from: JSONEncoder().encode(set))
        #expect(back == set)
    }
}
