import Foundation

/// Suggerimenti per `/` (comandi) e `@` (file) nel campo della chat.
public enum Completions {
    public static func slash(_ query: String, in commands: [SlashCommand]) -> [SlashCommand] {
        let q = query.lowercased()
        let sorted = commands.sorted { $0.name < $1.name }
        guard !q.isEmpty else { return Array(sorted.prefix(12)) }
        let prefix = sorted.filter { $0.name.lowercased().hasPrefix(q) }
        let inside = sorted.filter { !$0.name.lowercased().hasPrefix(q) && $0.name.lowercased().contains(q) }
        return Array((prefix + inside).prefix(12))
    }

    static let skipped: Set<String> = ["node_modules", "build", ".build", "DerivedData"]

    /// Percorsi relativi a `root` che contengono `query`, i più corti prima.
    public static func files(_ query: String, root: URL, limit: Int = 20) -> [String] {
        let q = query.lowercased()
        let base = root.standardizedFileURL.path
        var found: [String] = []
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                                          options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        for case let url as URL in walker {
            if skipped.contains(url.lastPathComponent) || walker.level > 6 {
                walker.skipDescendants()
                continue
            }
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory != true else { continue }
            let path = url.standardizedFileURL.path
            let relative = path.hasPrefix(base + "/") ? String(path.dropFirst(base.count + 1)) : url.lastPathComponent
            if q.isEmpty || relative.lowercased().contains(q) { found.append(relative) }
            if found.count >= 2_000 { break }
        }
        return Array(found.sorted { ($0.count, $0) < ($1.count, $1) }.prefix(limit))
    }
}
