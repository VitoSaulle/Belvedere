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
    private var waiters: [String: CheckedContinuation<PermissionDecision?, Never>] = [:]

    public init(policy: PermissionPolicy) {
        self.policy = policy
    }

    /// Attende la decisione per la richiesta; `nil` = nessuna risposta, decide il terminale.
    public func decision(for requestID: String) async -> PermissionDecision? {
        guard case .hold(let timeout) = policy else { return nil }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                waiters.removeValue(forKey: requestID)?.resume(returning: nil)
                guard !Task.isCancelled else { continuation.resume(returning: nil); return }
                waiters[requestID] = continuation
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(timeout))
                    await self?.finish(requestID, with: nil)
                }
            }
        } onCancel: {
            Task { await self.finish(requestID, with: nil) }
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
        finish(requestID, with: decision)
    }

    /// Chiude l'attesa senza decidere: la richiesta si è chiusa altrove.
    public func cancel(requestID: String) {
        finish(requestID, with: nil)
    }

    public func cancelAll() {
        let pending = waiters
        waiters.removeAll()
        for continuation in pending.values { continuation.resume(returning: nil) }
    }

    private func finish(_ requestID: String, with decision: PermissionDecision?) {
        waiters.removeValue(forKey: requestID)?.resume(returning: decision)
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
