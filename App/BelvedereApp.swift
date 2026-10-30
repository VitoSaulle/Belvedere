import AppKit
import SwiftUI
import BelvedereCore

@main
struct BelvedereApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @AppStorage(Appearance.key) private var appearance = Appearance.system.rawValue

    var body: some Scene {
        Window("Belvedere", id: "main") {
            MainWindow()
                .environment(delegate.model)
                .background(OpenWindowBridge(delegate: delegate))
        }
        .defaultSize(width: 1360, height: 860)
        .commands {
            CommandGroup(after: .appInfo) {
                if delegate.updater.isAvailable {
                    Button("Controlla aggiornamenti…") { delegate.updater.checkForUpdates() }
                        .disabled(!delegate.updater.canCheck)
                }
            }
            CommandGroup(replacing: .newItem) {
                Button("Nuova sessione…") { delegate.model.showNewSession = true }
                    .keyboardShortcut("n")
            }
            CommandGroup(after: .sidebar) {
                Button("Plancia") { delegate.model.route = .plancia }
                    .keyboardShortcut("0")
                Button("Statistiche") { delegate.model.route = .stats }
                    .keyboardShortcut("s", modifiers: [.command, .option])
                Button("Plugin di Claude Code…") { delegate.model.showPlugins = true }
                Divider()
                Picker("Aspetto", selection: Binding(get: { appearance }, set: { setAppearance(Appearance(rawValue: $0) ?? .system) })) {
                    ForEach(Appearance.allCases) { Text($0.label).tag($0.rawValue) }
                }
                Button("Passa al tema chiaro o scuro") { setAppearance(Appearance.isDark ? .light : .dark) }
                    .keyboardShortcut("l", modifiers: [.command, .shift])
            }
        }
        Settings {
            SettingsView()
                .environment(delegate.model)
                .environment(delegate.updater)
        }

        // Anteprima del pannello della menu bar in una finestra: `--args -BelvedereShowPanel YES`.
        Window("Pannello", id: "panel-preview") {
            MenuBarPanel()
                .environment(delegate.model)
                .background(.regularMaterial)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(UserDefaults.standard.bool(forKey: "BelvedereShowPanel") ? .presented : .suppressed)

        MenuBarExtra {
            MenuBarPanel()
                .environment(delegate.model)
        } label: {
            MenuBarLabel(active: delegate.model.workingCount + delegate.model.waitingCount,
                         waiting: delegate.model.waitingCount > 0)
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    let updater = Updater()
    private var hotKey: GlobalHotKey?
    private var notch: NotchController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Appearance.current.apply()
        // La shell può metterci un attimo: si legge subito, così la prima sessione non aspetta.
        DispatchQueue.global(qos: .userInitiated).async { _ = ShellEnvironment.current }
        hotKey = GlobalHotKey { [weak self] in self?.showMainWindow() }
        let notch = NotchController(model: model)
        notch.start()
        self.notch = notch
        Task { await model.start() }
    }

    /// Porta in primo piano la finestra principale, riaprendola se era chiusa.
    func showMainWindow() {
        NSApp.activate()
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "main" || $0.title == "Belvedere" }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            openMainWindow?()
        }
    }

    /// Impostata dalla scena: apre la finestra con `openWindow(id: "main")`.
    var openMainWindow: (() -> Void)?

    /// Chiudere la finestra lascia l'app nella menu bar.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let working = model.workingHostedCount
        if working > 0 {
            let alert = NSAlert()
            alert.messageText = working == 1 ? "Una sessione sta lavorando" : "\(working) sessioni stanno lavorando"
            alert.informativeText = "Uscendo si fermano. Potrai riprenderle da Belvedere o dal terminale."
            alert.addButton(withTitle: "Esci")
            alert.addButton(withTitle: "Annulla")
            guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        }
        Task {
            await model.shutdown()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

/// Aspetto dell'app, indipendente da quello di sistema se l'utente lo sceglie.
enum Appearance: String, CaseIterable, Identifiable {
    case system, light, dark

    static let key = "appearance"
    var id: String { rawValue }

    static var current: Appearance {
        UserDefaults.standard.string(forKey: key).flatMap(Appearance.init) ?? .system
    }

    var label: String {
        switch self {
        case .system: "Come il sistema"
        case .light: "Chiaro"
        case .dark: "Scuro"
        }
    }

    /// L'aspetto in uso adesso, anche quando segue il sistema.
    @MainActor static var isDark: Bool {
        NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    @MainActor func apply() {
        switch self {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

extension BelvedereApp {
    private func setAppearance(_ value: Appearance) {
        appearance = value.rawValue
        value.apply()
    }
}

/// Passa all'AppDelegate la funzione per riaprire la finestra principale.
private struct OpenWindowBridge: View {
    @Environment(\.openWindow) private var openWindow
    let delegate: AppDelegate

    var body: some View {
        Color.clear.onAppear { delegate.openMainWindow = { openWindow(id: "main") } }
    }
}
