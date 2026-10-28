import AppKit
import SwiftUI
import BelvedereCore

@main
struct BelvedereApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup("Belvedere") {
            Text("Belvedere — \(delegate.model.sessions.count) sessioni")
                .frame(minWidth: 900, minHeight: 600)
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
