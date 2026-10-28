import BelvedereCore
import SwiftUI

struct TranscriptList: View {
    let session: SessionSnapshot
    @State private var items: [TranscriptItem] = []
    @State private var loaded = false

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if loaded && items.isEmpty {
                        Text("Nessun messaggio da mostrare.")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 60)
                    }
                    ForEach(items) { item in
                        TranscriptRow(item: item)
                    }
                    if let pending = session.pending {
                        PendingBox(session: session, pending: pending)
                    } else if session.status == .working {
                        WorkingIndicator()
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .frame(maxWidth: 700)
                .padding(.horizontal, 28)
                .padding(.vertical, 22)
                .frame(maxWidth: .infinity)
            }
            .scrollContentBackground(.hidden)
            .defaultScrollAnchor(.bottom)
            .task(id: "\(session.id)|\(session.lastActivity?.timeIntervalSince1970 ?? 0)") {
                let path = session.transcriptPath, agent = session.agent
                let fresh = await Task.detached(priority: .userInitiated) {
                    (try? TranscriptMessages.load(path: path, agent: agent)) ?? []
                }.value
                let grew = fresh.last?.id != items.last?.id
                items = fresh
                loaded = true
                if grew {
                    withAnimation(.smooth(duration: 0.25)) { proxy.scrollTo("end", anchor: .bottom) }
                }
            }
        }
    }
}

struct TranscriptRow: View {
    let item: TranscriptItem

    var body: some View {
        switch item {
        case .user(_, let text):
            HStack {
                Spacer(minLength: 120)
                Text(text)
                    .font(.system(size: 14))
                    .lineSpacing(3)
                    .foregroundStyle(.white)
                    .textSelection(.enabled)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Theme.accent, in: UnevenRoundedRectangle(topLeadingRadius: 18, bottomLeadingRadius: 18,
                                                                        bottomTrailingRadius: 6, topTrailingRadius: 18))
            }
        case .assistant(_, let text):
            Text(Self.markdown(text))
                .font(.system(size: 14))
                .lineSpacing(4)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .tool(_, let name, let detail, let added, let removed):
            ToolRow(name: name, detail: detail, added: added, removed: removed)
        case .note(_, let text):
            Label(text, systemImage: "stop.circle")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    static func markdown(_ text: String) -> AttributedString {
        let parts = FencedBlocks.split(text)
        var out = AttributedString()
        for (index, part) in parts.enumerated() {
            switch part {
            case .text(let text):
                out += (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
                    ?? AttributedString(text)
            case .code(let code):
                var block = AttributedString(code)
                block.font = .system(size: 12.5, design: .monospaced)
                out += block
                if index < parts.count - 1 { out += AttributedString("\n") }
            }
        }
        return out
    }
}

struct ToolRow: View {
    @Environment(\.colorScheme) private var scheme
    let name: String
    let detail: String
    let added: Int?
    let removed: Int?

    var body: some View {
        HStack(spacing: 10) {
            Text(glyph)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(Theme.accent)
                .frame(width: 22, height: 22)
                .background(Theme.accent.opacity(0.10), in: .rect(cornerRadius: 6))
            Text(name).font(.system(size: 12.5, weight: .semibold))
            Text(detail.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            if let added, added > 0 {
                Text("+\(added)").foregroundStyle(Theme.done)
            }
            if let removed, removed > 0 {
                Text("−\(removed)").foregroundStyle(Theme.danger)
            }
        }
        .font(.system(size: 12, weight: .semibold))
        .monospacedDigit()
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(scheme == .dark ? Color(hex: 0x23252B) : Color.white, in: .rect(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.08)))
    }

    private var glyph: String {
        switch name {
        case "Bash", "exec_command", "shell": "›_"
        case "Edit", "MultiEdit", "Write", "apply_patch": "✎"
        case "Read": "≡"
        case "Grep", "Glob": "⌕"
        case "WebFetch", "WebSearch": "◎"
        case "Agent", "Task": "◆"
        default: "•"
        }
    }
}

struct WorkingIndicator: View {
    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Sta lavorando…").font(.system(size: 13)).foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

/// Conversazione dal vivo di una sessione lanciata da Belvedere: messaggi, testo in arrivo, richieste.
struct HostedTranscript: View {
    let host: HostedSession

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if host.state.items.isEmpty && host.state.streaming == nil && host.state.asks.isEmpty {
                        Text(host.isRunning ? "Scrivi il primo messaggio." : "La sessione non è avviata.")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 60)
                    }
                    ForEach(host.state.items) { item in
                        TranscriptRow(item: item)
                    }
                    if let streaming = host.state.streaming {
                        StreamingText(text: streaming)
                    }
                    ForEach(host.state.asks) { ask in
                        if ask.isQuestion {
                            QuestionCard(host: host, ask: ask)
                        } else {
                            PermissionCard(host: host, ask: ask)
                        }
                    }
                    if host.state.status == .working && host.state.streaming == nil && host.state.asks.isEmpty {
                        WorkingIndicator()
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .frame(maxWidth: 700)
                .padding(.horizontal, 28)
                .padding(.vertical, 22)
                .frame(maxWidth: .infinity)
            }
            .scrollContentBackground(.hidden)
            .defaultScrollAnchor(.bottom)
            .onChange(of: host.state.items.count) { scrollToEnd(proxy) }
            .onChange(of: host.state.asks.count) { scrollToEnd(proxy) }
            .onChange(of: host.state.streaming?.count) { proxy.scrollTo("end", anchor: .bottom) }
        }
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy) {
        withAnimation(.smooth(duration: 0.25)) { proxy.scrollTo("end", anchor: .bottom) }
    }
}

/// Testo dell'assistente mentre arriva, con un cursore che pulsa.
struct StreamingText: View {
    let text: String
    @State private var on = true

    var body: some View {
        (Text(TranscriptRow.markdown(text)) + Text(" ▍").foregroundStyle(Theme.accent.opacity(on ? 1 : 0.2)))
            .font(.system(size: 14))
            .lineSpacing(4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.6).repeatForever()) { on = false }
            }
    }
}
