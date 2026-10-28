import Foundation

public enum Belvedere {
    /// Porta del server locale su 127.0.0.1 che riceve hook e status line.
    public static let defaultPort: UInt16 = 47615

    /// ~/Library/Application Support/Belvedere
    public static var supportDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Belvedere", isDirectory: true)
    }
}
