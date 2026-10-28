import BelvedereCore
import SwiftUI

enum Route: Hashable {
    case plancia
    case session(String)
    case stats
}

struct MainWindow: View {
    @Environment(AppModel.self) private var model
    @State private var showInspector = true

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 230, ideal: 252, max: 300)
        } detail: {
            detail
                .background(Backdrop())
        }
        .frame(minWidth: 980, minHeight: 620)
    }

    @ViewBuilder private var detail: some View {
        switch model.route {
        case .plancia:
            PlanciaView()
                .inspector(isPresented: $showInspector) {
                    PlanciaInspector()
                        .inspectorColumnWidth(min: 260, ideal: 300, max: 360)
                }
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button { showInspector.toggle() } label: { Label("Riepilogo", systemImage: "sidebar.right") }
                            .help("Mostra o nascondi il riepilogo")
                    }
                }
        case .session(let id):
            SessionPlaceholder(sessionID: id)
        case .stats:
            ContentUnavailableView("Statistiche", systemImage: "chart.bar.xaxis", description: Text("In arrivo."))
        }
    }
}

/// Segnaposto della vista sessione, sostituito nel Task 13.
struct SessionPlaceholder: View {
    @Environment(AppModel.self) private var model
    let sessionID: String

    var body: some View {
        Text(model.session(sessionID)?.displayName ?? sessionID)
            .font(.title2.weight(.semibold))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
