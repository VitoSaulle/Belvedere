import Foundation
import Testing
@testable import BelvedereCore

@Suite(.serialized) struct LocalHTTPServerTests {
    private func request(_ port: UInt16, host: String = "127.0.0.1", path: String, body: Data) async throws -> (Int, Data) {
        var req = URLRequest(url: URL(string: "http://\(host):\(port)\(path)")!)
        req.httpMethod = "POST"
        req.httpBody = body
        req.timeoutInterval = 3
        let (data, response) = try await URLSession.shared.data(for: req)
        return ((response as! HTTPURLResponse).statusCode, data)
    }

    @Test func routesRequestsToHandler() async throws {
        let got = Locked<(String, String, Data)?>(nil)
        let server = LocalHTTPServer(port: 0) { method, path, body in
            got.withLock { $0 = (method, path, body) }
            return (200, Data(#"{"ok":true}"#.utf8))
        }
        try server.start()
        defer { server.stop() }
        let port = try #require(server.port)
        let (status, data) = try await request(port, path: "/hooks/Stop", body: Data(#"{"session_id":"s1"}"#.utf8))
        #expect(status == 200)
        #expect(String(decoding: data, as: UTF8.self) == #"{"ok":true}"#)
        let seen = try #require(got.withLock { $0 })
        #expect(seen.0 == "POST")
        #expect(seen.1 == "/hooks/Stop")
        #expect(String(decoding: seen.2, as: UTF8.self) == #"{"session_id":"s1"}"#)
    }

    /// Claude Code uccide il hook quando l'utente risponde nel terminale: l'attesa va cancellata.
    @Test func clientDisconnectCancelsHandler() async throws {
        let cancelled = Locked(false)
        let server = LocalHTTPServer(port: 0) { _, _, _ in
            do { try await Task.sleep(for: .seconds(5)) } catch { cancelled.withLock { $0 = true } }
            return (200, Data())
        }
        try server.start()
        defer { server.stop() }
        let port = try #require(server.port)
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        #expect(connected == 0)
        let request = "POST /hooks/PermissionRequest HTTP/1.1\r\nHost: x\r\nContent-Length: 2\r\n\r\n{}"
        _ = request.withCString { write(fd, $0, strlen($0)) }
        try await Task.sleep(for: .milliseconds(100))
        close(fd)
        for _ in 0..<20 where !cancelled.withLock({ $0 }) {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(cancelled.withLock { $0 })
    }

    @Test func rejectsOversizedBody() async throws {
        let server = LocalHTTPServer(port: 0) { _, _, _ in (200, Data()) }
        try server.start()
        defer { server.stop() }
        let (status, _) = try await request(try #require(server.port), path: "/hooks/Stop",
                                            body: Data(count: 1_048_577))
        #expect(status == 413)
    }

    @Test func listensOnLoopbackOnly() async throws {
        let server = LocalHTTPServer(port: 0) { _, _, _ in (200, Data()) }
        try server.start()
        defer { server.stop() }
        #expect(server.host == "127.0.0.1")
        let port = try #require(server.port)
        guard let lan = Self.lanAddress() else { return }
        await #expect(throws: (any Error).self) { _ = try await request(port, host: lan, path: "/x", body: Data()) }
    }

    /// Primo indirizzo IPv4 non di loopback, se esiste.
    static func lanAddress() -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let addr = ptr.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            let ip = String(cString: host)
            if !ip.hasPrefix("127.") { return ip }
        }
        return nil
    }
}
