import Foundation

/// Unisce i tre canali (log, hook, status line) in un'unica vista delle sessioni.
public struct LiveSessionStore: Sendable {
    /// Per quanto tempo lo stato dato da un hook prevale su quello dedotto dai log.
    public static let hookPrecedence: TimeInterval = 10 * 60
    public static let workingTimeout: TimeInterval = 5 * 60
    public static let doneTimeout: TimeInterval = 30 * 60

    struct HookState: Sendable {
        var status: SessionStatus?
        var statusAt: Date
        /// Richieste aperte, dalla più vecchia: più subagenti o strumenti in parallelo possono chiedere insieme.
        var pending: [PendingRequest] = []
        var cwd: String?
        var transcriptPath: String?
        var origin: SessionOrigin?
        var ended = false
    }

    struct StatusLineState: Sendable {
        var payload: StatusLinePayload
        var at: Date
    }

    private var logs: [String: SessionSnapshot] = [:]
    private var hooks: [String: HookState] = [:]
    private var statusLines: [String: StatusLineState] = [:]
    private var codexLimits: PlanLimits?
    /// Sessioni lanciate da Belvedere e ancora vive: la loro chat è la fonte di stato e richieste.
    private var hostedIDs: Set<String> = []
    /// Sessioni di Belvedere il cui processo è uscito: restano ferme finché un hook non dice altro.
    private var exitedIDs: Set<String> = []
    private var hosted: [String: SessionSnapshot] = [:]
    /// Ultimi limiti letti dalla status line: l'app li salva e li ripristina all'avvio.
    public private(set) var claudeLimits: PlanLimits?
    /// Finestra di contesto per modello Claude, vista da status line e chat ospitate: il log non la dice.
    /// L'app la salva e la ripristina all'avvio.
    public private(set) var knownWindows: [String: Int] = [:]
    private var now: Date = .distantPast

    public init() {}

    // MARK: - Ingressi

    public mutating func apply(_ update: IndexUpdate) {
        for snapshot in update.changed {
            logs[snapshot.id] = snapshot
            if let date = snapshot.lastActivity { advance(to: date) }
        }
    }

    /// Applica l'evento e restituisce gli id delle richieste di permesso che ha chiuso.
    @discardableResult
    public mutating func apply(_ event: HookEvent, origin: SessionOrigin?) -> [String] {
        advance(to: event.receivedAt)
        var state = hooks[event.sessionID] ?? HookState(statusAt: event.receivedAt)
        if let cwd = event.cwd { state.cwd = cwd }
        if let path = event.transcriptPath { state.transcriptPath = path }
        if let origin { state.origin = origin }
        let before = state.pending
        let hostedEvent = hostedIDs.contains(event.sessionID)
        for effect in event.effects {
            switch effect {
            case .register:
                state.ended = false
                if state.status == nil { state.status = .idle; state.statusAt = event.receivedAt }
            case .status(let status):
                state.status = status
                state.statusAt = event.receivedAt
            case .pending where hostedEvent:
                break
            case .pending(let request):
                state.pending.removeAll { $0.id == request.id }
                state.pending.append(request)
                state.status = .waiting
                state.statusAt = event.receivedAt
            case .clearPending:
                state.pending = []
            case .clearTool(let key):
                state.pending.removeAll { $0.kind == .question || ($0.toolKey != nil && $0.toolKey == key) }
            case .ended:
                state.ended = true
                state.pending = []
                state.statusAt = event.receivedAt
            case .none:
                break
            }
        }
        // Un PostToolUse di un altro strumento non deve far sembrare al lavoro chi aspetta ancora l'utente.
        if !state.pending.isEmpty { state.status = .waiting }
        hooks[event.sessionID] = state
        let open = Set(state.pending.map(\.id))
        return before.filter { $0.kind == .permission && !open.contains($0.id) }.map(\.id)
    }

    public mutating func apply(_ status: StatusLinePayload) {
        let at = status.limits?.observedAt ?? Date()
        advance(to: at)
        statusLines[status.sessionID] = StatusLineState(payload: status, at: at)
        // L'id della status line è quello in uso (dopo `/model`) e distingue la variante `[1m]`.
        if let model = status.modelID { learnWindow(status.contextWindowSize, for: model) }
        if let limits = status.limits { claudeLimits = limits }
    }

    public mutating func setHosted(_ ids: Set<String>, exited: Set<String> = []) {
        hostedIDs = ids
        exitedIDs = exited
        hosted = hosted.filter { ids.contains($0.key) || exited.contains($0.key) }
    }

    /// Stato della chat di una sessione lanciata da Belvedere: prevale su log e hook.
    public mutating func apply(hosted snapshot: SessionSnapshot) {
        guard hostedIDs.contains(snapshot.id) || exitedIDs.contains(snapshot.id) else { return }
        hosted[snapshot.id] = snapshot
        if let model = snapshot.model, !snapshot.isLocalModel { learnWindow(snapshot.contextWindow, for: model) }
        if let date = snapshot.lastActivity { advance(to: date) }
    }

    public mutating func restore(knownWindows windows: [String: Int]) {
        knownWindows = windows
    }

    private mutating func learnWindow(_ window: Int?, for model: String) {
        guard let window, window > 0, !ModelInfo.isLocal(claudeModel: model) else { return }
        // Lo stesso id visto con due finestre: per un log non si sa quale valga, 0 = non applicare.
        if let known = knownWindows[model], known != window { knownWindows[model] = 0; return }
        knownWindows[model] = window
    }

    public mutating func apply(claudeLimits limits: PlanLimits?) {
        claudeLimits = limits
    }

    public mutating func apply(codexLimits limits: PlanLimits?) {
        codexLimits = limits
    }

    public mutating func tick(now date: Date) {
        now = date
    }

    /// Toglie una richiesta: risposta data in Belvedere, oppure connessione del hook chiusa
    /// perché l'utente ha risposto nel terminale.
    public mutating func clearPending(requestID: String) {
        for id in hooks.keys {
            guard var state = hooks[id], state.pending.contains(where: { $0.id == requestID }) else { continue }
            state.pending.removeAll { $0.id == requestID }
            if state.pending.isEmpty, state.status == .waiting { state.status = .idle }
            hooks[id] = state
        }
    }

    /// Sessioni eliminate: escono da tutti i canali.
    public mutating func forget(_ ids: Set<String>) {
        for id in ids {
            logs.removeValue(forKey: id)
            hooks.removeValue(forKey: id)
            statusLines.removeValue(forKey: id)
            hosted.removeValue(forKey: id)
        }
    }

    // MARK: - Uscite

    public var sessions: [SessionSnapshot] {
        let ids = Set(logs.keys).union(hooks.keys).union(hosted.keys)
        return ids.compactMap(merged).sorted { a, b in
            let ra = Self.rank(a.status), rb = Self.rank(b.status)
            if ra != rb { return ra < rb }
            return (a.lastActivity ?? .distantPast) > (b.lastActivity ?? .distantPast)
        }
    }

    public var waitingCount: Int { sessions.filter { $0.status == .waiting }.count }

    /// Limiti del piano di un agente, senza le finestre già azzerate.
    public func planLimits(_ agent: AgentKind) -> PlanLimits? {
        guard var limits = agent == .claude ? claudeLimits : codexLimits else { return nil }
        let isExpired = { (w: LimitWindow?) in w?.resetsAt.map { $0 < now } ?? false }
        if isExpired(limits.fiveHour) { limits.fiveHour = nil }
        if isExpired(limits.weekly) { limits.weekly = nil }
        return limits.fiveHour == nil && limits.weekly == nil ? nil : limits
    }

    // MARK: - Fusione

    private func merged(_ id: String) -> SessionSnapshot? {
        let hook = hooks[id]
        var s: SessionSnapshot
        if let log = logs[id] {
            s = log
            if s.agent == .claude, !s.isLocalModel, let model = s.model, let known = knownWindows[model],
               known > (s.contextWindow ?? 0) {
                s.contextWindow = known
            }
        } else if let hook {
            s = SessionSnapshot(id: id, agent: .claude, cwd: hook.cwd ?? "", transcriptPath: hook.transcriptPath ?? "")
            s.lastActivity = hook.statusAt
            s.startedAt = hook.statusAt
        } else if let live = hosted[id] {
            return live
        } else {
            return nil
        }
        if let hook {
            if let origin = hook.origin { s.origin = origin }
            if s.cwd.isEmpty, let cwd = hook.cwd { s.cwd = cwd }
            if (s.lastActivity ?? .distantPast) < hook.statusAt { s.lastActivity = hook.statusAt }
            if let status = hook.status, now.timeIntervalSince(hook.statusAt) < Self.hookPrecedence {
                s.status = status
            }
            // Oltre il timeout del hook nessuno può più rispondere da qui: se il processo è morto
            // senza altri eventi, la richiesta resterebbe aperta per sempre.
            s.pending = nil
            if let pending = hook.pending.first(where: { now.timeIntervalSince($0.receivedAt) < Self.hookPrecedence }) {
                s.pending = pending
                s.status = .waiting
            } else if !hook.pending.isEmpty, s.status == .waiting {
                s.status = .idle
            }
            if hook.ended { s.status = .ended; s.pending = nil }
        }
        if let line = statusLines[id], line.at >= (logs[id]?.lastActivity ?? .distantPast) {
            if let size = line.payload.contextWindowSize {
                s.contextWindow = size
                if let percent = line.payload.contextUsedPercent {
                    s.contextTokens = Int((percent / 100 * Double(size)).rounded())
                }
            }
            if s.costUSD == nil, let cost = line.payload.costUSD { s.costUSD = cost }
        }
        let quiet = now.timeIntervalSince(s.lastActivity ?? .distantPast)
        if s.status == .working, quiet > Self.workingTimeout { s.status = .idle }
        if s.status == .done, quiet > Self.doneTimeout { s.status = .idle }
        // Dopo l'uscita del processo vale lo stato finale della chat, ma un hook più recente
        // (la sessione ripresa altrove) torna a comandare.
        let overlay = hosted[id].flatMap { live -> SessionSnapshot? in
            guard !hostedIDs.contains(id), let hook, hook.statusAt > (live.lastActivity ?? .distantPast) else { return live }
            return nil
        }
        if let live = overlay {
            // La chat sa sempre cosa sta succedendo: niente scadenze dedotte dal silenzio.
            s.status = live.status
            s.pending = live.pending
            s.origin = live.origin
            if let model = live.model { s.model = model }
            if let tokens = live.contextTokens { s.contextTokens = tokens }
            if let window = live.contextWindow { s.contextWindow = window }
            if s.costUSD == nil, let cost = live.costUSD { s.costUSD = cost }
            if live.isLocalModel { s.isLocalModel = true }
            if let text = live.lastText { s.lastText = text }
            if s.cwd.isEmpty { s.cwd = live.cwd }
            if (s.lastActivity ?? .distantPast) < (live.lastActivity ?? .distantPast) { s.lastActivity = live.lastActivity }
        }
        // La CLI calcola il costo con i prezzi di Claude anche per un modello locale: non è un costo.
        if s.isLocalModel { s.costUSD = nil }
        return s
    }

    private mutating func advance(to date: Date) {
        if date > now { now = date }
    }

    private static func rank(_ status: SessionStatus) -> Int {
        switch status {
        case .waiting: 0
        case .working: 1
        default: 2
        }
    }
}
