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

    /// Una pagina web può fare POST a 127.0.0.1: il browser manda sempre `Origin`, i hook no.
    @Test func rejectsBrowserRequestsWithOrigin() async throws {
        let called = Locked(false)
        let server = LocalHTTPServer(port: 0) { _, _, _ in
            called.withLock { $0 = true }
            return (200, Data())
        }
        try server.start()
        defer { server.stop() }
        let port = try #require(server.port)
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/hooks/Stop")!)
        req.httpMethod = "POST"
        req.httpBody = Data("{}".utf8)
        req.setValue("https://evil.example", forHTTPHeaderField: "Origin")
        req.timeoutInterval = 3
        let (_, response) = try await URLSession.shared.data(for: req)
        #expect((response as! HTTPURLResponse).statusCode == 403)
        #expect(called.withLock { $0 } == false)
    }

    @Test func parseFlagsOriginHeader() {
        let raw = Data("POST /x HTTP/1.1\r\norigin: null\r\nContent-Length: 0\r\n\r\n".utf8)
        #expect(LocalHTTPServer.parse(raw) == .forbidden)
    }

    /// Una connessione che non manda nulla non resta aperta per sempre.
    @Test func closesIdleConnections() async throws {
        let server = LocalHTTPServer(port: 0, idleTimeout: 0.3) { _, _, _ in (200, Data()) }
        try server.start()
        defer { server.stop() }
        let port = try #require(server.port)
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        #expect(connected == 0)
        var tv = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var byte: UInt8 = 0
        let start = Date()
        let n = recv(fd, &byte, 1, 0)
        // 0 = chiusa dal server (o un 408), prima dei 3 s del timeout di lettura.
        #expect(n >= 0)
        #expect(Date().timeIntervalSince(start) < 2)
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
