import BelvedereCore
import SwiftUI

enum Theme {
    static let accent = Color(hex: 0x3A5CCC)
    static let waiting = Color(hex: 0xE39A2B)
    static let working = Color(hex: 0x3A7BF2)
    static let done = Color(hex: 0x2FA36B)
    static let idle = Color(hex: 0xA3A6A9)
    static let danger = Color(hex: 0xD64545)

    static let claude = Color(hex: 0xD97757)
    static let claudeInk = Color(hex: 0xB85A3C)
    static let codex = Color(hex: 0x2F7F74)
    static let local = Color(hex: 0x9AA5C9)

    static func color(for status: SessionStatus) -> Color {
        switch status {
        case .waiting: waiting
        case .working: working
        case .done: done
        case .idle, .ended: idle
        }
    }

    static func label(for status: SessionStatus) -> String {
        switch status {
        case .waiting: "Ti aspetta"
        case .working: "Al lavoro"
        case .done: "Completata"
        case .idle: "Inattiva"
        case .ended: "Chiusa"
        }
    }

    static func agentName(_ agent: AgentKind) -> String {
        agent == .claude ? "Claude" : "Codex"
    }

    static func agentColor(_ agent: AgentKind) -> Color {
        agent == .claude ? claude : codex
    }

    /// Colore della barra del contesto: si scalda avvicinandosi al limite.
    static func contextColor(_ fraction: Double) -> Color {
        fraction < 0.7 ? accent : fraction < 0.9 ? waiting : danger
    }
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: opacity)
    }
}

/// Formati italiani per numeri, tempi e percentuali.
enum Fmt {
    static func tokens(_ n: Int) -> String {
        switch n {
        case ..<1_000: return "\(n)"
        case ..<100_000: return decimal(Double(n) / 1_000, digits: 1) + "k"
        case ..<1_000_000: return "\(n / 1_000)k"
        default: return decimal(Double(n) / 1_000_000, digits: 2) + "M"
        }
    }

    static func decimal(_ value: Double, digits: Int) -> String {
        value.formatted(.number.precision(.fractionLength(0...digits)).locale(Locale(identifier: "it_IT")))
    }

    static func percent(_ fraction: Double) -> String {
        "\(Int((fraction * 100).rounded()))%"
    }

    static func usd(_ value: Double) -> String {
        if value > 0 && value < 0.01 { return "<$0,01" }
        return "$" + value.formatted(.number.precision(.fractionLength(2)).locale(Locale(identifier: "it_IT")))
    }

    static func clock(_ date: Date) -> String {
        date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).locale(Locale(identifier: "it_IT")))
    }

    /// «ora», «12 min fa», «3 h fa», «ieri», poi la data.
    static func ago(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "—" }
        let seconds = now.timeIntervalSince(date)
        switch seconds {
        case ..<60: return "ora"
        case ..<3_600: return "\(Int(seconds / 60)) min fa"
        case ..<86_400: return "\(Int(seconds / 3_600)) h fa"
        case ..<172_800: return "ieri"
        default: return date.formatted(.dateTime.day().month(.abbreviated).locale(Locale(identifier: "it_IT")))
        }
    }

    /// Durata breve: «45 s», «12 min», «2 h 14 min».
    static func duration(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        if s < 60 { return "\(s) s" }
        if s < 3_600 { return "\(s / 60) min" }
        let m = (s % 3_600) / 60
        return m == 0 ? "\(s / 3_600) h" : "\(s / 3_600) h \(m) min"
    }

    /// «Si azzera alle 16:40» oggi, altrimenti con il giorno.
    static func reset(_ date: Date?, now: Date = Date()) -> String? {
        guard let date else { return nil }
        if Calendar.current.isDate(date, inSameDayAs: now) { return "si azzera alle \(clock(date))" }
        let day = date.formatted(.dateTime.weekday(.abbreviated).locale(Locale(identifier: "it_IT")))
        return "si azzera \(day) \(clock(date))"
    }

    /// Forma breve per spazi stretti: «azzera 16:40» oggi, «azzera lun» altrimenti.
    static func resetShort(_ date: Date?, now: Date = Date()) -> String? {
        guard let date else { return nil }
        if Calendar.current.isDate(date, inSameDayAs: now) { return "azzera \(clock(date))" }
        return "azzera " + date.formatted(.dateTime.weekday(.abbreviated).locale(Locale(identifier: "it_IT")))
    }

    /// Ultima cartella di un percorso.
    static func folder(_ path: String) -> String {
        let last = (path as NSString).lastPathComponent
        return last.isEmpty ? path : last
    }
}
