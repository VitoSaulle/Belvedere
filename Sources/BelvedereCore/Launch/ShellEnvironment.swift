import Foundation

/// Ambiente della shell dell'utente per i processi figli.
/// Un'app aperta dal Finder eredita da launchd un `PATH` minimo: senza questo i server MCP, gli hook
/// e ogni altro comando lanciato dalla CLI non trovano `npx`, `uvx` e simili, che dal terminale funzionano.
public enum ShellEnvironment {
    /// Letto una volta sola, al primo uso: ogni nuova sessione lo riusa senza riaprire la shell.
    public static let current: [String: String] = {
        let base = ProcessInfo.processInfo.environment
        let home = NSHomeDirectory()
        return merged(base: base, shell: read(shell: base["SHELL"] ?? "/bin/zsh", home: home), home: home)
    }()

    /// Stato del terminale, non dell'utente: ai figli non serve.
    static let terminalState: Set<String> = ["PWD", "OLDPWD", "SHLVL", "TERM", "_"]

    static let marker = "__BELVEDERE_ENV__"

    /// Vince la shell; le cartelle solite restano in coda al `PATH` se la shell non ha risposto.
    static func merged(base: [String: String], shell: [String: String]?, home: String) -> [String: String] {
        var env = base.merging((shell ?? [:]).filter { !terminalState.contains($0.key) }) { $1 }
        var folders = (env["PATH"] ?? "").split(separator: ":").map(String.init)
        for folder in ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin"] where !folders.contains(folder) {
            folders.append(folder)
        }
        env["PATH"] = folders.joined(separator: ":")
        return env
    }

    /// Variabili dopo il marcatore, separate da NUL: un file rc può stampare ciò che vuole prima.
    static func parse(_ data: Data) -> [String: String]? {
        guard let start = data.range(of: Data(marker.utf8)) else { return nil }
        var env: [String: String] = [:]
        for entry in data[start.upperBound...].split(separator: 0) {
            let text = String(decoding: entry, as: UTF8.self)
            guard let equals = text.firstIndex(of: "="), equals != text.startIndex else { continue }
            env[String(text[..<equals])] = String(text[text.index(after: equals)...])
        }
        return env
    }

    /// Shell interattiva e di login, perché il `PATH` può stare sia in `.zprofile` sia in `.zshrc`.
    /// `nil` se fallisce o se non risponde entro `timeout`: una shell lenta non deve fermare l'app.
    static func read(shell: String, home: String, timeout: DispatchTimeInterval = .seconds(5)) -> [String: String]? {
        // Su file e non su pipe: a uscita avvenuta c'è già tutto, senza un lettore da aspettare,
        // e un demone avviato dai file rc che tiene aperto stdout non blocca nulla.
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("belvedere-env-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600]),
              let output = try? FileHandle(forWritingTo: file) else { return nil }
        defer {
            try? output.close()
            try? FileManager.default.removeItem(at: file)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-ilc", "printf \(marker); /usr/bin/env -0"]
        process.currentDirectoryURL = URL(fileURLWithPath: home)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do { try process.run() } catch { return nil }
        guard exited.wait(timeout: .now() + timeout) == .success else {
            // SIGKILL: una zsh interattiva ignora SIGTERM.
            kill(process.processIdentifier, SIGKILL)
            return nil
        }
        guard process.terminationStatus == 0, let data = try? Data(contentsOf: file) else { return nil }
        return parse(data)
    }
}
