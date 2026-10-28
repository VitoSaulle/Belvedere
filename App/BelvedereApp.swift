import AppKit
import SwiftUI
import BelvedereCore

@main
struct BelvedereApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("Belvedere", id: "main") {
            MainWindow()
                .environment(delegate.model)
        }
        .defaultSize(width: 1360, height: 860)
        .commands {
            CommandGroup(after: .sidebar) {
                Button("Plancia") { delegate.model.route = .plancia }
                    .keyboardShortcut("0")
                Button("Statistiche") { delegate.model.route = .stats }
                    .keyboardShortcut("s", modifiers: [.command, .option])
            }
        }
        MenuBarExtra("Belvedere", systemImage: "building.columns") {
            Text("Belvedere")
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        Appearance.current.apply()
        Task { await model.start() }
    }

    /// Chiudere la finestra lascia l'app nella menu bar.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
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

    @MainActor func apply() {
        switch self {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}
