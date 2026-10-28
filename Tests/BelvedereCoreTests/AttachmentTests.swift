import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import BelvedereCore

@Suite struct AttachmentTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// Scrive un'immagine di prova; `noise` la rende poco comprimibile, quindi pesante.
    private func image(_ name: String, width: Int, height: Int, type: UTType, noise: Bool = false) throws -> String {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("belvedere-allegati-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        var seed: UInt32 = 7
        for i in stride(from: 0, to: bytes.count, by: 4) {
            if noise {
                for k in 0..<3 { seed = seed &* 1_103_515_245 &+ 12_345; bytes[i + k] = UInt8(truncatingIfNeeded: seed >> 16) }
            } else {
                bytes[i] = 90; bytes[i + 1] = 110; bytes[i + 2] = 240
            }
            bytes[i + 3] = 255
        }
        let context = try #require(CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let cg = try #require(context.makeImage())
        let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, cg, nil)
        #expect(CGImageDestinationFinalize(dest))
        return url.path
    }

    private func object(_ data: Data) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: - Claude

    @Test func userLineWithImagesUsesContentBlocks() throws {
        let o = try object(StreamInput.user("guarda qui", images: [ImagePayload(mediaType: "image/png", base64: "QUJD")]))
        let message = try #require(o["message"] as? [String: Any])
        let blocks = try #require(message["content"] as? [[String: Any]])
        #expect(blocks.count == 2)
        #expect(blocks[0]["type"] as? String == "image")
        let source = try #require(blocks[0]["source"] as? [String: Any])
        #expect(source["type"] as? String == "base64")
        #expect(source["media_type"] as? String == "image/png")
        #expect(source["data"] as? String == "QUJD")
        #expect(blocks[1]["type"] as? String == "text")
        #expect(blocks[1]["text"] as? String == "guarda qui")
    }

    @Test func imageOnlyMessageHasNoEmptyTextBlock() throws {
        let o = try object(StreamInput.user("", images: [ImagePayload(mediaType: "image/jpeg", base64: "QUJD")]))
        let blocks = try #require((o["message"] as? [String: Any])?["content"] as? [[String: Any]])
        #expect(blocks.map { $0["type"] as? String } == ["image"])
    }

    @Test func userLineWithoutImagesStaysAString() throws {
        let o = try object(StreamInput.user("ciao", images: []))
        #expect((o["message"] as? [String: Any])?["content"] as? String == "ciao")
    }

    // MARK: - Immagini

    @Test func smallPNGIsSentAsIs() throws {
        let path = try image("schermata.png", width: 40, height: 30, type: .png)
        let payload = try ImageAttachment(path: path).payload()
        #expect(payload.mediaType == "image/png")
        #expect(Data(base64Encoded: payload.base64) == FileManager.default.contents(atPath: path))
    }

    @Test func unsupportedFormatIsConvertedToJPEG() throws {
        let path = try image("scansione.tiff", width: 64, height: 48, type: .tiff)
        let payload = try ImageAttachment(path: path).payload()
        #expect(payload.mediaType == "image/jpeg")
        let data = try #require(Data(base64Encoded: payload.base64))
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        #expect(CGImageSourceGetType(source) as String? == UTType.jpeg.identifier)
    }

    @Test func heavyImageIsShrunkUnderTheLimit() throws {
        let path = try image("enorme.png", width: 2600, height: 1800, type: .png, noise: true)
        let size = try #require(try FileManager.default.attributesOfItem(atPath: path)[.size] as? Int)
        #expect(size > ImageAttachment.maxBytes)
        let payload = try ImageAttachment(path: path).payload()
        let data = try #require(Data(base64Encoded: payload.base64))
        #expect(data.count <= ImageAttachment.maxBytes)
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let props = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        let width = try #require(props[kCGImagePropertyPixelWidth] as? Int)
        let height = try #require(props[kCGImagePropertyPixelHeight] as? Int)
        #expect(max(width, height) <= ImageAttachment.maxEdge)
    }

    @Test func recognisesImagesByExtension() {
        #expect(ImageAttachment.isImage(path: "/a/Foto.HEIC"))
        #expect(ImageAttachment.isImage(path: "/a/b.png"))
        #expect(!ImageAttachment.isImage(path: "/a/b.swift"))
        #expect(!ImageAttachment.isImage(path: "/a/cartella"))
    }

    @Test func displayTextListsImages() {
        #expect(ImageAttachment.displayText("guarda", names: ["a.png", "b.jpg"]) == "guarda\n[Immagine: a.png]\n[Immagine: b.jpg]")
        #expect(ImageAttachment.displayText("", names: ["a.png"]) == "[Immagine: a.png]")
        #expect(ImageAttachment.displayText("solo testo", names: []) == "solo testo")
    }

    // MARK: - Codex

    private static func message(_ json: String) -> CodexMessage { CodexMessage.decode(Data(json.utf8)) }
    private static func object(_ data: Data) -> JSONValue {
        JSONValue(any: (try? JSONSerialization.jsonObject(with: data)) ?? [:])
    }

    @Test func codexTurnCarriesLocalImages() {
        var c = CodexConversation(options: LaunchOptions(folder: "/p", agent: .codex))
        var state = ChatState(agent: .codex)
        _ = c.begin()
        _ = c.receive(Self.message(#"{"id":1,"result":{}}"#), state: &state, now: now)
        // Prima che il thread esista il messaggio resta in coda con le sue immagini.
        #expect(c.send("guarda", images: ["/tmp/a.png"]).isEmpty)
        let out = c.receive(Self.message(#"{"id":2,"result":{"thread":{"id":"t1"}}}"#), state: &state, now: now).map(Self.object)
        #expect(out.first?["method"]?.stringValue == "turn/start")
        #expect(out.first?["params"]?["input"] == .array([
            .object(["type": .string("text"), "text": .string("guarda"), "text_elements": .array([])]),
            .object(["type": .string("localImage"), "path": .string("/tmp/a.png")]),
        ]))
    }

    // MARK: - Cronologia

    @Test func claudeHistoryShowsImagePlaceholder() {
        let line: [String: Any] = ["type": "user", "uuid": "u1", "message": ["role": "user", "content": [
            ["type": "image", "source": ["type": "base64", "media_type": "image/png", "data": "QUJD"]],
            ["type": "text", "text": "cosa vedi?"],
        ]]]
        #expect(TranscriptMessages.claudeItems(line) == [.user(id: "u1", text: "[Immagine]\ncosa vedi?")])
    }

    @Test func codexHistoryShowsImagePlaceholder() {
        let item = JSONValue(any: ["type": "userMessage", "id": "m0", "content": [
            ["type": "text", "text": "cosa vedi?"], ["type": "localImage", "path": "/tmp/a.png"],
        ]])
        #expect(CodexItems.item(item, includeUser: true) == .user(id: "m0", text: "cosa vedi?\n[Immagine]"))
    }
}
