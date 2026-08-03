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
                    "Each of these can be silenced on its own. Mobile camera spots are "
                        + "places police are known to park a van; they are a warning that "
                        + "one might be there, not that one is."
                )
            }

            Section {
                Toggle("Show the limit on screen", isOn: $model.settings.showSpeedLimit)
                Toggle("Say when I am over it", isOn: $model.settings.announceSpeedLimit)
                    .disabled(!model.settings.showSpeedLimit)
                LabeledContent("Limits downloaded", value: limitSummary)
            } header: {
                Text("Road speed limit")
            } footer: {
                Text(
                    "The limit for the road you are on, from OpenStreetMap. It is spoken "
                        + "only after you have held a speed over it for a few seconds, and "
                        + "not more than once a minute. Roads nobody has tagged have no "
                        + "limit and stay silent rather than being guessed at. Download "
                        + "limits per country under Countries; they are much larger than "
                        + "the camera data."
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
                LabeledContent("Position updates", value: trackingSummary)
            } header: {
                Text("Data and permissions")
            } footer: {
                // "I heard nothing on my drive" has three possible causes -
                // no permission, no fix stream, no data - and from the outside
                // they are indistinguishable. This row separates them without
                // anyone having to attach a debugger.
                Text(
                    "Position updates should show a rising count while you are watching "
                        + "the road. If it stays at nothing, no warning can be timed and "
                        + "the problem is location access rather than the alerts."
                )
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

    /// How many countries this phone holds speed limits for.
    private var limitSummary: String {
        let installed = model.sync?.countries.filter(\.roadLimitsInstalled) ?? []
        switch installed.count {
        case 0: return "None"
        case 1: return installed[0].name
        default: return "\(installed.count) countries"
        }
    }

    private var trackingSummary: String {
        let count = model.location.fixCount
        switch model.location.mode {
        case .off: return "Not watching"
        case .drive: return "\(count) received"
        case .precise: return "\(count) received, in a zone"
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
