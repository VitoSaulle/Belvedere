import BelvedereCore
import SwiftUI

/// Campo della chat: ⏎ invia, ⇧⏎ va a capo, `/` per i comandi, `@` per i file.
struct Composer: View {
    @Environment(AppModel.self) private var model
    let host: HostedSession
    let sessionID: String
    @State private var text = ""
    @State private var terminalOnly: String?
    @State private var files: [String] = []
    @State private var showErrorDetail = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let error = host.state.lastError {
                banner(error)
            }
            if let name = terminalOnly {
                terminalNotice(name)
            }
            if !suggestions.isEmpty {
                suggestionList
            }
            field
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 14)
        .frame(maxWidth: 760)
        .task(id: fileQuery) { await loadFiles() }
        .onAppear { focused = true }
    }

    // MARK: - Campo

    private var field: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("Scrivi a \(Theme.agentName(host.agent)), / per i comandi, @ per i file", text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .lineLimit(1...8)
                .focused($focused)
                .onSubmit(send)
                .onKeyPress(.return, phases: .down) { press in
                    guard press.modifiers.contains(.shift) else { return .ignored }
                    text += "\n"
                    return .handled
                }
                .onKeyPress(.tab) {
                    guard let first = suggestions.first else { return .ignored }
                    accept(first)
                    return .handled
                }
                .padding(.vertical, 6)
            Menu {
                Button("Apri nel terminale", systemImage: "terminal") { Task { await model.openInTerminal(sessionID) } }
                if !host.isRunning {
                    Button("Riavvia la sessione", systemImage: "arrow.clockwise") { host.restart() }
                }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(.plain)
            .fixedSize()
            .help("Altre azioni")
            if host.state.status == .working {
                Button { host.interrupt() } label: {
                    Image(systemName: "stop.fill").font(.system(size: 11, weight: .bold))
                        .frame(width: 28, height: 28)
                        .background(Color.primary.opacity(0.85), in: .circle)
                        .foregroundStyle(Color(nsColor: .windowBackgroundColor))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(".", modifiers: .command)
                .help("Ferma (⌘.)")
            }
            Button(action: send) {
                Image(systemName: "arrow.up").font(.system(size: 13, weight: .bold))
                    .frame(width: 28, height: 28)
                    .background(canSend ? Theme.accent : Color.primary.opacity(0.15), in: .circle)
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .help("Invia (⏎)")
        }
        .padding(.leading, 16)
        .padding(.trailing, 8)
        .padding(.vertical, 6)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
    }

    private var canSend: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private func send() {
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return }
        terminalOnly = nil
        if case .terminalOnly(let name) = host.send(message) {
            terminalOnly = name
            return
        }
        text = ""
    }

    // MARK: - Suggerimenti

    private enum Suggestion: Hashable {
        case command(name: String, description: String)
        case file(String)
    }

    /// `/nome` all'inizio del testo, senza spazi.
    private var slashQuery: String? {
        guard text.hasPrefix("/"), !text.contains(" "), !text.contains("\n") else { return nil }
        return String(text.dropFirst())
    }

    /// `@percorso` come ultima parola.
    private var fileQuery: String? {
        guard let last = text.split(separator: " ", omittingEmptySubsequences: false).last, last.hasPrefix("@") else { return nil }
        return String(last.dropFirst())
    }

    private var suggestions: [Suggestion] {
        if let query = slashQuery {
            return Completions.slash(query, in: host.state.commands).map { .command(name: $0.name, description: $0.description) }
        }
        if fileQuery != nil { return files.prefix(8).map { .file($0) } }
        return []
    }

    private func loadFiles() async {
        guard let query = fileQuery else { files = []; return }
        let root = URL(fileURLWithPath: host.state.cwd ?? host.options.folder)
        files = await Task.detached(priority: .userInitiated) { Completions.files(query, root: root) }.value
    }

    private func accept(_ suggestion: Suggestion) {
        switch suggestion {
        case .command(let name, _):
            text = "/\(name) "
        case .file(let path):
            var words = text.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
            words.removeLast()
            words.append("@\(path) ")
            text = words.joined(separator: " ")
        }
        focused = true
    }

    private var suggestionList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(suggestions, id: \.self) { suggestion in
                Button { accept(suggestion) } label: {
                    HStack(spacing: 10) {
                        switch suggestion {
                        case .command(let name, let description):
                            Text("/\(name)").font(.system(size: 12.5, weight: .semibold, design: .monospaced))
                            Text(description).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                        case .file(let path):
                            Image(systemName: "doc").foregroundStyle(.secondary)
                            Text(path).font(.system(size: 12.5, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 6)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
    }

    // MARK: - Avvisi

    private func banner(_ error: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.danger)
            Text(error).font(.system(size: 12.5)).lineLimit(3).textSelection(.enabled)
            Spacer()
            if let detail = host.state.errorDetail {
                Button("Dettagli") { showErrorDetail = true }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .popover(isPresented: $showErrorDetail) {
                        ScrollView {
                            Text(detail).font(.system(size: 11.5, design: .monospaced)).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                        }
                        .frame(width: 520, height: 320)
                    }
            }
            if !host.isRunning {
                Button("Riavvia") { host.restart() }.buttonStyle(.bordered).buttonBorderShape(.capsule)
            }
        }
        .padding(10)
        .background(Theme.danger.opacity(0.10), in: .rect(cornerRadius: 12))
    }

    private func terminalNotice(_ name: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "terminal").foregroundStyle(.secondary)
            Text("/\(name) funziona solo nel terminale.").font(.system(size: 12.5))
            Spacer()
            Button("Apri nel terminale") { Task { await model.openInTerminal(sessionID) } }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
            Button { terminalOnly = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
        }
        .padding(10)
        .background(Color.primary.opacity(0.05), in: .rect(cornerRadius: 12))
    }
}
