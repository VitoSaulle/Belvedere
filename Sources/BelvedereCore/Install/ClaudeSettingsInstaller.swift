import Foundation

/// Aggiunge e toglie i hook e la status line di Belvedere nelle impostazioni di Claude Code,
/// senza toccare il resto. Le funzioni sono pure: la scrittura su disco passa da `SettingsFile`.
public enum ClaudeSettingsInstaller {
    /// Eventi inoltrati a Belvedere. Tutti con hook di tipo command (`belvedere-hook`): se Belvedere è chiuso
    /// il comando esce in silenzio, mentre un hook HTTP farebbe comparire un errore nel terminale.
    public static let events = ["SessionStart", "SessionEnd", "UserPromptSubmit", "PreToolUse", "PermissionRequest",
                                "PostToolUse", "PostToolUseFailure", "Notification", "Stop", "StopFailure",
                                "SubagentStart", "SubagentStop", "PreCompact", "PostCompact"]

    static let hookBinary = "belvedere-hook"
    static let statusBinary = "belvedere-statusline"

    /// Il timeout del hook supera di 10 s l'attesa del broker, come deciso nello spike.
    static let permissionTimeoutMargin = 10.0

    public static func install(into settings: [String: Any], helpers: URL, port: UInt16,
                               permissionTimeout: Double?) -> [String: Any] {
        var result = uninstall(from: settings, port: port)
        var hooks = result["hooks"] as? [String: Any] ?? [:]
        for event in events {
            var hook: [String: Any] = ["type": "command",
                                       "command": shellQuote(helpers.appendingPathComponent(hookBinary).path) + " " + event]
            if event == "PermissionRequest", let permissionTimeout {
                hook["timeout"] = Int((permissionTimeout + permissionTimeoutMargin).rounded(.up))
            }
            hooks[event] = (hooks[event] as? [[String: Any]] ?? []) + [["hooks": [hook]]]
        }
        result["hooks"] = hooks

        var line = result["statusLine"] as? [String: Any] ?? ["type": "command"]
        var command = shellQuote(helpers.appendingPathComponent(statusBinary).path)
        if let existing = line["command"] as? String, !existing.isEmpty {
            command += " --wrap " + Data(existing.utf8).base64EncodedString()
        }
        line["type"] = "command"
        line["command"] = command
        result["statusLine"] = line
        return result
    }

    public static func uninstall(from settings: [String: Any], port: UInt16) -> [String: Any] {
        var result = settings
        if var hooks = result["hooks"] as? [String: Any] {
            for (event, value) in hooks {
                guard let groups = value as? [[String: Any]] else { continue }
                let kept: [[String: Any]] = groups.compactMap { group in
                    guard let list = group["hooks"] as? [[String: Any]] else { return group }
                    let remaining = list.filter { !isOurs($0, port: port) }
                    if remaining.count == list.count { return group }
                    if remaining.isEmpty { return nil }
                    var copy = group
                    copy["hooks"] = remaining
                    return copy
                }
                hooks[event] = kept.isEmpty ? nil : kept
            }
            result["hooks"] = hooks.isEmpty ? nil : hooks
        }
        if var line = result["statusLine"] as? [String: Any], let command = line["command"] as? String,
           command.contains(statusBinary) {
            if let original = wrappedCommand(command) {
                line["command"] = original
                result["statusLine"] = line
            } else {
                result["statusLine"] = nil
            }
        }
        return result
    }

    public static func isInstalled(_ settings: [String: Any], port: UInt16) -> Bool {
        let hooks = settings["hooks"] as? [String: Any] ?? [:]
        return events.allSatisfy { event in
            (hooks[event] as? [[String: Any]] ?? []).contains { group in
                (group["hooks"] as? [[String: Any]] ?? []).contains { isOurs($0, port: port) }
            }
        }
    }

    /// Copia gli eseguibili dal bundle in un percorso stabile, che non cambia se l'app viene spostata.
    public static func installHelpers(from bundle: Bundle,
                                      to destination: URL = Belvedere.supportDirectory.appendingPathComponent("bin")) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        let source = bundle.bundleURL.appendingPathComponent("Contents/Helpers", isDirectory: true)
        for name in [hookBinary, statusBinary] {
            let target = destination.appendingPathComponent(name)
            let staged = destination.appendingPathComponent(".\(name).new")
            try? fm.removeItem(at: staged)
            try fm.copyItem(at: source.appendingPathComponent(name), to: staged)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: staged.path)
            _ = try fm.replaceItemAt(target, withItemAt: staged)
        }
        return destination
    }

    // MARK: - Utilità

    /// Riconosce anche i vecchi hook HTTP verso Belvedere, così lo scollegamento li toglie.
    static func isOurs(_ hook: [String: Any], port: UInt16) -> Bool {
        if let url = hook["url"] as? String { return url.hasPrefix("http://127.0.0.1:\(port)/hooks/") }
        if let command = hook["command"] as? String { return command.contains(hookBinary) }
        return false
    }

    static func wrappedCommand(_ command: String) -> String? {
        guard let range = command.range(of: " --wrap ") else { return nil }
        let encoded = command[range.upperBound...].trimmingCharacters(in: .whitespaces)
        return Data(base64Encoded: encoded).flatMap { String(data: $0, encoding: .utf8) }
    }

    static func shellQuote(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }
}

/// Il file delle impostazioni di Claude Code, scritto sempre con un backup accanto.
public struct SettingsFile {
    public let url: URL

    public init(url: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")) {
        self.url = url
    }

    /// File assente → dizionario vuoto.
    public func read() throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let data = try Data(contentsOf: url)
        if data.isEmpty { return [:] }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return object
    }

    /// Salva una copia del file attuale (se esiste) e poi scrive in modo atomico. Restituisce il backup.
    @discardableResult
    public func writeWithBackup(_ settings: [String: Any], now: Date = Date()) throws -> URL? {
        let fm = FileManager.default
        var backup: URL?
        if fm.fileExists(atPath: url.path) {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyyMMdd-HHmmss"
            let stem = "\(url.lastPathComponent).belvedere-\(formatter.string(from: now))"
            // Mai sovrascrivere un backup esistente: potrebbe essere l'unica copia dell'originale.
            var target = url.deletingLastPathComponent().appendingPathComponent("\(stem).bak")
            var n = 1
            while fm.fileExists(atPath: target.path) {
                target = url.deletingLastPathComponent().appendingPathComponent("\(stem)-\(n).bak")
                n += 1
            }
            try fm.copyItem(at: url, to: target)
            backup = target
        } else {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        let data = try JSONSerialization.data(withJSONObject: settings,
                                              options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: url, options: .atomic)
        return backup
    }
}
