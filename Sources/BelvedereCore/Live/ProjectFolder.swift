import Foundation

/// Cartelle dei progetti: una sessione aperta in `~` non fa della home un progetto da eliminare.
public enum ProjectFolder {
    /// `path` è la cartella stessa o sta dentro: i sottoprogetti seguono la cartella.
    public static func contains(_ folder: String, _ path: String) -> Bool {
        path == folder || path.hasPrefix(folder + "/")
    }

    /// La home, ciò che la contiene e la configurazione di Claude non sono progetti.
    public static func isProject(_ folder: String, home: String) -> Bool {
        let path = URL(fileURLWithPath: folder).standardizedFileURL.path
        return folder.hasPrefix("/") && path != "/" && !contains(path, home) && !contains(home + "/.claude", path)
    }
}
