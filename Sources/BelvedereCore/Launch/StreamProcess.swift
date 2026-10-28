import Foundation

/// Processo figlio che parla a righe su stdin/stdout (il `claude -p` in stream-json).
public final class StreamProcess: @unchecked Sendable {
    public enum Event: Sendable, Equatable {
        case line(Data)
        /// Ultimo evento: codice d'uscita e gli ultimi 4 KB di stderr.
        case exited(code: Int32, stderr: String)
    }

    public enum ProcessError: Error { case notRunning }

    private let process = Process()
    private let stdin = Pipe()
    private let stdout = Pipe()
    private let stderr = Pipe()
    private let stderrTail = Tail()

    public init(executable: String, arguments: [String], environment: [String: String], directory: String) {
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
    }

    public var pid: Int32? { process.processIdentifier > 0 ? process.processIdentifier : nil }

    public func start() throws -> AsyncStream<Event> {
        // Scrivere su un processo già uscito non deve chiudere Belvedere.
        signal(SIGPIPE, SIG_IGN)
        // Un solo osservatore dell'uscita, su cui possono aspettare più thread
        // (`waitUntilExit` da due thread insieme può non tornare).
        let exited = DispatchGroup()
        exited.enter()
        process.terminationHandler = { _ in exited.leave() }
        do {
            try process.run()
        } catch {
            exited.leave()
            throw error
        }
        let (stream, continuation) = AsyncStream<Event>.makeStream()
        let errors = stderr.fileHandleForReading
        let tail = stderrTail
        let stderrDone = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            while true {
                let chunk = errors.availableData
                if chunk.isEmpty { break }
                tail.append(chunk)
            }
            stderrDone.signal()
        }
        let output = stdout.fileHandleForReading
        let process = self.process
        let readerDone = DispatchSemaphore(value: 0)
        let finish = Once()
        let report: @Sendable () -> Void = {
            finish.run {
                _ = stderrDone.wait(timeout: .now() + StreamProcess.eofGrace)
                let text = String(decoding: tail.data, as: UTF8.self)
                continuation.yield(.exited(code: process.terminationStatus, stderr: text))
                continuation.finish()
            }
        }
        // Un nipote (un server MCP, il binario sotto il wrapper di Codex) può tenere aperto stdout
        // dopo l'uscita: si aspetta l'EOF al massimo un attimo, poi l'uscita si segnala comunque.
        DispatchQueue.global(qos: .utility).async {
            exited.wait()
            if readerDone.wait(timeout: .now() + StreamProcess.eofGrace) == .timedOut { report() }
        }
        DispatchQueue.global(qos: .userInitiated).async {
            var buffer = Data()
            while true {
                let chunk = output.availableData
                if chunk.isEmpty { break }
                // Si cerca il fine riga solo nel pezzo nuovo: costo lineare anche per righe di molti MB.
                let searchFrom = buffer.count
                buffer.append(chunk)
                var start = 0
                var index = searchFrom
                while let newline = buffer[index...].firstIndex(of: 0x0A) {
                    if newline > start { continuation.yield(.line(Data(buffer[start..<newline]))) }
                    start = newline + 1
                    index = start
                }
                if start > 0 { buffer.removeSubrange(0..<start) }
            }
            if !buffer.isEmpty { continuation.yield(.line(buffer)) }
            readerDone.signal()
            exited.wait()
            report()
        }
        return stream
    }

    static let eofGrace: DispatchTimeInterval = .milliseconds(1500)

    public func send(_ data: Data) throws {
        guard process.isRunning else { throw ProcessError.notRunning }
        try stdin.fileHandleForWriting.write(contentsOf: data)
    }

    /// Chiude stdin, poi SIGINT; dopo `grace` SIGTERM e infine SIGKILL.
    /// I discendenti (server MCP, il binario sotto un wrapper) si raccolgono prima, perché dopo
    /// l'uscita del padre passano a launchd, e si chiudono anche loro.
    public func stop(grace: Duration = .seconds(2)) async {
        try? stdin.fileHandleForWriting.close()
        guard process.isRunning, let pid else { return }
        let tree = ProcessTree.descendants(of: pid)
        defer { Self.terminate(tree) }
        kill(pid, SIGINT)
        if await waitForExit(within: grace) { return }
        kill(pid, SIGTERM)
        if await waitForExit(within: .milliseconds(500)) { return }
        kill(pid, SIGKILL)
        _ = await waitForExit(within: .seconds(1))
    }

    private static func terminate(_ pids: [Int32]) {
        let alive = pids.filter { kill($0, 0) == 0 }
        guard !alive.isEmpty else { return }
        alive.forEach { kill($0, SIGTERM) }
        usleep(300_000)
        alive.filter { kill($0, 0) == 0 }.forEach { kill($0, SIGKILL) }
    }

    private func waitForExit(within limit: Duration) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + limit
        while process.isRunning && clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        return !process.isRunning
    }

    /// Esegue il blocco una volta sola, da qualunque thread.
    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false

        func run(_ body: () -> Void) {
            let first = lock.withLock { () -> Bool in
                defer { done = true }
                return !done
            }
            if first { body() }
        }
    }

    /// Ultimi 4 KB di stderr.
    private final class Tail: @unchecked Sendable {
        private let lock = NSLock()
        private var bytes = Data()

        var data: Data { lock.withLock { bytes } }

        func append(_ chunk: Data) {
            lock.withLock {
                bytes.append(chunk)
                if bytes.count > 4096 { bytes = Data(bytes.suffix(4096)) }
            }
        }
    }
}
