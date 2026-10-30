import BelvedereCore
import SwiftUI

/// Il testo con cui si apre il selettore di `/resume`.
struct ResumeSearch: Identifiable {
    let id = UUID()
    let text: String
}

/// `/resume` dalla chat: sceglie un'altra conversazione e la apre nella sua chat, con questa che resta aperta.
struct ResumePicker: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let agent: AgentKind
    let folder: String
    let currentID: String
    @State private var search: String
    @State private var allProjects = false

    init(agent: AgentKind, folder: String, currentID: String, query: String) {
        self.agent = agent
        self.folder = folder
        self.currentID = currentID
        _search = State(initialValue: query)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Riprendi una conversazione").font(.system(size: 15, weight: .semibold))
            TextField("Cerca", text: $search).textFieldStyle(.roundedBorder)
            Toggle("Tutti i progetti", isOn: $allProjects)
            if matches.isEmpty {
                ContentUnavailableView("Nessuna conversazione", systemImage: "text.bubble")
            } else {
                List(matches) { session in
                    row(session)
                }
                .listStyle(.plain)
            }
            HStack {
                Spacer()
                Button("Annulla") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(16)
        .frame(width: 520, height: 460)
    }

    private var matches: [SessionSnapshot] {
        let query = search.trimmingCharacters(in: .whitespaces)
        return model.sessions
            .filter { $0.agent == agent && $0.id != currentID && (allProjects || $0.cwd == folder) }
            .filter { query.isEmpty || [$0.displayName, $0.lastText ?? "", $0.id].contains { $0.localizedCaseInsensitiveContains(query) } }
            .sorted { ($0.lastActivity ?? .distantPast) > ($1.lastActivity ?? .distantPast) }
    }

    private func row(_ session: SessionSnapshot) -> some View {
        let available = model.isHosted(session.id) || model.canResumeHere(session)
        return Button {
            model.resume(session.id)
            dismiss()
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.displayName).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    Text(session.lastText ?? Fmt.folder(session.cwd))
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Text(available ? Fmt.ago(session.lastActivity) : "Aperta altrove")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(!available)
    }
}
