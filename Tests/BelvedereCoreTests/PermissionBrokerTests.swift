import Foundation
import Testing
@testable import BelvedereCore

@Suite struct PermissionBrokerTests {
    @Test func holdTimesOut() async {
        let broker = PermissionBroker(policy: .hold(timeoutSeconds: 0.2))
        let clock = ContinuousClock()
        var decision: PermissionDecision? = .allow
        let elapsed = await clock.measure { decision = await broker.decision(for: "r1") }
        #expect(decision == nil)
        #expect(elapsed < .milliseconds(500))
    }

    @Test func resolveBeforeTimeout() async throws {
        let broker = PermissionBroker(policy: .hold(timeoutSeconds: 5))
        async let decision = broker.decision(for: "r1")
        try await Task.sleep(for: .milliseconds(50))
        await broker.resolve(requestID: "r1", with: .allow)
        #expect(await decision == .allow)
    }

    @Test func observeOnlyReturnsImmediately() async {
        let broker = PermissionBroker(policy: .observeOnly)
        #expect(await broker.decision(for: "r1") == nil)
    }

    @Test func cancelAllReleasesWaiters() async throws {
        let broker = PermissionBroker(policy: .hold(timeoutSeconds: 5))
        async let a = broker.decision(for: "a")
        async let b = broker.decision(for: "b")
        try await Task.sleep(for: .milliseconds(50))
        await broker.cancelAll()
        #expect(await a == nil)
        #expect(await b == nil)
    }

    @Test func defaultPolicyFromSpike() {
        #expect(PermissionPolicy.default == .hold(timeoutSeconds: 590))
    }
}
