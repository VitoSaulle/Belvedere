import Foundation

/// Cartella temporanea isolata per un test; viene rimossa alla deinizializzazione.
final class TempDir {
    let url: URL
    init() {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("belvedere-tests-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: url) }

    func file(_ name: String, _ content: String = "") -> URL {
        let f = url.appendingPathComponent(name)
        try! FileManager.default.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! Data(content.utf8).write(to: f)
        return f
    }
}

func append(_ text: String, to url: URL) {
    let h = try! FileHandle(forWritingTo: url)
    h.seekToEndOfFile()
    h.write(Data(text.utf8))
    try! h.close()
}

extension Array where Element == Data {
    var strings: [String] { map { String(decoding: $0, as: UTF8.self) } }
}
