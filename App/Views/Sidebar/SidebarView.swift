import BelvedereCore
import SwiftUI

struct SidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        List(selection: Binding<Route?>(get: { model.route }, set: { if let r = $0 { model.route = r } })) {
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

            Section("Sessioni") {
                ForEach(model.sessions.prefix(12)) { session in
                    SessionRow(session: session).tag(Route.session(session.id))
                }
                if model.sessions.isEmpty {
                    Text("Nessuna sessione").foregroundStyle(.secondary)
                }
            }

            Section("Progetti") {
                ForEach(projects, id: \.path) { project in
                    Button {
                        model.projectFilter = model.projectFilter == project.path ? nil : project.path
                        model.route = .plancia
                    } label: {
                        HStack {
                            Image(systemName: model.projectFilter == project.path ? "folder.fill" : "folder")
                                .foregroundStyle(model.projectFilter == project.path ? Theme.accent : .secondary)
                            Text(Fmt.folder(project.path)).lineLimit(1)
                            Spacer()
                            Text("\(project.count)").foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                    .buttonStyle(.plain)
                    .help(project.path)
                }
            }

            Section {
                Label("Statistiche", systemImage: "chart.bar.xaxis").tag(Route.stats)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            // Fondo pieno sotto il vetro: le righe che scorrono non devono trasparire dietro i limiti.
            PlanUsageCard()
                .padding(.horizontal, 10)
                .padding(.vertical, 10)
                .background(.bar)
        }
    }

    /// Cartelle distinte delle sessioni attive o recenti, dalla più usata.
    private var projects: [(path: String, count: Int)] {
        let counts = Dictionary(grouping: model.sessions.filter { !$0.cwd.isEmpty }, by: \.cwd).mapValues(\.count)
        return counts.map { (path: $0.key, count: $0.value) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.path < $1.path }
            .prefix(8).map { $0 }
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
