import Foundation
import Observation
import Sparkle

/// Aggiornamenti automatici con Sparkle: il feed è l'appcast.xml allegato all'ultima release su GitHub,
/// ogni DMG è firmato con la chiave EdDSA del progetto. Spenti nelle build di sviluppo e senza chiave pubblica.
@MainActor @Observable
final class Updater {
    /// Vero solo se Sparkle è partito: build Release con `SUPublicEDKey` impostata.
    let isAvailable: Bool
    private(set) var canCheck = false
    private let controller: SPUStandardUpdaterController?
    @ObservationIgnored private var observation: NSKeyValueObservation?

    init() {
        #if DEBUG
        let enabled = false
        #else
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? ""
        let enabled = !key.trimmingCharacters(in: .whitespaces).isEmpty
        #endif
        isAvailable = enabled
        guard enabled else { controller = nil; return }
        let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        self.controller = controller
        canCheck = controller.updater.canCheckForUpdates
        observation = controller.updater.observe(\.canCheckForUpdates, options: [.new]) { [weak self] updater, _ in
            let value = updater.canCheckForUpdates
            Task { @MainActor in self?.canCheck = value }
        }
    }

    func checkForUpdates() { controller?.checkForUpdates(nil) }

    var checksAutomatically: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set { controller?.updater.automaticallyChecksForUpdates = newValue }
    }

    /// «0.2.0 (14)», dal bundle.
    static var versionText: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }
}
