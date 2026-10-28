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
        #expect(elapsed < .seconds(2))
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
        #expect(elapsed < .seconds(2))
    }

    /// Hook globale e hook di progetto mandano la stessa richiesta due volte: la risposta vale per entrambe.
    @Test func duplicateWaitsGetTheSameAnswer() async throws {
        let broker = PermissionBroker(policy: .hold(timeoutSeconds: 5))
        async let first = broker.decision(for: "r1")
        try await Task.sleep(for: .milliseconds(30))
        async let second = broker.decision(for: "r1")
        try await Task.sleep(for: .milliseconds(30))
        await broker.resolve(requestID: "r1", with: .allow)
        #expect(await first == .allow)
        #expect(await second == .allow)
    }

    /// Se uno dei due hook si chiude, l'altro resta in attesa.
    @Test func cancellingOneDuplicateKeepsTheOther() async throws {
        let broker = PermissionBroker(policy: .hold(timeoutSeconds: 5))
        let first = Task { await broker.decision(for: "r1") }
        try await Task.sleep(for: .milliseconds(30))
        async let second = broker.decision(for: "r1")
        try await Task.sleep(for: .milliseconds(30))
        first.cancel()
        #expect(await first.value == nil)
        await broker.resolve(requestID: "r1", with: .allow)
        #expect(await second == .allow)
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

    /// Il doppione che arriva a chiedere dopo che il primo ha già avuto la risposta non resta appeso.
    @Test func lateDuplicateGetsTheAnswerToo() async throws {
        let broker = PermissionBroker(policy: .hold(timeoutSeconds: 5))
        async let first = broker.decision(for: "r1")
        try await Task.sleep(for: .milliseconds(50))
        await broker.resolve(requestID: "r1", with: .allow)
        #expect(await first == .allow)
        #expect(await broker.decision(for: "r1") == .allow)
    }

    /// Risposta data prima che i due doppioni aspettino: la ricevono entrambi.
    @Test func earlyAnswerServesBothDuplicates() async {
        let broker = PermissionBroker(policy: .hold(timeoutSeconds: 5))
        await broker.resolve(requestID: "r1", with: .deny(reason: "no"))
        #expect(await broker.decision(for: "r1") == .deny(reason: "no"))
        #expect(await broker.decision(for: "r1") == .deny(reason: "no"))
    }

    @Test func oldTimerDoesNotCloseANewWait() async throws {
        // Margini larghi: sui runner di GitHub i sonni possono sforare di qualche centinaio di ms.
        // Il timer del primo scade a 2 s (con il secondo già in attesa), la risposta arriva a ~2,3 s,
        // il timer del secondo scadrebbe a 3 s.
        let broker = PermissionBroker(policy: .hold(timeoutSeconds: 2))
        async let first = broker.decision(for: "r1")
        try await Task.sleep(for: .milliseconds(1000))
        async let second = broker.decision(for: "r1")
        #expect(await first == nil)
        try await Task.sleep(for: .milliseconds(300))
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
        #expect(elapsed < .seconds(1))
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
