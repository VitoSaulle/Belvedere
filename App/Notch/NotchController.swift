import AppKit
import BelvedereCore
import Observation
import SwiftUI

/// Finestra senza bordi sopra il notch che mostra lo stato delle sessioni.
@MainActor @Observable
final class NotchController {
    static let enabledKey = "notchEnabled"
    static let canvas = NSSize(width: 560, height: 240)

    private(set) var state: NotchState = .hidden
    private(set) var geometry: NotchGeometry?
    @ObservationIgnored private let model: AppModel
    @ObservationIgnored private var panel: NSPanel?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private let demo: NotchState?

    init(model: AppModel) {
        self.model = model
        demo = UserDefaults.standard.string(forKey: "BelvedereNotchDemo").flatMap(Self.demoState)
    }

    var enabled: Bool {
        UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
    }

    func start() {
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: Self.canvas),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.contentView = NSHostingView(rootView: NotchView(controller: self).environment(model))
        self.panel = panel

        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.layout() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
        layout()
        update()
    }

    func open(_ sessionID: String) {
        model.route = .session(sessionID)
        (NSApp.delegate as? AppDelegate)?.showMainWindow()
    }

    private func update() {
        let next = demo ?? NotchStateMachine.next(sessions: model.sessions, previous: state, now: Date())
        if next != state { state = next }
        guard let panel else { return }
        let visible = enabled && state != .hidden
        switch state {
        case .needsYou, .finished: panel.ignoresMouseEvents = false
        default: panel.ignoresMouseEvents = true
        }
        if visible && !panel.isVisible { panel.orderFrontRegardless() }
        if !visible && panel.isVisible { panel.orderOut(nil) }
    }

    private func layout() {
        geometry = NotchGeometry.current()
        guard let panel, let g = geometry else { return }
        panel.setFrame(NSRect(x: g.screenFrame.midX - Self.canvas.width / 2, y: g.top - Self.canvas.height,
                              width: Self.canvas.width, height: Self.canvas.height), display: true)
    }

    static func demoState(_ name: String) -> NotchState? {
        let now = Date()
        switch name {
        case "resting": return .resting(active: 3)
        case "working": return .working(sessionID: "demo", project: "atlante", since: now.addingTimeInterval(-42))
        case "needsYou":
            return .needsYou(sessionID: "demo", request: PendingRequest(id: "r", kind: .permission, toolName: "Bash",
                                                                        summary: "xcodebuild test -scheme Tercio", receivedAt: now))
        case "finished":
            return .finished(sessionID: "demo", project: "Tercio", summary: "Sincronizzazione completata, test verdi.", at: now)
        default: return nil
        }
    }
}
