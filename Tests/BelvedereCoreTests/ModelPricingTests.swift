import Foundation
import Testing
@testable import BelvedereCore

@Suite struct ModelPricingTests {
    /// Riga reale della fixture `stream-allow.jsonl`: la CLI scrive 0,00445592 $.
    @Test func matchesTheCLIForHaiku() throws {
        let tokens = TokenTotals(input: 4, output: 170, cacheRead: 42392, cacheWrite: 19733)
        let cost = try #require(ModelPricing.cost(model: "claude-haiku-5-5", tokens: tokens))
        #expect(abs(cost - 0.00445592) < 0.000001)
    }

    @Test func familiesAndUnknownModels() throws {
        let million = TokenTotals(input: 1_000_000, output: 1_000_000, cacheRead: 1_000_000, cacheWrite: 0)
        #expect(ModelPricing.cost(model: "claude-opus-5-5", tokens: million) == 4 + 20 + 0.20)
        #expect(ModelPricing.cost(model: "claude-sonnet-4-6", tokens: million) == 3 + 15 + 0.30)
        #expect(ModelPricing.cost(model: "claude-fable-5-1", tokens: million) == 10 + 50 + 0.25)
        // Un modello senza listino noto non si stima: niente prezzi inventati.
        #expect(ModelPricing.cost(model: "gpt-5.3-codex", tokens: million) == nil)
        #expect(ModelPricing.cost(model: "<synthetic>", tokens: million) == nil)
    }
}
