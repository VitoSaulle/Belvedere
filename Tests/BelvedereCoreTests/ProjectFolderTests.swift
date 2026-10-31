import Testing
@testable import BelvedereCore

@Suite struct ProjectFolderTests {
    @Test func everyWorkFolderIsAProject() {
        for path in ["/Users/v/Projects/app", "/Users/v/Documents", "/Users/v/Desktop/x", "/Volumes/Dati/app", "/tmp/prova"] {
            #expect(ProjectFolder.isProject(path, home: "/Users/v"), "\(path)")
        }
    }

    @Test func homeAndClaudeConfigAreNot() {
        for path in ["/", "/Users", "/Users/v", "/Users/v/", "/Users/v/.claude", "/Users/v/.claude/projects/x",
                     "/Users/v/x/../..", "relativa"] {
            #expect(!ProjectFolder.isProject(path, home: "/Users/v"), "\(path)")
        }
    }

    @Test func containsMatchesWholeFoldersOnly() {
        #expect(ProjectFolder.contains("/p/app", "/p/app"))
        #expect(ProjectFolder.contains("/p/app", "/p/app/sub"))
        #expect(!ProjectFolder.contains("/p/app", "/p/app-due"))
    }
}
