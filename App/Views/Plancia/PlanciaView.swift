import BelvedereCore
import SwiftUI

enum PlanciaFilter: String, CaseIterable, Identifiable {
    case all = "Tutte"
    case waiting = "Aspettano te"
    case working = "Al lavoro"
    case finished = "Concluse"

    var id: String { rawValue }

    func matches(_ s: SessionSnapshot) -> Bool {
        switch self {
        case .all: true
        case .waiting: s.status == .waiting
        case .working: s.status == .working
        case .finished: s.status == .done || s.status == .idle || s.status == .ended
        }
    }
}

struct PlanciaView: View {
    @Environment(AppModel.self) private var model
    @State private var filter: PlanciaFilter = .all

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if let progress = model.indexingProgress {
                    IndexingBar(progress: progress)
                }
                if !model.hooksInstalled && model.indexingProgress == nil {
                    ConnectBanner()
                }
                if let error = model.serverError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(Theme.danger)
                }
                content
            }
            .padding(.horizontal, 22)
            .padding(.top, 6)
            .padding(.bottom, 22)
        }
        .scrollContentBackground(.hidden)
        .navigationTitle("")
    }

    private var visible: [SessionSnapshot] {
        model.sessions.filter { s in
            filter.matches(s) && (model.projectFilter == nil || s.cwd == model.projectFilter)
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Plancia").font(.system(size: 26, weight: .bold))
                Text(summary).font(.system(size: 13)).foregroundStyle(.secondary)
            }
            Spacer()
            FilterPicker(selection: $filter)
            Button { model.showNewSession = true } label: {
                Label("Nuova sessione", systemImage: "plus")
                    .font(.system(size: 12.5, weight: .semibold))
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .tint(Theme.accent)
            .help("Nuova sessione (⌘N)")
            Menu {
                let stale = model.staleSessionIDs
                Button("Nascondi le concluse da più di 7 giorni (\(stale.count))") { model.hide(stale) }
                    .disabled(stale.isEmpty)
                if !model.hiddenSessions.isEmpty {
                    SettingsLink { Text("Sessioni nascoste (\(model.hiddenSessions.count))…") }
                }
            } label: {
                Image(systemName: "ellipsis").frame(width: 30, height: 30)
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .circle)
            .help("Altre azioni")
        }
        .padding(.top, 8)
    }

    private var summary: String {
        var parts = ["\(model.sessions.count) sessioni"]
        parts.append("\(model.waitingCount) \(model.waitingCount == 1 ? "aspetta" : "aspettano") te")
        parts.append("\(model.workingCount) al lavoro")
        if let project = model.projectFilter { parts.append("in \(Fmt.folder(project))") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private var content: some View {
        if model.sessions.isEmpty && model.indexingProgress == nil {
            ContentUnavailableView {
                Label("Nessuna sessione", systemImage: "binoculars")
            } description: {
                Text("Apri Claude Code o Codex in un terminale: comparirà qui.")
            }
            .padding(.top, 80)
        } else if visible.isEmpty {
            HStack {
                Spacer()
                VStack(spacing: 8) {
                    Text("Nessuna sessione in questo filtro.").foregroundStyle(.secondary)
                    if model.projectFilter != nil {
                        Button("Mostra tutti i progetti") { model.projectFilter = nil }
                            .buttonStyle(.link)
                    }
                }
                Spacer()
            }
            .padding(.vertical, 80)
        } else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 290, maximum: 420), spacing: 14, alignment: .top)], spacing: 14) {
                ForEach(visible) { session in
                    SessionCard(session: session)
                        .contextMenu { HideButton(sessionID: session.id) }
                }
            }
            .animation(.smooth(duration: 0.25), value: visible.map(\.id))
        }
    }
}

/// Selettore a capsule di vetro: Tutte / Aspettano te / Al lavoro / Concluse.
struct FilterPicker: View {
    @Binding var selection: PlanciaFilter
    @Namespace private var glass

    var body: some View {
        HStack(spacing: 2) {
            ForEach(PlanciaFilter.allCases) { item in
                Button {
                    withAnimation(.smooth(duration: 0.2)) { selection = item }
                } label: {
                    Text(item.rawValue)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(selection == item ? Color.primary : Color.secondary)
                        .padding(.horizontal, 13)
                        .frame(height: 28)
                        .background {
                            if selection == item {
                                Capsule().fill(.background).shadow(color: .black.opacity(0.08), radius: 2, y: 1)
                                    .matchedGeometryEffect(id: "pill", in: glass)
                            }
                        }
                        .contentShape(.capsule)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .glassEffect(.regular, in: .capsule)
    }
}

struct IndexingBar: View {
    let progress: Double

    var body: some View {
        HStack(spacing: 10) {
            ProgressView(value: progress)
                .progressViewStyle(.linear)
                .tint(Theme.accent)
            Text("Lettura dei log · \(Fmt.percent(progress))")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .fixedSize()
        }
    }
}

/// Voce «Nascondi» dei menu contestuali: la sessione esce dalla vista ma i suoi file restano.
struct HideButton: View {
    @Environment(AppModel.self) private var model
    let sessionID: String

    var body: some View {
        Button("Nascondi", systemImage: "eye.slash") { model.hide([sessionID]) }
    }
}
