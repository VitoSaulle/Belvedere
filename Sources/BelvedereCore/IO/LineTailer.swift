import Foundation

/// Legge un file di log riga per riga a partire da un offset, restituendo solo righe complete.
/// L'offset avanza fino all'ultimo `\n`: una riga ancora in scrittura viene riletta al giro dopo.
public struct LineTailer: Codable, Sendable {
    public var offset: UInt64

    public init(offset: UInt64 = 0) {
        self.offset = offset
    }

    private static let chunkSize = 1 << 20

    public mutating func readNewLines(from url: URL) throws -> [Data] {
        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64 ?? 0
        if offset > size { offset = 0 }
        guard size > offset else { return [] }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: offset)

        var lines: [Data] = []
        var pending = Data()
        var consumed: UInt64 = 0
        while let chunk = try handle.read(upToCount: Self.chunkSize), !chunk.isEmpty {
            pending.append(chunk)
            var start = pending.startIndex
            while let nl = pending[start...].firstIndex(of: 0x0A) {
                let line = pending[start..<nl]
                if !line.isEmpty { lines.append(Data(line)) }
                consumed += UInt64(nl - start + 1)
                start = pending.index(after: nl)
            }
            pending = Data(pending[start...])
        }
        offset += consumed
        return lines
    }
}
