import Foundation

public enum PermissionPolicy: Sendable, Equatable {
    /// Tiene aperta la richiesta del hook finché l'utente risponde in Belvedere o scade il tempo.
    case hold(timeoutSeconds: Double)
    /// Non risponde mai: il dialogo resta al terminale.
    case observeOnly

    /// Dallo spike: il timeout del hook HTTP è 600 s, Belvedere rinuncia 10 s prima.
    public static let `default` = PermissionPolicy.hold(timeoutSeconds: 590)

    /// Forma salvata nelle preferenze: "observe" oppure "hold".
    public var storageValue: String {
        switch self {
        case .observeOnly: "observe"
        case .hold: "hold"
        }
    }

    public init(storageValue: String?) {
        self = storageValue == "observe" ? .observeOnly : .default
    }
}

public enum PermissionDecision: Sendable, Equatable {
    case allow
    case deny(reason: String)
}

/// Accoppia le richieste di permesso in arrivo dai hook con le risposte date nell'interfaccia.
public actor PermissionBroker {
    private var policy: PermissionPolicy
    /// Per richiesta, ogni attesa aperta: con hook globale e di progetto la stessa richiesta arriva due volte.
    private var waiters: [String: [UUID: CheckedContinuation<PermissionDecision?, Never>]] = [:]
    private var early: [String: (decision: PermissionDecision, at: Date)] = [:]
    private static let earlyLifetime: TimeInterval = 30

    public init(policy: PermissionPolicy) {
        self.policy = policy
    }

    /// Attende la decisione per la richiesta; `nil` = nessuna risposta, decide il terminale.
    public func decision(for requestID: String) async -> PermissionDecision? {
        guard case .hold(let timeout) = policy else { return nil }
        if let answer = early.removeValue(forKey: requestID),
           Date().timeIntervalSince(answer.at) < Self.earlyLifetime {
            return answer.decision
        }
        let token = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(returning: nil); return }
                waiters[requestID, default: [:]][token] = continuation
                // Il timer chiude solo questa attesa.
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(timeout))
                    await self?.finish(requestID, token: token, with: nil)
                }
            }
        } onCancel: {
            Task { await self.finish(requestID, token: token, with: nil) }
        }
    }

    /// `true` se le richieste vengono tenute aperte in attesa di una risposta da Belvedere.
    public var isHolding: Bool {
        if case .hold = policy { true } else { false }
    }

    /// Cambia la politica per le richieste future; quelle in attesa restano come sono.
    public func setPolicy(_ policy: PermissionPolicy) {
        self.policy = policy
    }

    public func resolve(requestID: String, with decision: PermissionDecision) {
        guard waiters[requestID] != nil else {
            let now = Date()
            early = early.filter { now.timeIntervalSince($0.value.at) < Self.earlyLifetime }
            early[requestID] = (decision, now)
            return
        }
        finish(requestID, with: decision)
    }

    /// Chiude l'attesa senza decidere: la richiesta si è chiusa altrove.
    public func cancel(requestID: String) {
        finish(requestID, with: nil)
    }

    public func cancelAll() {
        let pending = waiters
        waiters.removeAll()
        early.removeAll()
        for continuation in pending.values.flatMap(\.values) { continuation.resume(returning: nil) }
    }

    private func finish(_ requestID: String, with decision: PermissionDecision?) {
        for continuation in (waiters.removeValue(forKey: requestID) ?? [:]).values {
            continuation.resume(returning: decision)
        }
    }

    private func finish(_ requestID: String, token: UUID, with decision: PermissionDecision?) {
        guard let continuation = waiters[requestID]?.removeValue(forKey: token) else { return }
        if waiters[requestID]?.isEmpty == true { waiters.removeValue(forKey: requestID) }
        continuation.resume(returning: decision)
    }
}

/// Corpo della risposta HTTP al hook `PermissionRequest`.
public enum HookResponse {
    public static func body(for decision: PermissionDecision?) -> Data {
        guard let decision else { return Data() }
        var inner: [String: Any]
        switch decision {
        case .allow: inner = ["behavior": "allow"]
        case .deny(let reason): inner = ["behavior": "deny", "message": reason]
        }
        let object: [String: Any] = ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": inner]]
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
    }
}
