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
        var pending: PendingRequest?
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
    private var claudeLimits: PlanLimits?
    private var now: Date = .distantPast

    public init() {}

    // MARK: - Ingressi

    public mutating func apply(_ update: IndexUpdate) {
        for snapshot in update.changed {
            logs[snapshot.id] = snapshot
            if let date = snapshot.lastActivity { advance(to: date) }
        }
    }

    public mutating func apply(_ event: HookEvent, origin: SessionOrigin?) {
        advance(to: event.receivedAt)
        var state = hooks[event.sessionID] ?? HookState(statusAt: event.receivedAt)
        if let cwd = event.cwd { state.cwd = cwd }
        if let path = event.transcriptPath { state.transcriptPath = path }
        if let origin { state.origin = origin }
        for effect in event.effects {
            switch effect {
            case .register:
                state.ended = false
                if state.status == nil { state.status = .idle; state.statusAt = event.receivedAt }
            case .status(let status):
                state.status = status
                state.statusAt = event.receivedAt
            case .pending(let request):
                state.pending = request
                state.status = .waiting
                state.statusAt = event.receivedAt
            case .clearPending:
                state.pending = nil
            case .ended:
                state.ended = true
                state.pending = nil
                state.statusAt = event.receivedAt
            case .none:
                break
            }
        }
        hooks[event.sessionID] = state
    }

    public mutating func apply(_ status: StatusLinePayload) {
        let at = status.limits?.observedAt ?? Date()
        advance(to: at)
        statusLines[status.sessionID] = StatusLineState(payload: status, at: at)
        if let limits = status.limits { claudeLimits = limits }
    }

    public mutating func apply(codexLimits limits: PlanLimits?) {
        codexLimits = limits
    }

    public mutating func tick(now date: Date) {
        now = date
    }

    /// Toglie la richiesta in sospeso dopo una risposta data in Belvedere.
    public mutating func clearPending(sessionID: String) {
        hooks[sessionID]?.pending = nil
    }

    // MARK: - Uscite

    public var sessions: [SessionSnapshot] {
        let ids = Set(logs.keys).union(hooks.keys)
        return ids.compactMap(merged).sorted { a, b in
            let ra = Self.rank(a.status), rb = Self.rank(b.status)
            if ra != rb { return ra < rb }
            return (a.lastActivity ?? .distantPast) > (b.lastActivity ?? .distantPast)
        }
    }

    public var waitingCount: Int { sessions.filter { $0.status == .waiting }.count }

    public var planLimits: PlanLimits? {
        let newest = [claudeLimits, codexLimits].compactMap { $0 }.max { $0.observedAt < $1.observedAt }
        guard var limits = newest else { return nil }
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
        } else if let hook {
            s = SessionSnapshot(id: id, agent: .claude, cwd: hook.cwd ?? "", transcriptPath: hook.transcriptPath ?? "")
            s.lastActivity = hook.statusAt
            s.startedAt = hook.statusAt
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
            s.pending = hook.pending
            if hook.pending != nil { s.status = .waiting }
            if hook.ended { s.status = .ended; s.pending = nil }
        }
        if let line = statusLines[id], line.at >= (logs[id]?.lastActivity ?? .distantPast) {
            if let size = line.payload.contextWindowSize {
                s.contextWindow = size
                if let percent = line.payload.contextUsedPercent {
                    s.contextTokens = Int((percent / 100 * Double(size)).rounded())
                }
            }
            if let cost = line.payload.costUSD { s.costUSD = cost }
        }
        let quiet = now.timeIntervalSince(s.lastActivity ?? .distantPast)
        if s.status == .working, quiet > Self.workingTimeout { s.status = .idle }
        if s.status == .done, quiet > Self.doneTimeout { s.status = .idle }
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
