import ZonexploCore
import SwiftUI
import UIKit

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL

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

                Picker("Voice", selection: $model.settings.voiceIdentifier) {
                    Text("Automatic").tag(String?.none)
                    ForEach(spokenLanguageVoices) { voice in
                        Text("\(voice.name) · \(voice.quality.label)").tag(String?.some(voice.id))
                    }
                }
                .disabled(!model.settings.voiceEnabled || spokenLanguageVoices.isEmpty)

                VStack(alignment: .leading, spacing: 2) {
                    LabeledContent("Speaking speed", value: rateLabel)
                    Slider(value: $model.settings.speechRate, in: 0.7...1.4, step: 0.05)
                        .accessibilityLabel("Speaking speed")
                        .accessibilityValue(rateLabel)
                }
                .disabled(!model.settings.voiceEnabled)

                Button("Hear a sample") {
                    model.voice.preview()
                }
                .disabled(!model.settings.voiceEnabled)

                Toggle("Silent switch mutes Zonexplo", isOn: $model.settings.respectSilentSwitch)
            } header: {
                Text("Voice")
            } footer: {
                Text(voiceFooter)
            }

            Section {
                Toggle("Average speed zones", isOn: $model.settings.announceZones)
                Toggle("Speed cameras", isOn: $model.settings.announcePointCameras)
                Toggle("Red light cameras", isOn: $model.settings.announceRedLightCameras)
                Toggle("Mobile camera spots", isOn: $model.settings.announceMobileHotspots)
            } header: {
                Text("Camera alerts")
            } footer: {
                Text(
                    "Each of these can be silenced on its own. Mobile camera spots are "
                        + "places police are known to park a van; they are a warning that "
                        + "one might be there, not that one is."
                )
            }
            // Every toggle above is a category of *spoken* warning, so with the
            // voice off they are four switches that visibly do nothing. The
            // road-limit pair below has always been disabled by its parent;
            // this is the same rule applied to the parent above it.
            .disabled(!model.settings.voiceEnabled)

            Section {
                Toggle("Show the limit on screen", isOn: $model.settings.showSpeedLimit)
                Toggle("Say when I am over it", isOn: $model.settings.announceSpeedLimit)
                    .disabled(!model.settings.showSpeedLimit || !model.settings.voiceEnabled)
                NavigationLink {
                    CountryDownloadView()
                } label: {
                    LabeledContent("Limits downloaded", value: limitSummary)
                }
            } header: {
                Text("Road speed limit")
            } footer: {
                Text(
                    "The limit for the road you are on, from OpenStreetMap. It is spoken "
                        + "only after you have held a speed over it for a few seconds, and "
                        + "not more than once a minute. Roads nobody has tagged have no "
                        + "limit and stay silent rather than being guessed at. Limits are "
                        + "downloaded per country and are much larger than the camera data."
                )
            }

            Section {
                NavigationLink {
                    CountryDownloadView()
                } label: {
                    LabeledContent("Countries", value: downloadSummary)
                }
                LabeledContent("Location access", value: locationSummary)

                // Anything short of Always means no warning can ever be spoken
                // with the phone locked, which is the whole product. Naming the
                // problem and offering no way out of it is the one thing this
                // row must not do.
                if model.location.authorizationStatus == .notDetermined {
                    Button("Allow location access") {
                        Task { _ = await model.location.requestWhenInUse() }
                    }
                } else if model.location.authorizationStatus != .authorizedAlways {
                    Button("Fix in iOS Settings") { openSystemSettings() }
                }

                NavigationLink("Drive history") { DriveHistoryView() }

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
                Toggle("Start when I start driving", isOn: $model.settings.autoStartWhenDriving)
                    .disabled(!DrivingDetector.isSupported)
            } footer: {
                Text(
                    DrivingDetector.isSupported
                        ? "Zonexplo begins watching by itself once your phone is confident it is "
                            + "in a moving car, so a drive is never missed because nobody pressed "
                            + "start. It never stops by itself: at a red light you are still driving."
                        : "This iPhone does not report motion activity, so watching has to be "
                            + "started by hand."
                )
            }

            Section {
                Toggle("Share anonymous usage", isOn: $model.settings.analyticsEnabled)
            } header: {
                Text("Privacy")
            } footer: {
                Text(
                    "Counts of things like how often the app is watching the road and which "
                        + "countries get downloaded, so the parts nobody uses can be found and "
                        + "removed. Never your location, never a camera or a road, and no "
                        + "account is involved because there is not one. Turning this off shuts "
                        + "the collector down rather than muting it."
                )
            }

            Section {
                LabeledContent("Version", value: version)
            } footer: {
                Text(
                    "Zonexplo is a speed awareness aid, not a navigator, and not a substitute "
                        + "for the signs. Camera data comes from OpenStreetMap contributors and "
                        + "published enforcement announcements, and it will sometimes be wrong. "
                        + "The limit on the sign is always the limit."
                )
            }
        }
        .navigationTitle("Settings")
        // A voice can be installed in iOS Settings while Zonexplo sits in the
        // background, and a picker that only grows on relaunch is how that
        // download appears to have failed.
        .task {
            model.voice.refreshVoices()

            // It can be deleted there too. VoiceCoach already falls back to the
            // best installed voice, so speech keeps working - but a Picker
            // whose selection matches no row renders blank, which would show an
            // empty setting beside a voice that is audibly speaking.
            if let chosen = model.settings.voiceIdentifier,
               !model.voice.availableVoices.contains(where: { $0.id == chosen }) {
                model.settings.voiceIdentifier = nil
            }
        }
    }

    // MARK: - Voice

    /// The voices that can read the Phrasebook, best first.
    private var spokenLanguageVoices: [VoiceOption] {
        VoiceCatalogue.matching(model.voice.availableVoices, language: VoiceCatalogue.spokenLanguage)
    }

    /// Words rather than a multiplier: 1.05 means nothing to anyone.
    private var rateLabel: String {
        switch model.settings.speechRate {
        case ..<0.85: return "Slow"
        case ..<1.0: return "Relaxed"
        case ..<1.15: return "Normal"
        case ..<1.3: return "Brisk"
        default: return "Fast"
        }
    }

    private var voiceFooter: String {
        let ducking = "Zonexplo ducks whatever you are listening to for a second or two, "
            + "then hands the audio back. It never takes over playback."

        // The compact voice is the robotic one, and nothing in Zonexplo can
        // install a better one - only iOS can. Saying where is the whole point
        // of the hint; without it the driver concludes this is how the app
        // sounds.
        guard VoiceCatalogue.hasUpgradedVoice(
            in: model.voice.availableVoices,
            for: VoiceCatalogue.spokenLanguage
        ) else {
            return ducking
                + "\n\nOnly the basic voice is installed. iOS Settings > Accessibility > "
                + "Spoken Content > Voices has better ones to download, and Zonexplo "
                + "will use the best it finds."
        }
        return ducking
    }

    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        openURL(url)
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
