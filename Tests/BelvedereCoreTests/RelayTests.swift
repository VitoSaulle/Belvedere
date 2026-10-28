import Foundation
import Testing
@testable import BelvedereCore

@Suite(.serialized) struct RelayTests {
    @Test func noServerReturnsNilQuickly() {
        let start = Date()
        #expect(Relay.post(path: "/hooks/Stop", body: Data("{}".utf8), port: 1, timeout: 0.3) == nil)
        #expect(Date().timeIntervalSince(start) < 0.5)
    }

    @Test func returnsServerBody() async throws {
        let server = LocalHTTPServer(port: 0) { _, path, body in (200, Data((path + ":" + String(decoding: body, as: UTF8.self)).utf8)) }
        try server.start()
        defer { server.stop() }
        let port = try #require(server.port)
        let reply = await Task.detached { Relay.post(path: "/statusline", body: Data("ciao".utf8), port: port, timeout: 1) }.value
        #expect(reply.map { String(decoding: $0, as: UTF8.self) } == "/statusline:ciao")
    }

    @Test func emptyReplyIsEmptyData() async throws {
        let server = LocalHTTPServer(port: 0) { _, _, _ in (204, Data()) }
        try server.start()
        defer { server.stop() }
        let port = try #require(server.port)
        let reply = await Task.detached { Relay.post(path: "/hooks/Stop", body: Data(), port: port, timeout: 1) }.value
        #expect(reply == Data())
    }
}
