import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Immagine pronta per un blocco `image` di Claude.
public struct ImagePayload: Equatable, Sendable {
    public let mediaType: String
    public let base64: String

    public init(mediaType: String, base64: String) {
        self.mediaType = mediaType
        self.base64 = base64
    }
}

/// Un'immagine allegata a un messaggio, come quelle incollate nel terminale.
/// A Claude arriva come blocco base64, a Codex come percorso (`localImage`).
public struct ImageAttachment: Equatable, Sendable, Identifiable {
    public let path: String
    public var id: String { path }
    public var name: String { (path as NSString).lastPathComponent }

    /// Le API accettano fino a 5 MB in base64: circa 3,75 MB di file.
    public static let maxBytes = 3_750_000
    /// Lato lungo delle immagini ridotte: oltre, il modello le rimpicciolisce comunque.
    public static let maxEdge = 2000

    private static let sentAsIs: [String: String] = ["png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg",
                                                     "gif": "image/gif", "webp": "image/webp"]
    private static let converted: Set<String> = ["heic", "heif", "tif", "tiff", "bmp"]

    public init(path: String) {
        self.path = path
    }

    public static func isImage(path: String) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        return sentAsIs[ext] != nil || converted.contains(ext)
    }

    /// I formati che le API leggono e non troppo pesanti passano così come sono; gli altri diventano JPEG ridotti.
    public func payload() throws -> ImagePayload {
        let url = URL(fileURLWithPath: path)
        let data = try Data(contentsOf: url)
        if let type = Self.sentAsIs[url.pathExtension.lowercased()], data.count <= Self.maxBytes {
            return ImagePayload(mediaType: type, base64: data.base64EncodedString())
        }
        return ImagePayload(mediaType: "image/jpeg", base64: try Self.jpeg(data).base64EncodedString())
    }

    private static func jpeg(_ data: Data) throws -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { throw CocoaError(.fileReadCorruptFile) }
        var edge = maxEdge
        var quality = 0.85
        while true {
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                            kCGImageSourceCreateThumbnailWithTransform: true,
                                            kCGImageSourceThumbnailMaxPixelSize: edge]
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let out = NSMutableData()
            guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
            CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
            guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
            if out.length <= maxBytes || edge <= 400 { return out as Data }
            edge = edge * 3 / 4
            quality = max(0.6, quality - 0.1)
        }
    }

    /// Testo del messaggio mostrato nella chat: come nel terminale, le immagini compaiono per nome.
    public static func displayText(_ text: String, names: [String]) -> String {
        ([text].filter { !$0.isEmpty } + names.map { "[Immagine: \($0)]" }).joined(separator: "\n")
    }
}
