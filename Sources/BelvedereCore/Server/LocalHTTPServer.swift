import Foundation
import Network
import Synchronization

/// Server HTTP/1.1 minimo, solo su 127.0.0.1: riceve hook e status line.
/// Una richiesta per connessione, corpo con `Content-Length`, massimo 1 MiB.
public final class LocalHTTPServer: Sendable {
    public typealias Handler = @Sendable (_ method: String, _ path: String, _ body: Data) async -> (status: Int, body: Data)

    public static let maxBody = 1 << 20
    public let host = "127.0.0.1"
    private let requestedPort: UInt16
    private let handler: Handler
    private let queue = DispatchQueue(label: "it.vitosaulle.Belvedere.server")
    private let state = Mutex<(listener: NWListener?, port: UInt16?)>((nil, nil))

    public init(port: UInt16, handler: @escaping Handler) {
        self.requestedPort = port
        self.handler = handler
    }

    /// Porta effettiva, nota dopo `start()`.
    public var port: UInt16? { state.withLock { $0.port } }

    public enum ServerError: Error { case failed(String) }

    /// Avvia l'ascolto e attende che il listener sia pronto.
    public func start() throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(host),
                                                 port: NWEndpoint.Port(rawValue: requestedPort) ?? .any)
        params.allowLocalEndpointReuse = true
        let listener = try NWListener(using: params)
        let ready = DispatchSemaphore(value: 0)
        let failure = Mutex<String?>(nil)
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready: ready.signal()
            case .failed(let error):
                failure.withLock { $0 = "\(error)" }
                ready.signal()
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
        listener.start(queue: queue)
        if ready.wait(timeout: .now() + 5) == .timedOut {
            listener.cancel()
            throw ServerError.failed("timeout")
        }
        if let message = failure.withLock({ $0 }) {
            listener.cancel()
            throw ServerError.failed(message)
        }
        state.withLock { $0 = (listener, listener.port?.rawValue) }
    }

    public func stop() {
        state.withLock {
            $0.listener?.cancel()
            $0 = (nil, nil)
        }
    }

    // MARK: - Connessioni

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] chunk, _, isComplete, error in
            guard let self else { connection.cancel(); return }
            var buffer = buffer
            if let chunk { buffer.append(chunk) }
            switch Self.parse(buffer) {
            case .incomplete where error == nil && !isComplete:
                self.receive(connection, buffer: buffer)
            case .incomplete, .malformed:
                self.respond(connection, status: 400, body: Data())
            case .tooLarge:
                self.respond(connection, status: 413, body: Data())
            case .request(let method, let path, let body):
                Task {
                    let result = await self.handler(method, path, body)
                    self.respond(connection, status: result.status, body: result.body)
                }
            }
        }
    }

    private func respond(_ connection: NWConnection, status: Int, body: Data) {
        let reason = [200: "OK", 204: "No Content", 400: "Bad Request", 404: "Not Found", 413: "Payload Too Large"][status] ?? "Status"
        var head = "HTTP/1.1 \(status) \(reason)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n"
        if !body.isEmpty { head += "Content-Type: application/json\r\n" }
        var data = Data((head + "\r\n").utf8)
        data.append(body)
        connection.send(content: data, completion: .contentProcessed { _ in connection.cancel() })
    }

    enum Parsed: Equatable {
        case incomplete, malformed, tooLarge
        case request(method: String, path: String, body: Data)
    }

    static func parse(_ buffer: Data) -> Parsed {
        guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
            return buffer.count > 16_384 ? .malformed : .incomplete
        }
        let head = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
        let lines = head.components(separatedBy: "\r\n")
        let parts = lines.first?.split(separator: " ") ?? []
        guard parts.count >= 2 else { return .malformed }
        var length = 0
        for line in lines.dropFirst() {
            let pair = line.split(separator: ":", maxSplits: 1)
            if pair.count == 2, pair[0].lowercased() == "content-length" {
                guard let n = Int(pair[1].trimmingCharacters(in: .whitespaces)), n >= 0 else { return .malformed }
                length = n
            }
        }
        if length > maxBody { return .tooLarge }
        let body = buffer[end.upperBound...]
        guard body.count >= length else { return .incomplete }
        return .request(method: String(parts[0]), path: String(parts[1]), body: Data(body.prefix(length)))
    }
}
