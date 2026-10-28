import Foundation

public enum Belvedere {
    /// Porta del server locale su 127.0.0.1 che riceve hook e status line.
    public static let defaultPort: UInt16 = 47615

    /// Home da cui leggere sessioni e cache. `-BelvedereDemoHome <cartella>` la sostituisce con una home
    /// di dimostrazione (schermate e video senza dati reali); `HOME` non basta, Foundation usa la home dell'utente.
    public static var home: URL {
        if let demo = demoHome { return demo }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    public static var demoHome: URL? {
        UserDefaults.standard.string(forKey: "BelvedereDemoHome").map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    /// ~/Library/Application Support/Belvedere
    public static var supportDirectory: URL {
        home.appendingPathComponent("Library/Application Support/Belvedere", isDirectory: true)
    }
}
