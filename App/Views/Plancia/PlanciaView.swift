import AppKit
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
                if !model.cardSelection.isEmpty { selectionBar }
                content
            }
            .padding(.horizontal, 22)
            .padding(.top, 6)
            .padding(.bottom, 22)
        }
        .scrollContentBackground(.hidden)
        .navigationTitle("")
        .onChange(of: filter) { model.cardSelection = SessionSelection() }
        .onChange(of: model.projectFilter) { model.cardSelection = SessionSelection() }
    }

    private var selectionBar: some View {
        let ids = model.cardSelection.ids.sorted()
        return HStack(spacing: 10) {
            Text(ids.count == 1 ? "1 sessione selezionata" : "\(ids.count) sessioni selezionate")
                .font(.system(size: 12.5, weight: .medium))
            Spacer()
            Button("Nascondi", systemImage: "eye.slash") { model.hide(ids) }
            DeleteButton(sessionIDs: ids)
            Button("Annulla") { model.cardSelection = SessionSelection() }
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
    }

    private var visible: [SessionSnapshot] {
        model.boardSessions.filter { s in
            filter.matches(s) && (model.projectFilter == nil || s.cwd == model.projectFilter)
        }
    }

    /// Su una riga se c'è spazio, altrimenti i comandi vanno sotto il titolo: le etichette del filtro
    /// non si troncano mai.
    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 14) {
                titleBlock
                Spacer(minLength: 14)
                controls
            }
            VStack(alignment: .leading, spacing: 12) {
                titleBlock
                HStack(spacing: 14) { controls }
            }
        }
        .padding(.top, 8)
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Plancia").font(.system(size: 26, weight: .bold))
            Text(summary).font(.system(size: 13)).foregroundStyle(.secondary)
        }
        .fixedSize()
    }

    @ViewBuilder private var controls: some View {
        FilterPicker(selection: $filter)
        if ProfileMenu.isVisible(model) {
            @Bindable var model = model
            Toggle(isOn: $model.showOnlyActiveProfile) {
                Label("Solo profilo attivo", systemImage: "person.crop.circle")
                    .font(.system(size: 12.5, weight: .medium))
                    .fixedSize()
            }
            .toggleStyle(.button)
            .buttonBorderShape(.capsule)
            .help("Mostra solo le sessioni dei profili attivi")
        }
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
            Button(stale.isEmpty ? "Nessuna sessione conclusa da più di 7 giorni"
                                 : "Nascondi le concluse da più di 7 giorni (\(stale.count))",
                   systemImage: "eye.slash") { model.hide(stale) }
                .disabled(stale.isEmpty)
            let staleDeletable = model.staleDeletableIDs
            DeleteButton(sessionIDs: staleDeletable,
                         title: staleDeletable.isEmpty ? "Nessuna sessione da eliminare"
                                                       : "Elimina le concluse da più di 7 giorni (\(staleDeletable.count))…")
            SettingsLink {
                Label("Sessioni nascoste (\(model.hiddenSessions.count))…", systemImage: "archivebox")
            }
            Divider()
            Button("Statistiche", systemImage: "chart.bar") { model.route = .stats }
            Button("Plugin di Claude Code…", systemImage: "puzzlepiece.extension") { model.showPlugins = true }
            SettingsLink { Label("Impostazioni…", systemImage: "gearshape") }
        } label: {
            Image(systemName: "ellipsis")
                .frame(width: 18, height: 18)
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .fixedSize()
        .help("Altre azioni")
    }

    private var summary: String {
        var parts = ["\(model.boardSessions.count) sessioni"]
        parts.append("\(model.waitingCount) \(model.waitingCount == 1 ? "aspetta" : "aspettano") te")
        parts.append("\(model.workingCount) al lavoro")
        if let project = model.projectFilter { parts.append("in \(Fmt.folder(project))") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private var content: some View {
        if model.boardSessions.isEmpty && model.indexingProgress == nil {
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
                    SessionCard(session: session, order: visible.map(\.id))
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
                        .fixedSize()
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

/// Voci «Nascondi» ed «Elimina…» dei menu contestuali delle sessioni.
struct SessionMenuItems: View {
    @Environment(AppModel.self) private var model
    let sessionID: String

    var body: some View {
        if let session = model.session(sessionID) { ContinueMenu(session: session) }
        Button("Nascondi", systemImage: "eye.slash") { model.hide([sessionID]) }
        DeleteButton(sessionIDs: [sessionID])
    }
}

/// «Nascondi» ed «Elimina…» su più sessioni scelte insieme.
struct BulkMenuItems: View {
    @Environment(AppModel.self) private var model
    let sessionIDs: [String]

    var body: some View {
        Button("Nascondi \(sessionIDs.count) sessioni", systemImage: "eye.slash") { model.hide(sessionIDs) }
        DeleteButton(sessionIDs: sessionIDs, title: "Elimina \(sessionIDs.count) sessioni…")
    }
}

/// «Nascondi» ed «Elimina…» su tutte le sessioni di un progetto. La cartella non si tocca.
struct ProjectMenuItems: View {
    @Environment(AppModel.self) private var model
    let path: String

    var body: some View {
        let ids = model.sessionIDs(inProject: path)
        Button("Nascondi il progetto \(Fmt.folder(path))", systemImage: "eye.slash") { model.hide(ids) }
        DeleteButton(sessionIDs: ids, title: "Elimina le sessioni di \(Fmt.folder(path)) (\(ids.count))…")
    }
}

/// «Continua con…»: la conversazione passa a un altro profilo della stessa CLI.
struct ContinueMenu: View {
    @Environment(AppModel.self) private var model
    let session: SessionSnapshot

    var body: some View {
        if model.profiles.hasChoice(session.agent) {
            Menu("Continua con…", systemImage: "arrow.right.arrow.left") {
                ForEach(model.continueTargets(session)) { profile in
                    Button(ProfileMenu.label(profile, model: model)) {
                        Task { await model.continueIn(session.id, profile: profile.id) }
                    }
                }
            }
            .disabled(!model.canContinueElsewhere(session) || model.continueTargets(session).isEmpty)
        }
    }
}

/// Elimina le sessioni dal disco, dopo una conferma: i file non passano dal Cestino.
struct DeleteButton: View {
    @Environment(AppModel.self) private var model
    let sessionIDs: [String]
    var title = "Elimina…"

    var body: some View {
        let deletable = sessionIDs.filter { id in model.session(id).map(model.canDelete) ?? false }
        Button(title, systemImage: "trash", role: .destructive) {
            guard confirmDeletion(deletable.count) else { return }
            Task { await model.delete(deletable) }
        }
        .disabled(deletable.isEmpty)
    }
}

@MainActor func confirmDeletion(_ count: Int) -> Bool {
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = count == 1 ? "Eliminare la sessione?" : "Eliminare \(count) sessioni?"
    alert.informativeText = "I file della trascrizione vengono cancellati subito, senza passare dal Cestino, "
        + "e non si potranno più riprendere. Le cartelle dei progetti e le statistiche d'uso restano."
    alert.addButton(withTitle: "Elimina").hasDestructiveAction = true
    alert.addButton(withTitle: "Annulla")
    return alert.runModal() == .alertFirstButtonReturn
}
