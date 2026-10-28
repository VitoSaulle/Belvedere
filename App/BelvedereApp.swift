import SwiftUI
import BelvedereCore

@main
struct BelvedereApp: App {
    var body: some Scene {
        WindowGroup("Belvedere") {
            Text("Belvedere")
                .frame(minWidth: 900, minHeight: 600)
        }
        MenuBarExtra("Belvedere", systemImage: "building.columns") {
            Text("Belvedere")
        }
    }
}
