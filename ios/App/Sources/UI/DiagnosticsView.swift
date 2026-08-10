import CoreLocation
import SwiftUI
import ZonexploCore

/// "It didn't say anything" — answered.
///
/// A tester who hears nothing cannot tell the difference between a muted
/// switch, a permission never granted, a country never downloaded and a zone
/// that was rejected at harvest. Neither can the developer reading their
/// message. Every one of those is a different fix.
///
/// So this is a checklist before it is a log. Each row is one gate the app
/// actually passes through on the way to speaking, evaluated live, and any row
/// that fails says what to do about it. The event log underneath is for the
/// cases the checklist cannot predict, and the share button is for when it
/// needs a second pair of eyes.
struct DiagnosticsView: View {
    @Environment(AppModel.self) private var model

    private var monitor: DriveMonitor? { model.monitor }
    private var log: Diagnostics { Diagnostics.shared }

    var body: some View {
        List {
            Section {
                ForEach(checks) { check in
                    row(check)
                }
            } header: {
                Text("Can it warn you?")
            } footer: {
                Text(
                    failing.isEmpty
                        ? "Everything needed to speak is in place. If it is still silent on a "
                            + "drive, share the report below — the log records why each line was "
                            + "or was not spoken."
                        : "\(failing.count) of these will stop you hearing anything. Fix those first."
                )
            }

            Section("Right now") {
                LabeledContent("Watching", value: model.settings.isWatching ? "Yes" : "No")
                LabeledContent("Position updates", value: "\(model.location.fixCount)")
                LabeledContent("Speed", value: speedText)
                LabeledContent("Cameras nearby", value: "\(monitor?.nearbyCameras.count ?? 0)")
                LabeledContent("Zones nearby", value: "\(monitor?.nearbyZones.count ?? 0)")
                LabeledContent("In a zone", value: monitor?.activeZone?.name ?? "No")
            }

            Section {
                ForEach(log.entries.reversed()) { entry in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.message)
                            .font(.footnote)
                        // Parenthesised: without them the modifiers bind to the
                        // second Text only and the timestamp keeps body size.
                        (
                            Text(entry.at, format: .dateTime.hour().minute().second())
                                + Text("  ·  \(entry.category.rawValue)")
                        )
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Recent decisions")
            } footer: {
                Text(
                    log.entries.isEmpty
                        ? "Nothing yet. Start watching the road and drive; every decision to "
                            + "speak or stay quiet is recorded here."
                        : "The last \(log.entries.count) decisions the app made."
                )
            }

            Section {
                ShareLink(item: log.report(snapshot)) {
                    Label("Share diagnostic report", systemImage: "square.and.arrow.up")
                }
                Button("Clear log", role: .destructive) { log.clear() }
                    .disabled(log.entries.isEmpty)
            } footer: {
                Text(
                    "The report contains your settings, permissions, what is downloaded and the "
                        + "list above. It contains no coordinates and nothing about where you have "
                        + "driven, and it is only ever sent when you tap share."
                )
            }
        }
        .navigationTitle("Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - The gates

    private struct Check: Identifiable {
        let id = UUID()
        let title: String
        let passing: Bool
        /// What to do about it. Nil when the check passes.
        let fix: String?
    }

    private var failing: [Check] { checks.filter { !$0.passing } }

    /// In the order the app passes through them, so the first failing row is
    /// the one that matters.
    private var checks: [Check] {
        let status = model.location.authorizationStatus
        let installed = model.sync?.countries.filter(\.isInstalled) ?? []
        let zoneCountries = installed.filter { $0.zoneCount > 0 }

        return [
            Check(
                title: "Location access is Always",
                passing: status == .authorizedAlways,
                fix: status == .authorizedAlways ? nil
                    : "Nothing can be announced with the screen locked. "
                        + "Settings > Zonexplo > Location > Always."
            ),
            Check(
                title: "Precise location is on",
                passing: model.location.accuracyAuthorization == .fullAccuracy,
                fix: model.location.accuracyAuthorization == .fullAccuracy ? nil
                    : "Reduced accuracy is far too coarse to place you in a zone. "
                        + "Turn Precise Location on."
            ),
            Check(
                title: "Watching the road",
                passing: model.settings.isWatching,
                fix: model.settings.isWatching ? nil
                    : "Press Start on the main screen, or turn on "
                        + "Start when I start driving."
            ),
            Check(
                title: "Position updates are arriving",
                passing: model.location.fixCount > 0,
                fix: model.location.fixCount > 0 ? nil
                    : "No fixes have arrived. If this stays at zero while watching, the "
                        + "problem is location access rather than the alerts."
            ),
            Check(
                title: "Spoken alerts are on",
                passing: model.settings.voiceEnabled,
                fix: model.settings.voiceEnabled ? nil : "Settings > Voice > Spoken alerts."
            ),
            Check(
                title: "Zone announcements are on",
                passing: model.settings.announceZones,
                fix: model.settings.announceZones ? nil : "Settings > Camera alerts > Average speed zones."
            ),
            Check(
                title: "Silent switch will not mute it",
                passing: !model.settings.respectSilentSwitch,
                fix: model.settings.respectSilentSwitch
                    ? "You asked the silent switch to mute Zonexplo. With the phone on "
                        + "silent it will stay quiet."
                    : nil
            ),
            Check(
                title: "A usable voice is installed",
                passing: !model.voice.availableVoices.isEmpty,
                fix: model.voice.availableVoices.isEmpty
                    ? "No usable voice for \(VoiceCatalogue.spokenLanguage). iOS Settings > "
                        + "Accessibility > Spoken Content > Voices."
                    : nil
            ),
            Check(
                title: "A country is downloaded",
                passing: !installed.isEmpty,
                fix: installed.isEmpty
                    ? "Settings > Countries, then Get on the country you are in."
                    : nil
            ),
            Check(
                title: "A downloaded country has zones",
                passing: !zoneCountries.isEmpty,
                fix: zoneCountries.isEmpty
                    ? "You have camera data but no average-speed zones, so there is nothing "
                        + "to coach through. Only some countries have zones mapped."
                    : nil
            )
        ]
    }

    private func row(_ check: Check) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: check.passing ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(check.passing ? .green : .orange)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(check.title).font(.subheadline)
                if let fix = check.fix {
                    Text(fix).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            check.passing
                ? "\(check.title). Passing."
                : "\(check.title). Needs attention. \(check.fix ?? "")"
        )
    }

    // MARK: - Report

    private var speedText: String {
        guard let speed = monitor?.currentSpeedKph else { return "—" }
        return "\(Int(speed.rounded())) km/h"
    }

    private var snapshot: [String: String] {
        let installed = model.sync?.countries.filter(\.isInstalled) ?? []
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"

        return [
            "App": "\(version) (\(build))",
            "iOS": ProcessInfo.processInfo.operatingSystemVersionString,
            "Location authorisation": String(describing: model.location.authorizationStatus),
            "Accuracy": model.location.accuracyAuthorization == .fullAccuracy ? "full" : "REDUCED",
            "Tracking mode": String(describing: model.location.mode),
            "Position updates": "\(model.location.fixCount)",
            "Watching": model.settings.isWatching ? "yes" : "no",
            "Spoken alerts": model.settings.voiceEnabled ? "on" : "OFF",
            "Zone announcements": model.settings.announceZones ? "on" : "OFF",
            "Camera announcements": model.settings.announcePointCameras ? "on" : "OFF",
            "Speed limit alerts": model.settings.announceSpeedLimit ? "on" : "OFF",
            "Silent switch mutes": model.settings.respectSilentSwitch ? "YES" : "no",
            "Speech rate": String(format: "%.2f", model.settings.speechRate),
            "Chosen voice": model.settings.voiceIdentifier ?? "automatic",
            "Voices available": "\(model.voice.availableVoices.count) for \(VoiceCatalogue.spokenLanguage)",
            "Countries installed": installed.isEmpty
                ? "NONE"
                : installed.map { "\($0.code)(\($0.cameraCount)c/\($0.zoneCount)z)" }.joined(separator: " "),
            "Cameras nearby": "\(monitor?.nearbyCameras.count ?? 0)",
            "Zones nearby": "\(monitor?.nearbyZones.count ?? 0)",
            "In a zone": monitor?.activeZone?.name ?? "no"
        ]
    }
}
