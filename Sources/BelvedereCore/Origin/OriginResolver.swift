import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// Trova l'app (terminale o IDE) da cui è partita una sessione esterna.
public enum OriginResolver {
    public static func friendlyName(bundleID: String, fallback: String) -> String {
        switch bundleID {
        case "com.apple.Terminal": return "Terminale"
        case "com.googlecode.iterm2": return "iTerm"
        case "com.mitchellh.ghostty": return "Ghostty"
        case "com.microsoft.VSCode": return "VS Code"
        case let id where id.hasPrefix("com.jetbrains.intellij"): return "IntelliJ"
        default: return fallback
        }
    }

    /// Il primo processo, a partire da `pid` e risalendo, che è un'app con interfaccia.
    public static func resolve(pid: Int32,
                               appLookup: (Int32) -> (bundleID: String?, name: String?)? = OriginResolver.runningApp) -> SessionOrigin? {
        for candidate in [pid] + ProcessTree.ancestors(of: pid) where candidate > 1 {
            guard let app = appLookup(candidate) else { continue }
            let fallback = app.name ?? app.bundleID ?? "App"
            let name = app.bundleID.map { friendlyName(bundleID: $0, fallback: fallback) } ?? fallback
            return SessionOrigin(appName: name, bundleID: app.bundleID, pid: candidate)
        }
        return nil
    }

    public static func runningApp(_ pid: Int32) -> (bundleID: String?, name: String?)? {
        #if canImport(AppKit)
        guard let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy == .regular else { return nil }
        return (app.bundleIdentifier, app.localizedName)
        #else
        return nil
        #endif
    }
}
