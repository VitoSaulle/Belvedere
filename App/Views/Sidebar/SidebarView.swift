import BelvedereCore
import SwiftUI

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    /// Righe scelte con ⌘ o ⇧; con una riga sola vale la posizione corrente.
    @State private var picked: Set<Route> = []

    var body: some View {
        @Bindable var model = model
        List(selection: Binding<Set<Route>>(get: { selection }, set: { select($0) })) {
            Label {
                HStack {
                    Text("Plancia")
                    Spacer()
                    if model.waitingCount > 0 {
                        Text("\(model.waitingCount)")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 1)
                            .background(Theme.waiting, in: .capsule)
                    }
                }
            } icon: {
                Image(systemName: "square.grid.2x2")
            }
            .tag(Route.plancia)

            Section {
                ForEach(model.boardSessions.prefix(12)) { session in
                    SessionRow(session: session).tag(Route.session(session.id))
                }
                if model.boardSessions.isEmpty {
                    Text("Nessuna sessione").foregroundStyle(.secondary)
                }
            } header: {
                HStack {
                    Text("Sessioni")
                    Spacer()
                    Button { model.showNewSession = true } label: {
                        Image(systemName: "plus").font(.system(size: 11, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .help("Nuova sessione (⌘N)")
                }
            }

            Section("Progetti") {
                ForEach(projects, id: \.path) { project in
                    HStack {
                        Image(systemName: model.projectFilter == project.path ? "folder.fill" : "folder")
                            .foregroundStyle(model.projectFilter == project.path ? Theme.accent : .secondary)
                        Text(Fmt.folder(project.path)).lineLimit(1)
                        Spacer()
                        Text("\(project.count)").foregroundStyle(.secondary).monospacedDigit()
                    }
                    .help(project.path)
                    .tag(Route.project(project.path))
                }
            }

            Section {
                Label("Statistiche", systemImage: "chart.bar.xaxis").tag(Route.stats)
            }
        }
        .listStyle(.sidebar)
        .contextMenu(forSelectionType: Route.self) { SidebarMenuItems(rows: $0) }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            // Fondo pieno sotto il vetro: le righe che scorrono non devono trasparire dietro i limiti.
            PlanUsageCard()
                .padding(.horizontal, 10)
                .padding(.vertical, 10)
                .background(.bar)
        }
    }

    private var selection: Set<Route> {
        let shown = Set(model.boardSessions.map(\.id))
        let alive = picked.filter { row in
            guard case .session(let id) = row else { return true }
            return shown.contains(id)
        }
        if alive.count > 1 { return alive }
        if model.route == .plancia, let project = model.projectFilter { return [.project(project)] }
        return [model.route]
    }

    /// Una riga sola è una destinazione; più righe sono solo una scelta su cui agire dal menu.
    private func select(_ rows: Set<Route>) {
        picked = rows
        guard rows.count == 1, let row = rows.first else { return }
        switch row {
        case .project(let path):
            model.projectFilter = path
            model.route = .plancia
        case .plancia:
            model.projectFilter = nil
            model.route = .plancia
        default:
            model.route = row
        }
    }

    /// Cartelle distinte delle sessioni attive o recenti, dalla più usata.
    private var projects: [(path: String, count: Int)] {
        let counts = Dictionary(grouping: model.boardSessions.filter { !$0.cwd.isEmpty }, by: \.cwd).mapValues(\.count)
        return counts.map { (path: $0.key, count: $0.value) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.path < $1.path }
            .prefix(8).map { $0 }
    }
}

/// Menu delle righe della sidebar: una sessione, un progetto o più righe insieme.
private struct SidebarMenuItems: View {
    @Environment(AppModel.self) private var model
    let rows: Set<Route>

    var body: some View {
        if let id = single.session {
            SessionMenuItems(sessionID: id)
        } else if let path = single.project {
            ProjectMenuItems(path: path)
        } else if !ids.isEmpty {
            BulkMenuItems(sessionIDs: ids)
        }
    }

    private var single: (session: String?, project: String?) {
        guard rows.count == 1, let row = rows.first else { return (nil, nil) }
        if case .session(let id) = row { return (id, nil) }
        if case .project(let path) = row { return (nil, path) }
        return (nil, nil)
    }

    /// Le sessioni scelte più quelle dei progetti scelti, senza doppioni.
    private var ids: [String] {
        var ids = Set<String>()
        for row in rows {
            if case .session(let id) = row { ids.insert(id) }
            if case .project(let path) = row { ids.formUnion(model.sessionIDs(inProject: path)) }
        }
        return ids.sorted()
    }
}

struct SessionRow: View {
    let session: SessionSnapshot

    var body: some View {
        HStack(spacing: 10) {
            StatusDot(status: session.status)
            VStack(alignment: .leading, spacing: 1) {
                Text(session.displayName).lineLimit(1)
                Text(Theme.label(for: session.status))
                    .font(.system(size: 11))
                    .foregroundStyle(session.status == .waiting ? Theme.waiting : .secondary)
            }
            Spacer(minLength: 4)
            Tag(text: Theme.agentName(session.agent))
        }
        .padding(.vertical, 1)
    }
}
