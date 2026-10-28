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
                .animation(.smooth(duration: 0.3), value: model.route)
                .navigationTitle("")
                .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        }
        .frame(minWidth: 980, minHeight: 620)
        .sheet(isPresented: $model.showWelcome) {
            WelcomeSheet()
        }
        .sheet(isPresented: $model.showNewSession) {
            NewSessionSheet()
        }
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
            SessionView(sessionID: id)
                .id(id)
                .transition(.scale(scale: 0.96).combined(with: .opacity))
                .inspector(isPresented: $showInspector) {
                    SessionInspector(sessionID: id)
                        .inspectorColumnWidth(min: 260, ideal: 300, max: 360)
                }
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button { showInspector.toggle() } label: { Label("Dettagli", systemImage: "sidebar.right") }
                            .help("Mostra o nascondi i dettagli")
                    }
                }
        case .stats:
            StatsView()
        }
    }
}
