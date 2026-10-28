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
        }
    }

    static func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
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
