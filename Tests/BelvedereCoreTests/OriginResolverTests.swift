import Foundation
import Testing
@testable import BelvedereCore

@Suite struct OriginResolverTests {
    @Test func ancestorsEndWithoutCycles() {
        let chain = ProcessTree.ancestors(of: getpid())
        #expect(!chain.isEmpty)
        #expect(Set(chain).count == chain.count)
        #expect(chain.last == 1 || chain.count == 32)
        #expect(ProcessTree.parent(of: getpid()) == getppid())
    }

    @Test func resolvesFirstKnownAncestor() throws {
        let chain = ProcessTree.ancestors(of: getpid())
        let target = chain[min(2, chain.count - 1)]
        let origin = try #require(OriginResolver.resolve(pid: getpid()) { pid in
            pid == target ? ("com.jetbrains.intellij", "IntelliJ IDEA") : nil
        })
        #expect(origin.appName == "IntelliJ")
        #expect(origin.bundleID == "com.jetbrains.intellij")
        #expect(origin.pid == target)
    }

    @Test func unknownAncestryIsNil() {
        #expect(OriginResolver.resolve(pid: getpid()) { _ in nil } == nil)
    }

    @Test func friendlyNames() {
        #expect(OriginResolver.friendlyName(bundleID: "com.jetbrains.intellij.ce", fallback: "x") == "IntelliJ")
        #expect(OriginResolver.friendlyName(bundleID: "com.apple.Terminal", fallback: "x") == "Terminale")
        #expect(OriginResolver.friendlyName(bundleID: "com.googlecode.iterm2", fallback: "x") == "iTerm")
        #expect(OriginResolver.friendlyName(bundleID: "com.mitchellh.ghostty", fallback: "x") == "Ghostty")
        #expect(OriginResolver.friendlyName(bundleID: "com.microsoft.VSCode", fallback: "x") == "VS Code")
        #expect(OriginResolver.friendlyName(bundleID: "dev.warp.Warp-Stable", fallback: "Warp") == "Warp")
    }
}
