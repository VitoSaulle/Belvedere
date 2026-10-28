import Foundation

/// Listino API dei modelli Claude (dollari per milione di token, al 2026-10-06), per la «Stima API».
/// È una stima: Claude Code scrive la cache con durata di un'ora (2× il prezzo di input), le letture costano
/// quanto dice il listino, e i prezzi oltre i 100k token di prompt di Haiku 5.5 non sono distinti.
public enum ModelPricing {
    struct Price {
        let input: Double
        let output: Double
        let cacheRead: Double
    }

    /// Dal prefisso più specifico al più generico: `claude-opus-5-5` prima di `claude-opus-5`.
    static let table: [(prefix: String, price: Price)] = [
        ("claude-fable-5-1", Price(input: 10, output: 50, cacheRead: 0.25)),
        ("claude-mythos-5-1", Price(input: 10, output: 50, cacheRead: 0.25)),
        ("claude-fable-5", Price(input: 10, output: 50, cacheRead: 1)),
        ("claude-mythos-5", Price(input: 10, output: 50, cacheRead: 1)),
        ("claude-opus-5-5", Price(input: 4, output: 20, cacheRead: 0.20)),
        ("claude-opus-5", Price(input: 5, output: 25, cacheRead: 0.50)),
        ("claude-opus-4-8", Price(input: 5, output: 25, cacheRead: 0.50)),
        ("claude-opus-4-7", Price(input: 5, output: 25, cacheRead: 0.50)),
        ("claude-opus-4-6", Price(input: 5, output: 25, cacheRead: 0.50)),
        ("claude-opus-4-5", Price(input: 5, output: 25, cacheRead: 0.50)),
        ("claude-opus-4", Price(input: 15, output: 75, cacheRead: 1.50)),
        ("claude-sonnet-5", Price(input: 2, output: 10, cacheRead: 0.20)),
        ("claude-sonnet-4", Price(input: 3, output: 15, cacheRead: 0.30)),
        ("claude-3-7-sonnet", Price(input: 3, output: 15, cacheRead: 0.30)),
        ("claude-haiku-5-5", Price(input: 0.10, output: 0.50, cacheRead: 0.01)),
        ("claude-haiku-4-5", Price(input: 1, output: 5, cacheRead: 0.10)),
        ("claude-3-5-haiku", Price(input: 0.80, output: 4, cacheRead: 0.08)),
    ]

    /// Costo stimato in dollari; `nil` per un modello senza listino noto (Codex, locali): niente prezzi inventati.
    public static func cost(model: String, tokens: TokenTotals) -> Double? {
        guard let price = table.first(where: { model.hasPrefix($0.prefix) })?.price else { return nil }
        let perToken = { (dollarsPerMillion: Double, count: Int) in dollarsPerMillion * Double(count) / 1_000_000 }
        return perToken(price.input, tokens.input) + perToken(price.output, tokens.output)
            + perToken(price.cacheRead, tokens.cacheRead) + perToken(2 * price.input, tokens.cacheWrite)
    }
}
