import Foundation

/// Divide un testo Markdown nei blocchi da mostrare a spaziatura fissa (codice recintati e tabelle)
/// e nel testo attorno, dove i titoli diventano grassetto.
/// Serve perché il Markdown in linea di AttributedString trasforma gli a capo dei blocchi in spazi.
public enum FencedBlocks {
    public enum Part: Equatable, Sendable {
        case text(String)
        case code(String)
    }

    public static func split(_ markdown: String) -> [Part] {
        var parts: [Part] = []
        var text: [String] = []
        var code: [String]?
        var table: [String] = []
        let lines = markdown.components(separatedBy: "\n")

        func flushText(closingLine: Bool) {
            guard !text.isEmpty else { return }
            parts.append(.text(text.joined(separator: "\n") + (closingLine ? "\n" : "")))
            text = []
        }
        func flushTable() {
            guard !table.isEmpty else { return }
            flushText(closingLine: true)
            parts.append(.code(aligned(table)))
            table = []
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if var block = code {
                if trimmed.hasPrefix("```") {
                    parts.append(.code(block.joined(separator: "\n")))
                    code = nil
                } else {
                    block.append(line)
                    code = block
                }
            } else if trimmed.hasPrefix("```") {
                flushTable()
                flushText(closingLine: true)
                code = []
            } else if trimmed.hasPrefix("|") {
                table.append(trimmed)
            } else {
                flushTable()
                text.append(heading(line) ?? line)
            }
        }
        flushTable()
        if let block = code { parts.append(.code(block.joined(separator: "\n"))) }
        flushText(closingLine: false)
        return parts
    }

    /// `### Titolo` → `**Titolo**`.
    private static func heading(_ line: String) -> String? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
        return "**\(line.dropFirst(hashes + 1).trimmingCharacters(in: .whitespaces))**"
    }

    /// Righe di una tabella Markdown in colonne allineate, senza la riga di separazione.
    private static func aligned(_ rows: [String]) -> String {
        let cells = rows.compactMap { row -> [String]? in
            var inner = row.dropFirst()
            if inner.hasSuffix("|") { inner = inner.dropLast() }
            let cells = inner.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
            let isSeparator = cells.allSatisfy { !$0.isEmpty && $0.allSatisfy { "-:".contains($0) } }
            return isSeparator ? nil : cells
        }
        let columns = cells.map(\.count).max() ?? 0
        let widths = (0..<columns).map { c in cells.map { c < $0.count ? $0[c].count : 0 }.max() ?? 0 }
        return cells.map { row in
            row.enumerated().map { c, cell in
                c == row.count - 1 ? cell : cell.padding(toLength: widths[c] + 2, withPad: " ", startingAt: 0)
            }.joined()
        }.joined(separator: "\n")
    }
}

extension FencedBlocks {
    /// Il markdown inline lega solo `[testo](url)`: gli indirizzi scritti nudi, come quelli degli artefatti, restano testo.
    public static func linkingURLs(_ text: AttributedString) -> AttributedString {
        var out = text
        let plain = String(out.characters)
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        for match in detector?.matches(in: plain, range: NSRange(plain.startIndex..., in: plain)) ?? [] {
            // Il rilevatore prende anche i falsi domini come «README.md»: si tengono gli indirizzi completi.
            guard let url = match.url, let found = Range(match.range, in: plain), plain[found].hasPrefix("http"),
                  let range = Range(match.range, in: out), out[range].link == nil else { continue }
            out[range].link = url
        }
        return out
    }
}
