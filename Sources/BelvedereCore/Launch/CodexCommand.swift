import Foundation

/// Processo `codex app-server` lanciato da Belvedere e parametri dei suoi thread.
public enum CodexCommand {
    public static let arguments = ["app-server"]

    /// Provider di LM Studio integrato in Codex: non serve toccare `~/.codex/config.toml`.
    public static let localProvider = "lmstudio"

    public static func locateBinary(home: String, path: String?, isExecutable: (String) -> Bool) -> String? {
        let fixed = ["/opt/homebrew/bin/codex", "/usr/local/bin/codex", "\(home)/.local/bin/codex"]
        let fromPath = (path ?? "").split(separator: ":").map { "\($0)/codex" }
        return (fixed + fromPath).first(where: isExecutable)
    }

    /// Permessi di Belvedere → criterio di approvazione e sandbox di Codex.
    public static func policy(_ choice: PermissionChoice) -> (approval: String, sandbox: String) {
        switch choice {
        case .ask: ("untrusted", "workspace-write")
        case .acceptEdits: ("on-request", "workspace-write")
        case .auto: ("never", "workspace-write")
        case .plan: ("on-request", "read-only")
        case .skip: ("never", "danger-full-access")
        }
    }

    /// Parametri comuni a `thread/start` e `thread/resume`.
    public static func threadParams(_ o: LaunchOptions) -> JSONValue {
        let p = policy(o.permission)
        var params: [String: JSONValue] = ["cwd": .string(o.folder), "approvalPolicy": .string(p.approval),
                                           "sandbox": .string(p.sandbox)]
        if let local = o.local {
            params["modelProvider"] = .string(localProvider)
            params["model"] = .string(local.id)
        } else if let model = o.model {
            params["model"] = .string(model)
        }
        return .object(params)
    }

    /// Ambiente del processo: `CODEX_HOME` del profilo, mai quello ereditato.
    public static func environment(base: [String: String], profile: Profile?) -> [String: String] {
        ClaudeCommand.profileEnvironment(base, key: "CODEX_HOME", profile: profile)
    }

    /// Comando equivalente da terminale.
    public static func preview(_ o: LaunchOptions, profile: Profile? = nil) -> String {
        (["cd \(ClaudeCommand.quote(o.folder)) && \(ClaudeCommand.profilePrefix(profile))codex"]
            + choiceArguments(o).map(ClaudeCommand.quoteIfNeeded))
            .joined(separator: " ")
    }

    /// Argomenti per riprendere la sessione nel terminale con `codex resume`.
    public static func terminalArguments(_ o: LaunchOptions) -> [String] {
        ["resume"] + (o.resumeID.map { [$0] } ?? []) + choiceArguments(o)
    }

    private static func choiceArguments(_ o: LaunchOptions) -> [String] {
        var args: [String] = []
        if let local = o.local {
            args += ["--oss", "--local-provider", localProvider, "-m", local.id]
        } else if let model = o.model {
            args += ["-m", model]
        }
        if o.permission == .skip {
            args.append("--dangerously-bypass-approvals-and-sandbox")
        } else {
            let p = policy(o.permission)
            args += ["-a", p.approval, "-s", p.sandbox]
        }
        return args
    }
}
