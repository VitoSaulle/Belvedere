import Foundation

/// L'account con cui Claude Code è collegato in una cartella: cambia con `/login`.
/// Viene da `.claude.json`, che non contiene token: i login stanno nel portachiavi e Belvedere non li legge.
public struct ClaudeAccount: Equatable, Sendable {
    public let id: String
    public let email: String

    public init(id: String, email: String) {
        self.id = id
        self.email = email
    }

    /// Il profilo predefinito lo tiene nella home, gli altri nella loro cartella.
    public static func file(profile: Profile, home: URL) -> URL {
        (profile.isDefault ? home : URL(fileURLWithPath: profile.configDir, isDirectory: true))
            .appendingPathComponent(".claude.json")
    }

    public static func read(profile: Profile, home: URL) -> ClaudeAccount? {
        (try? Data(contentsOf: file(profile: profile, home: home))).flatMap(parse)
    }

    static func parse(_ data: Data) -> ClaudeAccount? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let account = json["oauthAccount"] as? [String: Any],
              let id = account["accountUuid"] as? String,
              let email = account["emailAddress"] as? String else { return nil }
        return ClaudeAccount(id: id, email: email)
    }
}
