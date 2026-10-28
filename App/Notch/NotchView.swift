import BelvedereCore
import SwiftUI

/// Le quattro forme del notch (tavola E): riposo, al lavoro, ti serve, fatto.
struct NotchView: View {
    @Environment(AppModel.self) private var model
    let controller: NotchController

    static let warm = Color(hex: 0xF2B35B)

    var body: some View {
        let g = controller.geometry
        let bar = g?.barHeight ?? 32
        let hasNotch = g?.hasNotch ?? false
        let notch = hasNotch ? (g?.notchWidth ?? 0) : 0
        // Con il notch i contenuti stanno ai lati della tacca e sotto di essa; senza, la pillola è compatta.
        let inset = hasNotch ? bar : 0
        let size = size(for: controller.state, bar: bar, notch: notch, inset: inset)
        let radius = bottomRadius(for: controller.state)
        VStack(spacing: 0) {
            content(bar: bar, notch: notch, inset: inset)
                .frame(width: size.width, height: size.height, alignment: .top)
                .background(.black, in: UnevenRoundedRectangle(topLeadingRadius: hasNotch ? 0 : radius,
                                                               bottomLeadingRadius: radius,
                                                               bottomTrailingRadius: radius,
                                                               topTrailingRadius: hasNotch ? 0 : radius))
                .shadow(color: .black.opacity(isExpanded ? 0.45 : 0), radius: 22, y: 12)
                .opacity(controller.state == .hidden ? 0 : 1)
            Spacer(minLength: 0)
        }
        .frame(width: NotchController.canvas.width, height: NotchController.canvas.height, alignment: .top)
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .animation(.spring(response: 0.38, dampingFraction: 0.78), value: controller.state)
    }

    private var isExpanded: Bool {
        switch controller.state {
        case .needsYou, .finished: true
        default: false
        }
    }

    private func size(for state: NotchState, bar: CGFloat, notch: CGFloat, inset: CGFloat) -> CGSize {
        let compact = notch == 0
        return switch state {
        case .hidden: CGSize(width: max(notch, 120), height: bar)
        case .resting: CGSize(width: compact ? 84 : max(252, notch + 80), height: bar)
        case .working: CGSize(width: compact ? 270 : max(380, notch + 190), height: bar + 4)
        case .needsYou: CGSize(width: 460, height: inset + 132)
        case .finished: CGSize(width: max(400, notch + 120), height: inset + (compact ? 58 : 40))
        }
    }

    private func bottomRadius(for state: NotchState) -> CGFloat {
        switch state {
        case .needsYou: 30
        case .finished: 26
        case .working: 18
        default: 14
        }
    }

    @ViewBuilder private func content(bar: CGFloat, notch: CGFloat, inset: CGFloat) -> some View {
        switch controller.state {
        case .hidden:
            EmptyView()
        case .resting(let active):
            HStack {
                Image("MenuBarGlyph")
                    .renderingMode(.template)
                    .resizable()
                    .frame(width: 14, height: 14)
                    .foregroundStyle(Self.warm)
                Spacer(minLength: notch == 0 ? 8 : notch)
                Text("\(active)").font(.system(size: 13, weight: .semibold)).monospacedDigit()
            }
            .padding(.horizontal, 14)
            .frame(height: bar)
        case .working(_, let project, let since):
            HStack(spacing: 10) {
                Text(project).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Spacer(minLength: notch == 0 ? 12 : notch)
                ActivityBars()
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(Self.elapsed(since, now: context.date))
                        .font(.system(size: 12.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.75))
                }
            }
            .padding(.horizontal, 16)
            .frame(height: bar + 4)
        case .needsYou(let sessionID, let request):
            NeedsYouContent(sessionID: sessionID, request: request, topInset: inset, controller: controller)
        case .finished(let sessionID, let project, let summary, _):
            HStack(spacing: 12) {
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .bold))
                    .frame(width: 26, height: 26)
                    .background(Theme.done, in: .circle)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(project) · completata").font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text(meta(sessionID, fallback: summary))
                        .font(.system(size: 11.5))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                }
                Spacer()
                Button("Vedi") { controller.open(sessionID) }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 12)
                    .frame(height: 26)
                    .background(.white.opacity(0.14), in: .capsule)
            }
            .padding(.horizontal, 18)
            .padding(.top, max(0, inset - 2))
            .frame(maxHeight: .infinity)
        }
    }

    /// «Locale · 388k token · 47 min»; se la sessione non è nota, il riassunto.
    private func meta(_ sessionID: String, fallback: String) -> String {
        guard let s = model.session(sessionID) else { return fallback }
        var parts = [s.isLocalModel ? "Locale" : (s.model.map(ModelInfo.displayName) ?? "Cloud")]
        parts.append("\(Fmt.tokens(s.tokens.total)) token")
        if let start = s.startedAt, let end = s.lastActivity { parts.append(Fmt.duration(end.timeIntervalSince(start))) }
        return parts.joined(separator: " · ")
    }

    static func elapsed(_ since: Date, now: Date) -> String {
        let s = max(0, Int(now.timeIntervalSince(since)))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
                         : String(format: "%02d:%02d", s / 60, s % 60)
    }
}

/// Quattro barrette che si muovono mentre la sessione lavora.
struct ActivityBars: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 12)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 2) {
                ForEach(0..<4) { i in
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(NotchView.warm)
                        .frame(width: 3, height: 5 + 9 * abs(sin(t * 3 + Double(i) * 0.9)))
                }
            }
            .frame(height: 14)
        }
    }
}

struct NeedsYouContent: View {
    @Environment(AppModel.self) private var model
    let sessionID: String
    let request: PendingRequest
    let topInset: CGFloat
    let controller: NotchController

    var body: some View {
        let session = model.session(sessionID)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle().fill(Theme.waiting).frame(width: 8, height: 8)
                Text("\(session?.displayName ?? "Sessione") \(request.kind == .permission ? "chiede il permesso" : "ti fa una domanda")")
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Spacer()
                Text(session.map { Theme.agentName($0.agent) } ?? "Claude")
                    .font(.system(size: 10.5, weight: .semibold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(.white.opacity(0.12), in: .rect(cornerRadius: 6))
            }
            Text(request.summary.isEmpty ? (request.toolName ?? "") : request.summary)
                .font(.system(size: 12, design: request.kind == .permission ? .monospaced : .default))
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(2)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.white.opacity(0.08), in: .rect(cornerRadius: 10))
            HStack(spacing: 8) {
                Spacer()
                if request.kind == .permission && model.answersHere(sessionID) {
                    pill("Nega", strong: false) { model.respond(to: request, with: .deny(reason: "Negato da Belvedere")) }
                    pill("Apri", strong: false) { controller.open(sessionID) }
                    pill("Consenti", strong: true) { model.respond(to: request, with: .allow) }
                } else if model.host(for: sessionID) != nil {
                    pill("Rispondi", strong: true) { controller.open(sessionID) }
                } else {
                    pill("Apri", strong: false) { controller.open(sessionID) }
                    pill("Vai al terminale", strong: true) { model.activateOrigin(of: sessionID) }
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, topInset + 14)
        .padding(.bottom, 16)
    }

    private func pill(_ title: String, strong: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(strong ? .black : .white)
                .padding(.horizontal, 14)
                .frame(height: 28)
                .background(strong ? Color.white : Color.white.opacity(0.14), in: .capsule)
        }
        .buttonStyle(.plain)
    }
}
