import Foundation

public enum StatsRange: CaseIterable, Sendable {
    case today, days14, days30

    public var dayCount: Int {
        switch self {
        case .today: 1
        case .days14: 14
        case .days30: 30
        }
    }
}

/// Token di un giorno; i modelli locali sono separati dal loro agente.
public struct DayUsage: Sendable, Equatable {
    public let day: String
    public let claude: Int
    public let codex: Int
    public let local: Int

    public var total: Int { claude + codex + local }
}

public struct ProjectUsage: Sendable, Equatable {
    public let project: String
    public let sessions: Int
    public let tokens: Int
    public let cacheRatio: Double
    public let costUSD: Double?
    public let claudeShare: Double
    public let codexShare: Double
    public let localShare: Double
}

public struct StatsSummary: Sendable, Equatable {
    public let totalTokens: Int
    public let previousPeriodTokens: Int
    public let costUSD: Double?
    public let sessions: Int
    public let sessionsByAgent: [AgentKind: Int]
    public let localSessions: Int
    public let days: [DayUsage]
    public let projects: [ProjectUsage]
    public let localShare: Double
    public let topTools: [(name: String, count: Int)]

    public static func == (lhs: StatsSummary, rhs: StatsSummary) -> Bool {
        lhs.totalTokens == rhs.totalTokens && lhs.previousPeriodTokens == rhs.previousPeriodTokens
            && lhs.costUSD == rhs.costUSD && lhs.sessions == rhs.sessions
            && lhs.sessionsByAgent == rhs.sessionsByAgent && lhs.localSessions == rhs.localSessions
            && lhs.days == rhs.days && lhs.projects == rhs.projects && lhs.localShare == rhs.localShare
            && lhs.topTools.map(\.name) == rhs.topTools.map(\.name) && lhs.topTools.map(\.count) == rhs.topTools.map(\.count)
    }
}

public enum UsageStats {
    public static func summarize(buckets: [UsageBucket], sessions: [SessionSnapshot], range: StatsRange,
                                 project: String?, now: Date, calendar: Calendar) -> StatsSummary {
        let today = calendar.startOfDay(for: now)
        let dayList = (0..<range.dayCount).reversed().map { offset in
            UsageBucket.dayString(calendar.date(byAdding: .day, value: -offset, to: today)!, calendar: calendar)
        }
        let previousDays = Set((range.dayCount..<(2 * range.dayCount)).map { offset in
            UsageBucket.dayString(calendar.date(byAdding: .day, value: -offset, to: today)!, calendar: calendar)
        })
        let inProject = buckets.filter { project == nil || $0.project == project }
        let current = Set(dayList)
        let selected = inProject.filter { current.contains($0.day) }
        let previous = inProject.filter { previousDays.contains($0.day) }

        let total = selected.reduce(0) { $0 + $1.tokens.total }
        let local = selected.filter(\.isLocal).reduce(0) { $0 + $1.tokens.total }

        var agentOf: [String: AgentKind] = [:]
        var localIDs: Set<String> = []
        for b in selected {
            agentOf[b.sessionID] = b.agent
            if b.isLocal { localIDs.insert(b.sessionID) }
        }
        var byAgent: [AgentKind: Int] = [:]
        for agent in agentOf.values { byAgent[agent, default: 0] += 1 }

        var perDay: [String: (claude: Int, codex: Int, local: Int)] = [:]
        for b in selected {
            var entry = perDay[b.day] ?? (0, 0, 0)
            if b.isLocal { entry.local += b.tokens.total }
            else if b.agent == .claude { entry.claude += b.tokens.total }
            else { entry.codex += b.tokens.total }
            perDay[b.day] = entry
        }
        let days = dayList.map { day in
            let e = perDay[day] ?? (0, 0, 0)
            return DayUsage(day: day, claude: e.claude, codex: e.codex, local: e.local)
        }

        let projects = Dictionary(grouping: selected, by: \.project).map { name, list in
            projectUsage(name, list)
        }.sorted { $0.tokens != $1.tokens ? $0.tokens > $1.tokens : $0.project < $1.project }

        var tools: [String: Int] = [:]
        for b in selected { tools.merge(b.toolCounts, uniquingKeysWith: +) }
        let topTools = tools.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(8).map { (name: $0.key, count: $0.value) }

        return StatsSummary(totalTokens: total,
                            previousPeriodTokens: previous.reduce(0) { $0 + $1.tokens.total },
                            costUSD: cost(of: selected),
                            sessions: agentOf.count,
                            sessionsByAgent: byAgent,
                            localSessions: localIDs.count,
                            days: days,
                            projects: projects,
                            localShare: ratio(local, total),
                            topTools: topTools)
    }

    private static func projectUsage(_ name: String, _ list: [UsageBucket]) -> ProjectUsage {
        let tokens = list.reduce(TokenTotals.zero) { $0 + $1.tokens }
        let total = tokens.total
        let share = { (match: (UsageBucket) -> Bool) in
            ratio(list.filter(match).reduce(0) { $0 + $1.tokens.total }, total)
        }
        let ids = Set(list.map(\.sessionID))
        return ProjectUsage(project: name,
                            sessions: ids.count,
                            tokens: total,
                            cacheRatio: ratio(tokens.cacheRead, tokens.input + tokens.cacheRead + tokens.cacheWrite),
                            costUSD: cost(of: list),
                            claudeShare: share { !$0.isLocal && $0.agent == .claude },
                            codexShare: share { !$0.isLocal && $0.agent == .codex },
                            localShare: share(\.isLocal))
    }

    /// «Stima API»: token del periodo × listino del modello. Il costo che Claude Code scrive per sessione
    /// riparte da zero dopo una compattazione o una ripresa, e copre l'intera sessione anche in «Oggi».
    /// `nil` se nessun modello del periodo ha un listino noto; i locali non costano.
    private static func cost(of list: [UsageBucket]) -> Double? {
        let known = list.filter { !$0.isLocal }.compactMap { ModelPricing.cost(model: $0.model, tokens: $0.tokens) }
        return known.isEmpty ? nil : known.reduce(0, +)
    }

    private static func ratio(_ part: Int, _ whole: Int) -> Double {
        whole > 0 ? Double(part) / Double(whole) : 0
    }
}
