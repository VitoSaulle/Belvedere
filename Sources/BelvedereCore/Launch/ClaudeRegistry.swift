import Foundation

/// Un `claude` vivo, come si annuncia in `<config>/sessions/<pid>.json`.
public struct LiveClaudeProcess: Equatable, Sendable {
    public let pid: Int32
    public let sessionID: String
    public let cwd: String
    public let status: String?
    public let entrypoint: String?

    public init(pid: Int32, sessionID: String, cwd: String, status: String?, entrypoint: String?) {
        self.pid = pid
        self.sessionID = sessionID
        self.cwd = cwd
        self.status = status
        self.entrypoint = entrypoint
    }

    /// Solo la CLI aperta in un terminale: estensioni e SDK appartengono all'app che li ha lanciati.
    public var canHandOver: Bool { entrypoint == "cli" }
    /// Tra un turno e l'altro: nessuna risposta in corso.
    public var isBetweenTurns: Bool { status == "idle" || hasBackgroundShell }
    /// Turno finito ma con un comando ancora vivo: chiudendo la CLI si interrompe anche quello.
    public var hasBackgroundShell: Bool { status == "shell" }
}

/// Legge il registro dei processi di Claude Code. Non è un'API documentata: un file illeggibile
/// o un campo mancante escludono la voce, e quel `claude` resta trattato come sconosciuto.
public enum ClaudeRegistry {
    public static func live(configDirs: [String],
                            isAlive: (Int32) -> Bool = { RunningProcesses.isRunning($0, named: "claude") }) -> [LiveClaudeProcess] {
        let fm = FileManager.default
        return configDirs.flatMap { dir -> [LiveClaudeProcess] in
            let folder = URL(fileURLWithPath: dir, isDirectory: true).appendingPathComponent("sessions", isDirectory: true)
            let names = (try? fm.contentsOfDirectory(atPath: folder.path)) ?? []
            return names.filter { $0.hasSuffix(".json") }.compactMap { name in
                guard let data = try? Data(contentsOf: folder.appendingPathComponent(name)),
                      let process = parse(data), isAlive(process.pid) else { return nil }
                return process
            }
        }
    }

    static func parse(_ data: Data) -> LiveClaudeProcess? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pid = json["pid"] as? Int, let id = json["sessionId"] as? String,
              let cwd = json["cwd"] as? String, let pid32 = Int32(exactly: pid) else { return nil }
        return LiveClaudeProcess(pid: pid32, sessionID: id, cwd: cwd,
                                 status: json["status"] as? String, entrypoint: json["entrypoint"] as? String)
    }
}
