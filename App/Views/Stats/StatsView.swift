import BelvedereCore
import SwiftUI

struct StatsView: View {
    @Environment(AppModel.self) private var model
    @State private var range: StatsRange = .days14
    @State private var project: String?

    var body: some View {
        let s = model.stats(range: range, project: project)
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                kpis(s)
                HStack(alignment: .top, spacing: 16) {
                    VStack(spacing: 16) {
                        chartPanel(s)
                        projectsTable(s)
                    }
                    .frame(maxWidth: .infinity)
                    VStack(spacing: 16) {
                        limitsPanel
                        localPanel(s)
                        toolsPanel(s)
                    }
                    .frame(width: 290)
                }
            }
            .padding(22)
        }
        .scrollContentBackground(.hidden)
    }

    // MARK: - Intestazione

    private var header: some View {
        HStack(spacing: 14) {
            Text("Statistiche").font(.system(size: 26, weight: .bold))
            Spacer()
            Picker("Periodo", selection: $range) {
                Text("Oggi").tag(StatsRange.today)
                Text("14 giorni").tag(StatsRange.days14)
                Text("30 giorni").tag(StatsRange.days30)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 260)
            Picker("Progetto", selection: $project) {
                Text("Tutti i progetti").tag(String?.none)
                Divider()
                ForEach(projectChoices, id: \.self) { path in
                    Text(Fmt.folder(path)).tag(String?.some(path))
                }
            }
            .labelsHidden()
            .frame(width: 200)
        }
    }

    private var projectChoices: [String] {
        let totals = Dictionary(grouping: model.buckets, by: \.project).mapValues { $0.reduce(0) { $0 + $1.tokens.total } }
        return totals.sorted { $0.value > $1.value }.prefix(20).map(\.key).filter { !$0.isEmpty }
    }

    // MARK: - Riquadri

    private func kpis(_ s: StatsSummary) -> some View {
        HStack(spacing: 14) {
            Kpi(label: "Token", value: Fmt.tokens(s.totalTokens), delta: delta(s))
            Kpi(label: "Stima API", value: s.costUSD.map(Fmt.usd) ?? "—",
                delta: s.costUSD == nil ? "nessun modello con listino noto" : "token × listino, solo modelli Claude")
            Kpi(label: "Sessioni", value: "\(s.sessions)",
                delta: "Claude \(s.sessionsByAgent[.claude] ?? 0) · Codex \(s.sessionsByAgent[.codex] ?? 0)")
            Kpi(label: "Sessioni locali", value: "\(s.localSessions)", delta: "\(Fmt.percent(s.localShare)) dei token")
        }
    }

    private func delta(_ s: StatsSummary) -> String {
        guard s.previousPeriodTokens > 0 else { return "nessun dato nel periodo precedente" }
        let change = Double(s.totalTokens - s.previousPeriodTokens) / Double(s.previousPeriodTokens)
        let sign = change >= 0 ? "+" : "−"
        return "\(sign)\(Fmt.percent(abs(change))) sul periodo precedente"
    }

    private func chartPanel(_ s: StatsSummary) -> some View {
        Panel(title: nil) {
            HStack(alignment: .firstTextBaseline) {
                Text("Token al giorno").font(.system(size: 14, weight: .semibold))
                Text("milioni, cache inclusa").font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                ShareLegend()
            }
            DailyUsageChart(days: s.days)
                .frame(height: 220)
        }
    }

    private func projectsTable(_ s: StatsSummary) -> some View {
        Panel(title: nil) {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 9) {
                GridRow {
                    ForEach(["Progetto", "Sessioni", "Token", "Cache", "Stima API", "Mix modelli"], id: \.self) { title in
                        Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    }
                }
                Divider().gridCellColumns(6)
                ForEach(s.projects.prefix(12), id: \.project) { p in
                    GridRow {
                        Text(Fmt.folder(p.project)).font(.system(size: 12.5, weight: .medium)).lineLimit(1).help(p.project)
                        Text("\(p.sessions)").monospacedDigit()
                        Text(Fmt.tokens(p.tokens)).monospacedDigit()
                        Text(Fmt.percent(p.cacheRatio)).monospacedDigit()
                        Text(p.costUSD.map(Fmt.usd) ?? "—").monospacedDigit()
                        MixBar(claude: p.claudeShare, codex: p.codexShare, local: p.localShare)
                            .frame(minWidth: 90)
                    }
                    .font(.system(size: 12.5))
                }
                if s.projects.isEmpty {
                    Text("Nessun dato nel periodo.").foregroundStyle(.secondary).gridCellColumns(6)
                }
            }
        }
    }

    private var limitsPanel: some View {
        Panel(title: "Limiti del piano") {
            LimitRow(title: "Finestra 5 h", window: model.planLimits?.fiveHour, color: Theme.accent)
            LimitRow(title: "Settimana", window: model.planLimits?.weekly, color: .primary)
        }
    }

    private func localPanel(_ s: StatsSummary) -> some View {
        Panel(title: "Cloud o locale") {
            HStack(alignment: .firstTextBaseline) {
                Text("Locale").font(.system(size: 12.5, weight: .medium))
                Spacer()
                Text("\(Fmt.percent(s.localShare)) dei token").font(.system(size: 12.5, weight: .semibold))
            }
            MeterBar(fraction: s.localShare, color: Theme.local)
            Text(model.lmStudio?.reachable == true ? "LM Studio in linea" : "LM Studio non in esecuzione")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
        }
    }

    private func toolsPanel(_ s: StatsSummary) -> some View {
        Panel(title: "Strumenti più usati") {
            let peak = Double(s.topTools.first?.count ?? 1)
            if s.topTools.isEmpty {
                Text("Nessuno nel periodo.").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            ForEach(Array(s.topTools.enumerated()), id: \.offset) { _, tool in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(tool.name).font(.system(size: 12.5))
                        Spacer()
                        Text("\(tool.count)").font(.system(size: 12.5, weight: .semibold)).monospacedDigit()
                    }
                    MeterBar(fraction: Double(tool.count) / peak, color: Theme.accent.opacity(0.7), height: 4)
                }
            }
        }
    }
}

struct Kpi: View {
    let label: String
    let value: String
    let delta: String

    var body: some View {
        Panel(title: label) {
            Text(value).font(.system(size: 24, weight: .bold)).monospacedDigit().lineLimit(1)
            Text(delta).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
        }
    }
}

struct MixBar: View {
    let claude: Double
    let codex: Double
    let local: Double

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 1) {
                Rectangle().fill(Theme.claude).frame(width: geo.size.width * claude)
                Rectangle().fill(Theme.codex).frame(width: geo.size.width * codex)
                Rectangle().fill(Theme.local).frame(width: geo.size.width * local)
            }
            .clipShape(.capsule)
        }
        .frame(height: 6)
        .background(Color.primary.opacity(0.08), in: .capsule)
    }
}

struct ShareLegend: View {
    var body: some View {
        HStack(spacing: 12) {
            ForEach([("Claude", Theme.claude), ("Codex", Theme.codex), ("Locale", Theme.local)], id: \.0) { name, color in
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 8, height: 8)
                    Text(name).font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
            }
        }
    }
}
