import GlidePathCore
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        Form {
            Section("Units") {
                Picker("Distance and speed", selection: $model.settings.units) {
                    Text("Kilometres").tag(DistanceUnits.metric)
                    Text("Miles").tag(DistanceUnits.imperial)
                }
                .pickerStyle(.segmented)
            }

            Section {
                Toggle("Spoken alerts", isOn: $model.settings.voiceEnabled)

                Button("Hear a sample") {
                    model.voice.preview()
                }
                .disabled(!model.settings.voiceEnabled)
            } header: {
                Text("Voice")
            } footer: {
                Text(
                    "GlidePath ducks whatever you are listening to for a second or two, "
                        + "then hands the audio back. It never takes over playback."
                )
            }

            Section {
                Toggle("Average speed zones", isOn: $model.settings.announceZones)
                Toggle("Speed cameras", isOn: $model.settings.announcePointCameras)
                Toggle("Red light cameras", isOn: $model.settings.announceRedLightCameras)
                Toggle("Mobile camera spots", isOn: $model.settings.announceMobileHotspots)
            } header: {
                Text("What to announce")
            } footer: {
                Text(
                    "Mobile camera spots are places police are known to park a van. "
                        + "They are a warning that one might be there, not that one is."
                )
            }

            Section {
                Toggle("Silent switch mutes GlidePath", isOn: $model.settings.respectSilentSwitch)
            } footer: {
                Text(
                    "Off by default, so a phone silenced for a meeting still warns you about a camera."
                )
            }

            Section {
                NavigationLink {
                    CountryDownloadView()
                } label: {
                    LabeledContent("Countries", value: downloadSummary)
                }
                LabeledContent("Location access", value: locationSummary)
            } header: {
                Text("Data and permissions")
            }

            Section {
                LabeledContent("Version", value: version)
            } footer: {
                Text(
                    "GlidePath is a speed awareness aid, not a navigator, and not a substitute "
                        + "for the signs. Camera data comes from OpenStreetMap contributors and "
                        + "published enforcement announcements, and it will sometimes be wrong. "
                        + "The limit on the sign is always the limit."
                )
            }
        }
        .navigationTitle("Settings")
    }

    /// How many countries this phone actually holds, so the row answers the
    /// question without needing to be tapped.
    private var downloadSummary: String {
        let installed = model.sync?.countries.filter(\.isInstalled) ?? []
        switch installed.count {
        case 0: return "None downloaded"
        case 1: return installed[0].name
        default: return "\(installed.count) downloaded"
        }
    }

    private var locationSummary: String {
        switch model.location.authorizationStatus {
        case .authorizedAlways: return "Always"
        case .authorizedWhenInUse: return "While using, background alerts off"
        case .denied: return "Denied"
        case .restricted: return "Restricted"
        case .notDetermined: return "Not asked yet"
        @unknown default: return "Unknown"
        }
    }

    private var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(short) (\(build))"
    }
}
