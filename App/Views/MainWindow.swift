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
                .toolbar {
                    ToolbarItem(placement: .primaryAction) { ProfileMenu() }
                    ToolbarItem(placement: .primaryAction) { AppearanceMenu() }
                }
        }
        .frame(minWidth: 980, minHeight: 620)
        .sheet(isPresented: $model.showWelcome) {
            WelcomeSheet()
        }
        .sheet(isPresented: $model.showNewSession) {
            NewSessionSheet()
        }
        .sheet(isPresented: $model.showPlugins) {
            PluginsSheet()
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

/// Tema dell'app a portata di clic: come il sistema, chiaro o scuro.
private struct AppearanceMenu: View {
    @AppStorage(Appearance.key) private var appearance = Appearance.system.rawValue

    var body: some View {
        Menu {
            Picker("Tema", selection: Binding(get: { appearance }, set: { value in
                appearance = value
                (Appearance(rawValue: value) ?? .system).apply()
            })) {
                ForEach(Appearance.allCases) { Text($0.label).tag($0.rawValue) }
            }
            .pickerStyle(.inline)
        } label: {
            Label("Tema", systemImage: symbol)
        }
        .menuIndicator(.hidden)
        .help("Tema: come il sistema, chiaro o scuro (⇧⌘L per alternare)")
    }

    private var symbol: String {
        switch Appearance(rawValue: appearance) ?? .system {
        case .system: "circle.lefthalf.filled"
        case .light: "sun.max"
        case .dark: "moon"
        }
    }
}
