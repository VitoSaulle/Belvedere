import Foundation

public struct DiffLine: Equatable, Sendable {
    public enum Kind: Sendable { case context, added, removed }

    public let kind: Kind
    /// Riga nel file: quella nuova, o la vecchia per le righe tolte. `nil` se la trascrizione non la dice.
    public let number: Int?
    public let text: String

    public init(kind: Kind, number: Int?, text: String) {
        self.kind = kind
        self.number = number
        self.text = text
    }
}

/// Modifiche fatte a un file durante una sessione, lette dalla trascrizione solo quando servono:
/// nello snapshot, che sta in cache, peserebbero troppo.
public enum FileEdits {
    /// Un blocco di righe per modifica o gruppo di modifiche vicine, in ordine di tempo.
    public static func load(transcript: String, file: String) throws -> [[DiffLine]] {
        let data = try Data(contentsOf: URL(fileURLWithPath: transcript))
        var pending: [String: (name: String, input: [String: Any])] = [:]
        var hunks: [[DiffLine]] = []
        for line in data.split(separator: 0x0A) {
            guard let obj = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                  let message = obj["message"] as? [String: Any],
                  let blocks = message["content"] as? [[String: Any]] else { continue }
            for block in blocks {
                if block["type"] as? String == "tool_use", let id = block["id"] as? String, let name = block["name"] as? String,
                   let input = block["input"] as? [String: Any], input["file_path"] as? String == file {
                    pending[id] = (name, input)
                } else if block["type"] as? String == "tool_result", let id = block["tool_use_id"] as? String,
                          let use = pending.removeValue(forKey: id), block["is_error"] as? Bool != true {
                    // Una scrittura negata non ha toccato il disco; il risultato può mancare, l'input no.
                    let patch = (obj["toolUseResult"] as? [String: Any])?["structuredPatch"] as? [[String: Any]] ?? []
                    hunks += patch.isEmpty ? fromInput(use.name, use.input) : patch.map(fromPatch)
                }
            }
        }
        return hunks.filter { !$0.isEmpty }
    }

    static func fromPatch(_ hunk: [String: Any]) -> [DiffLine] {
        var old = hunk["oldStart"] as? Int ?? 1, new = hunk["newStart"] as? Int ?? 1
        var lines: [DiffLine] = []
        for line in hunk["lines"] as? [String] ?? [] {
            let text = String(line.dropFirst())
            switch line.first {
            case "+":
                lines.append(DiffLine(kind: .added, number: new, text: text))
                new += 1
            case "-":
                lines.append(DiffLine(kind: .removed, number: old, text: text))
                old += 1
            case " ":
                lines.append(DiffLine(kind: .context, number: new, text: text))
                old += 1
                new += 1
            default: break // «\ No newline at end of file»
            }
        }
        return lines
    }

    static func fromInput(_ name: String, _ input: [String: Any]) -> [[DiffLine]] {
        func lines(_ value: Any?, _ kind: DiffLine.Kind) -> [DiffLine] {
            ((value as? String) ?? "").split(separator: "\n", omittingEmptySubsequences: false)
                .map { DiffLine(kind: kind, number: nil, text: String($0)) }
        }
        switch name {
        case "Write":
            return [lines(input["content"], .added).enumerated().map { DiffLine(kind: .added, number: $0 + 1, text: $1.text) }]
        case "Edit":
            return [lines(input["old_string"], .removed) + lines(input["new_string"], .added)]
        case "MultiEdit":
            return (input["edits"] as? [[String: Any]] ?? []).map { lines($0["old_string"], .removed) + lines($0["new_string"], .added) }
        default:
            return []
        }
    }
}
