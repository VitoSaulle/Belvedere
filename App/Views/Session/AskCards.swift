import BelvedereCore
import SwiftUI

/// Richiesta di permesso nella chat: Nega / Sempre in questo progetto / Consenti.
struct PermissionCard: View {
    let host: HostedSession
    let ask: PermissionAsk

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "hand.raised.fill").foregroundStyle(Theme.waiting)
                Text("Vuole usare \(ask.toolName)").font(.system(size: 13, weight: .semibold))
                Spacer()
            }
            if let detail = Self.detail(ask) {
                Text(detail)
                    .font(.system(size: 12.5, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(8)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.05), in: .rect(cornerRadius: 10))
            }
            if let description = ask.description, description != Self.detail(ask) {
                Text(description).font(.system(size: 12.5)).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Spacer()
                Button("Nega") { host.answer(ask, allow: false) }
                    .buttonStyle(.bordered)
                if let always = ask.always {
                    Button(always.title) { host.answer(ask, allow: true, always: true) }
                        .buttonStyle(.bordered)
                        .help(always.help)
                }
                Button("Consenti") { host.answer(ask, allow: true) }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                    .keyboardShortcut(.return, modifiers: .command)
            }
            .buttonBorderShape(.capsule)
        }
        .padding(14)
        .background(Theme.waiting.opacity(0.08), in: .rect(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.waiting.opacity(0.4)))
    }

    static func detail(_ ask: PermissionAsk) -> String? {
        for key in ["command", "file_path", "url", "pattern", "path"] {
            if let value = ask.input[key]?.stringValue { return value.replacingOccurrences(of: NSHomeDirectory(), with: "~") }
        }
        return nil
    }
}

/// Domanda di Claude (AskUserQuestion): opzioni come pulsanti, poi «Invia risposta».
struct QuestionCard: View {
    let host: HostedSession
    let ask: PermissionAsk
    @State private var chosen: [String: Set<String>] = [:]

    private struct Question: Identifiable {
        let id: String
        let header: String
        let multiSelect: Bool
        let options: [(label: String, description: String)]
    }

    private var questions: [Question] {
        guard case .array(let list)? = ask.input["questions"] else { return [] }
        return list.compactMap { q in
            guard let text = q["question"]?.stringValue else { return nil }
            var options: [(String, String)] = []
            if case .array(let opts)? = q["options"] {
                options = opts.compactMap { o in o["label"]?.stringValue.map { ($0, o["description"]?.stringValue ?? "") } }
            }
            var multi = false
            if case .bool(let b)? = q["multiSelect"] { multi = b }
            return Question(id: text, header: q["header"]?.stringValue ?? "", multiSelect: multi, options: options)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "questionmark.bubble.fill").foregroundStyle(Theme.accent)
                Text("\(Theme.agentName(host.agent)) ha una domanda").font(.system(size: 13, weight: .semibold))
            }
            ForEach(questions) { q in
                VStack(alignment: .leading, spacing: 8) {
                    if !q.header.isEmpty {
                        Text(q.header.uppercased()).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.secondary)
                    }
                    Text(q.id).font(.system(size: 13.5))
                    VStack(spacing: 6) {
                        ForEach(q.options, id: \.label) { option in
                            optionRow(q, option)
                        }
                    }
                }
            }
            HStack {
                Spacer()
                Button("Invia risposta") {
                    host.answer(ask, answers: chosen.mapValues { $0.sorted().joined(separator: ", ") })
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .tint(Theme.accent)
                .disabled(questions.contains { chosen[$0.id, default: []].isEmpty })
            }
        }
        .padding(14)
        .background(Theme.accent.opacity(0.06), in: .rect(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.accent.opacity(0.3)))
    }

    private func optionRow(_ q: Question, _ option: (label: String, description: String)) -> some View {
        let selected = chosen[q.id, default: []].contains(option.label)
        return Button {
            var set = chosen[q.id, default: []]
            if q.multiSelect {
                if selected { set.remove(option.label) } else { set.insert(option.label) }
            } else {
                set = [option.label]
            }
            chosen[q.id] = set
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: q.multiSelect ? (selected ? "checkmark.square.fill" : "square")
                                                : (selected ? "largecircle.fill.circle" : "circle"))
                    .foregroundStyle(selected ? Theme.accent : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.label).font(.system(size: 13, weight: .medium))
                    if !option.description.isEmpty {
                        Text(option.description).font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            .padding(9)
            .background(selected ? Theme.accent.opacity(0.10) : Color.primary.opacity(0.03), in: .rect(cornerRadius: 10))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}
