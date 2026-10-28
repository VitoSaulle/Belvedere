import BelvedereCore
import SwiftUI

/// Switch del profilo attivo, una sezione per CLI. Compare solo se almeno una CLI ha più profili.
struct ProfileMenu: View {
    @Environment(AppModel.self) private var model

    static func isVisible(_ model: AppModel) -> Bool { AgentKind.allCases.contains(where: model.profiles.hasChoice) }

    var body: some View {
        if Self.isVisible(model) {
            Menu {
                ForEach(AgentKind.allCases.filter(model.profiles.hasChoice), id: \.self) { agent in
                    Section(agent.productName) {
                        ForEach(model.profiles.profiles(agent)) { profile in
                            Toggle(isOn: Binding(get: { model.profiles.active(agent).id == profile.id },
                                                 set: { if $0 { model.setActiveProfile(profile.id) } })) {
                                Text(ProfileMenu.label(profile, model: model))
                            }
                            .disabled(model.profileFolderMissing(profile))
                        }
                    }
                }
            } label: {
                Label(title, systemImage: "person.crop.circle")
            }
            .help("Profilo attivo: le nuove sessioni partono con questo account")
        }
    }

    private var title: String {
        AgentKind.allCases.filter(model.profiles.hasChoice).map { model.profiles.active($0).name }.joined(separator: " · ")
    }

    /// «Lavoro 2 · 5 h 34%», con la finestra di 5 ore se nota.
    static func label(_ profile: Profile, model: AppModel) -> String {
        if model.profileFolderMissing(profile) { return "\(profile.name) · cartella mancante" }
        guard let five = model.limits(for: profile.id)?.fiveHour else { return profile.name }
        return "\(profile.name) · 5 h \(Fmt.percent(five.usedPercent / 100))"
    }
}
