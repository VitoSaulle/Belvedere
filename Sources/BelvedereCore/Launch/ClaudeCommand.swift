import Foundation

/// Riga di comando e ambiente del processo `claude` lanciato da Belvedere.
public enum ClaudeCommand {
    public static let baseArguments = ["-p", "--input-format", "stream-json", "--output-format", "stream-json",
                                       "--verbose", "--include-partial-messages", "--permission-prompt-tool", "stdio"]

    public static func arguments(_ o: LaunchOptions, isGitRepository: Bool) -> [String] {
        baseArguments + variableArguments(o, isGitRepository: isGitRepository)
    }

    /// Variabili del processo: via quelle di una sessione Claude genitore, e per i modelli locali
    /// l'indirizzo di LM Studio. Nessun file di configurazione viene toccato.
    public static func environment(_ o: LaunchOptions, base: [String: String]) -> [String: String] {
        var env = base.filter { key, _ in
            !(key == "CLAUDECODE" || key == "CLAUDE_PID" || key == "CLAUDE_EFFORT" || key.hasPrefix("CLAUDE_CODE_"))
        }
        if let local = o.local {
            env["ANTHROPIC_BASE_URL"] = "http://localhost:1234"
            env["ANTHROPIC_AUTH_TOKEN"] = "lmstudio"
            for key in ["ANTHROPIC_MODEL", "ANTHROPIC_SMALL_FAST_MODEL", "ANTHROPIC_DEFAULT_HAIKU_MODEL"] {
                env[key] = local.id
            }
            env["CLAUDE_CODE_ATTRIBUTION_HEADER"] = "0"
        }
        return env
    }

    /// Comando equivalente da terminale, con le sole scelte dell'utente.
    public static func preview(_ o: LaunchOptions, isGitRepository: Bool) -> String {
        let args = variableArguments(o, isGitRepository: isGitRepository).map(quoteIfNeeded)
        return (["cd \(quote(o.folder)) && claude"] + args).joined(separator: " ")
    }

    public static func locateBinary(home: String, path: String?, isExecutable: (String) -> Bool) -> String? {
        let fixed = ["\(home)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude", "\(home)/.claude/local/claude"]
        let fromPath = (path ?? "").split(separator: ":").map { "\($0)/claude" }
        return (fixed + fromPath).first(where: isExecutable)
    }

    public static func quote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func quoteIfNeeded(_ s: String) -> String {
        s.allSatisfy { $0.isLetter || $0.isNumber || "-_./:=@".contains($0) } ? s : quote(s)
    }

    private static func variableArguments(_ o: LaunchOptions, isGitRepository: Bool) -> [String] {
        var args: [String] = []
        if let model = o.local?.id ?? o.model { args += ["--model", model] }
        switch o.permission {
        case .ask: break
        case .acceptEdits, .auto, .plan: args += ["--permission-mode", o.permission.rawValue]
        case .skip: args.append("--dangerously-skip-permissions")
        }
        if let id = o.resumeID { args += ["--resume", id] }
        if let name = o.name, !name.isEmpty { args += ["--name", name] }
        if o.worktree && isGitRepository { args.append("--worktree") }
        return args
    }
}

public enum GitInfo {
    /// `true` se la cartella o una delle superiori contiene `.git` (cartella o file, per i worktree).
    public static func isRepository(_ folder: String) -> Bool {
        var url = URL(fileURLWithPath: folder).standardizedFileURL
        while true {
            if FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path) { return true }
            let parent = url.deletingLastPathComponent()
            if parent.path == url.path { return false }
            url = parent
        }
    }
}

public enum LaunchAdvice {
    /// Avviso per i modelli locali con contesto piccolo.
    public static func contextWarning(_ contextLength: Int?) -> String? {
        guard let n = contextLength, n < 65_536 else { return nil }
        let formatted = n.formatted(.number.locale(Locale(identifier: "it_IT")))
        return "Contesto di \(formatted) token: Claude Code ne usa circa 20k solo per istruzioni e strumenti."
    }
}

public enum TerminalHandoff {
    /// Script `.command` che apre la sessione nel terminale con `claude --resume`.
    /// Scrive il proprio PID, che `exec` passa a claude: finché vive, Belvedere non riprende la sessione.
    /// `environment` porta le variabili di un modello locale, così la sessione non passa al cloud.
    public static func script(cwd: String, sessionID: String, binary: String, pidFile: String,
                              environment: [String: String] = [:]) -> String {
        script(cwd: cwd, arguments: [binary, "--resume", sessionID], pidFile: pidFile, environment: environment)
    }

    /// Come sopra, con la riga di comando completa (`codex resume <id>` per Codex).
    public static func script(cwd: String, arguments: [String], pidFile: String,
                              environment: [String: String] = [:]) -> String {
        let exports = environment.sorted { $0.key < $1.key }
            .map { "export \($0.key)=\(ClaudeCommand.quote($0.value))\n" }.joined()
        return "#!/bin/zsh\necho $$ > \(ClaudeCommand.quote(pidFile))\n" + exports
            + "cd \(ClaudeCommand.quote(cwd)) && exec \(arguments.map(ClaudeCommand.quote).joined(separator: " "))\n"
    }

    /// Il processo aperto dallo script è ancora vivo (anche se fermo su una domanda del terminale).
    public static func isRunning(pidFile: URL) -> Bool {
        guard let text = try? String(contentsOf: pidFile, encoding: .utf8),
              let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0 else { return false }
        return kill(pid, 0) == 0
    }
}
