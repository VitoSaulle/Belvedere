import BelvedereCore
import Charts
import SwiftUI

/// Barre impilate per giorno: Claude, Codex e modelli locali.
struct DailyUsageChart: View {
    let days: [DayUsage]

    private struct Point: Identifiable {
        let id: String
        let date: Date
        let series: String
        let tokens: Int
    }

    private static let parser: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private var points: [Point] {
        days.flatMap { day -> [Point] in
            guard let date = Self.parser.date(from: day.day) else { return [] }
            return [("Claude", day.claude), ("Codex", day.codex), ("Locale", day.local)].map { name, value in
                Point(id: day.day + name, date: date, series: name, tokens: value)
            }
        }
    }

    var body: some View {
        Chart(points) { point in
            BarMark(x: .value("Giorno", point.date, unit: .day),
                    y: .value("Token", Double(point.tokens) / 1_000_000))
                .foregroundStyle(by: .value("Origine", point.series))
                .cornerRadius(3)
        }
        .chartForegroundStyleScale(["Claude": Theme.claude, "Codex": Theme.codex, "Locale": Theme.local])
        .chartLegend(.hidden)
        .chartXAxis {
            AxisMarks(values: .stride(by: .day, count: days.count > 14 ? 5 : (days.count > 1 ? 2 : 1))) { _ in
                AxisValueLabel(format: .dateTime.day().month(.abbreviated).locale(Locale(identifier: "it_IT")))
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine().foregroundStyle(Color.primary.opacity(0.08))
                AxisValueLabel { if let v = value.as(Double.self) { Text(Fmt.decimal(v, digits: 1)) } }
            }
        }
    }
}
