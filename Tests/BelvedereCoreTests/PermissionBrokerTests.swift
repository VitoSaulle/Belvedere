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

    /// Il hook ucciso dal terminale chiude la connessione: il server cancella l'attesa.
    @Test func cancellingTheWaitReturnsNilAtOnce() async throws {
        let broker = PermissionBroker(policy: .hold(timeoutSeconds: 5))
        let wait = Task { await broker.decision(for: "r1") }
        try await Task.sleep(for: .milliseconds(50))
        let clock = ContinuousClock()
        var decision: PermissionDecision? = .allow
        let elapsed = await clock.measure {
            wait.cancel()
            decision = await wait.value
        }
        #expect(decision == nil)
        #expect(elapsed < .milliseconds(500))
    }

    @Test func cancelReleasesOnlyThatRequest() async throws {
        let broker = PermissionBroker(policy: .hold(timeoutSeconds: 5))
        async let a = broker.decision(for: "a")
        async let b = broker.decision(for: "b")
        try await Task.sleep(for: .milliseconds(50))
        await broker.cancel(requestID: "a")
        #expect(await a == nil)
        await broker.resolve(requestID: "b", with: .allow)
        #expect(await b == .allow)
    }

    @Test func answerBeforeTheWaitIsKept() async {
        let broker = PermissionBroker(policy: .hold(timeoutSeconds: 5))
        await broker.resolve(requestID: "r1", with: .deny(reason: "no"))
        #expect(await broker.decision(for: "r1") == .deny(reason: "no"))
    }

    @Test func oldTimerDoesNotCloseANewWait() async throws {
        let broker = PermissionBroker(policy: .hold(timeoutSeconds: 0.3))
        async let first = broker.decision(for: "r1")
        try await Task.sleep(for: .milliseconds(200))
        async let second = broker.decision(for: "r1")
        #expect(await first == nil)
        try await Task.sleep(for: .milliseconds(150))
        await broker.resolve(requestID: "r1", with: .allow)
        #expect(await second == .allow)
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

    @Test func policyCanChangeAtRuntime() async {
        let broker = PermissionBroker(policy: .hold(timeoutSeconds: 5))
        await broker.setPolicy(.observeOnly)
        let clock = ContinuousClock()
        var decision: PermissionDecision? = .allow
        let elapsed = await clock.measure { decision = await broker.decision(for: "r") }
        #expect(decision == nil)
        #expect(elapsed < .milliseconds(100))
    }

    @Test func policyStorageRoundTrip() {
        #expect(PermissionPolicy(storageValue: PermissionPolicy.observeOnly.storageValue) == .observeOnly)
        #expect(PermissionPolicy(storageValue: PermissionPolicy.default.storageValue) == .default)
        #expect(PermissionPolicy(storageValue: nil) == .default)
    }

    @Test func defaultPolicyFromSpike() {
        #expect(PermissionPolicy.default == .hold(timeoutSeconds: 590))
    }
}
