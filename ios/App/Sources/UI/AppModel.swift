import Foundation
import ZonexploCore
import Observation
import SwiftUI
import UIKit

/// The composition root.
///
/// Everything is wired here so that no view ever constructs a service and no
/// service ever knows about a view. It also means the failure modes on first
/// launch have exactly one place to live, which matters because "nothing
/// happens and there is no error" is the worst possible first run for an app
/// that is meant to be watching the road for you.
@MainActor
@Observable
final class AppModel {
    enum StartupState: Equatable {
        case loading
        case needsConfiguration(String)
        case failed(String)
        case ready
    }

    private(set) var startup: StartupState = .loading

    private(set) var location = LocationService()
    private(set) var voice = VoiceCoach()

    private(set) var database: LocalDatabase?
    private(set) var sync: CountrySyncService?
    private(set) var monitor: DriveMonitor?
    private(set) var store: LocalCameraStore?

    let driving = DrivingDetector()

    /// Silence for this run of the app only.
    ///
    /// Deliberately not in AppSettings and deliberately not persisted. The
    /// Settings toggle is a decision about how the app behaves; this is a
    /// decision about the next twenty minutes - a passenger asleep, a phone
    /// call, a stretch of road you already know. Carrying it across a relaunch
    /// would turn a temporary hush into a permanently silent safety app whose
    /// owner has forgotten why, which is the one failure mode a mute button
    /// must not have.
    var isMutedForSession = false {
        didSet {
            guard isMutedForSession != oldValue else { return }
            voice.settings = settings.voiceSettings(mutedForSession: isMutedForSession)
            Diagnostics.shared.record(
                .voice,
                isMutedForSession
                    ? "muted for this session - restored when the app is next opened"
                    : "unmuted"
            )
        }
    }

    /// A value type, so `didSet` fires when a view toggles any single setting.
    /// A reference type here would only notify on replacement, and every
    /// settings toggle would silently fail to reach the voice and the monitor.
    var settings = AppSettings(defaults: .standard) {
        didSet {
            guard settings != oldValue else { return }
            settings.persist(to: .standard)
            applySettings()
        }
    }

    func bootstrap() async {
        guard case .loading = startup else { return }

        if let problem = AppConfig.configurationProblem {
            startup = .needsConfiguration(problem)
            return
        }

        do {
            let database = try LocalDatabase(url: try LocalDatabase.defaultURL())
            let store = LocalCameraStore(database: database)
            let client = try SupabaseREST.fromAppConfig()
            let sync = CountrySyncService(database: database, client: client)
            let monitor = DriveMonitor(
                location: location,
                store: store,
                voice: voice,
                settings: settings.driveSettings
            )

            self.database = database
            self.store = store
            self.sync = sync
            self.monitor = monitor

            applySettings()
            startup = .ready

            // Resume watching if that is what this phone was doing when it was
            // last alive.
            //
            // Not a nicety. A monitored region relaunches a terminated app into
            // the background, which is the whole reason the geofences exist -
            // and without this the relaunched app comes up idle, ignores the
            // crossing it was woken for, and stays silent for the rest of the
            // drive. Nobody presses start again, because nobody knows it
            // stopped.
            if settings.isWatching {
                monitor.start()
            }

            // A failed catalogue refresh is not a failed launch. Whatever was
            // downloaded before still works, which is the entire point.
            await sync.syncInstalledCountries()
        } catch {
            startup = .failed(error.localizedDescription)
        }
    }

    func startMonitoring() {
        let wasWatching = settings.isWatching
        settings.isWatching = true
        monitor?.start()
        // Only the transition. scenePhase re-asserts this on every activation,
        // and counting that would report a number that means "app opened".
        if !wasWatching {
            Analytics.capture(.watchStarted)
            Diagnostics.shared.record(.app, "started watching the road")
        }
    }

    func stopMonitoring() {
        let wasWatching = settings.isWatching
        settings.isWatching = false
        monitor?.stop()
        if wasWatching {
            Analytics.capture(.watchStopped)
            Diagnostics.shared.record(.app, "stopped watching the road")
        }
    }

    /// Starting and stopping the SDK from the toggle, so "off" means the
    /// library is shut down rather than merely unused.
    /// Files an anonymous report about one camera.
    ///
    /// The only write this app makes, and the only request that carries a
    /// coordinate - the camera's own, which is already public data the phone
    /// downloaded. Not the driver's position, and only on an explicit tap.
    func reportCamera(_ camera: ZonexploCore.Camera, kind: CameraDetailSheet.ReportKind) async -> Bool {
        guard let client = sync?.client else { return false }
        do {
            try await client.insert([
                "country_code": camera.countryCode,
                "kind": kind.rawValue,
                "camera_id": camera.id,
                "location": "SRID=4326;POINT(\(camera.coordinate.longitude) \(camera.coordinate.latitude))"
            ], into: "pending_reports")
            return true
        } catch {
            return false
        }
    }

    /// The posted limit where a camera stands, when the downloaded road data
    /// can establish one beyond doubt.
    ///
    /// Most cameras carry no limit of their own - under five per cent do in
    /// California - so without this the detail sheet is silent about the one
    /// number anyone taps a speed camera to find out. The refusing is done in
    /// `RoadLimitLookup`; this only fetches the roads to ask about.
    func postedLimit(at camera: ZonexploCore.Camera) async -> RoadLimitLookup.Result? {
        guard let store else { return nil }

        // Wider than the corridor the lookup applies, because a road is stored
        // as a whole way: the nearest recorded point of a long road can sit far
        // from where it passes the camera.
        let candidates = (try? await store.roadLimits(
            near: camera.coordinate,
            radiusMeters: 250
        )) ?? []

        return RoadLimitLookup.limit(
            at: camera.coordinate,
            facing: camera.directionDegrees,
            candidates: candidates
        )
    }

    private func applyAnalyticsSetting() {
        if settings.analyticsEnabled {
            Analytics.start(enabled: true)
        } else {
            // Captured before the shutdown, or it never leaves the device -
            // which is the one number that tells us how unwelcome this is.
            Analytics.capture(.analyticsOptOut)
            Analytics.stop()
        }
    }

    /// Motion monitoring follows the setting, and is never left running for a
    /// feature that has been turned off.
    private func applyDrivingDetection() {
        guard settings.autoStartWhenDriving, settings.hasSeenOnboarding else {
            driving.stop()
            return
        }
        driving.onDrivingStarted = { [weak self] in
            guard let self, !self.settings.isWatching else { return }
            self.startMonitoring()
        }
        driving.start()
    }

    /// The screen sleeps after thirty seconds, and every visual warning this
    /// app draws is worthless once it does. Cleared the moment watching stops,
    /// so a phone left on a desk is not held awake by an app nobody is using.
    private func applyIdleTimer() {
        UIApplication.shared.isIdleTimerDisabled = settings.keepScreenAwake && settings.isWatching
    }

    private func applySettings() {
        applyAnalyticsSetting()
        applyDrivingDetection()
        applyIdleTimer()
        voice.settings = settings.voiceSettings(mutedForSession: isMutedForSession)
        monitor?.settings = settings.driveSettings
    }
}

/// User settings, persisted to UserDefaults.
///
/// UserDefaults rather than the database: these are a dozen booleans that must
/// be readable the instant the app launches, including on a background wake-up
/// where opening SQLite first would be wasted work.
struct AppSettings: Equatable {
    var units: DistanceUnits
    var voiceEnabled: Bool
    var announceZones: Bool
    var announcePointCameras: Bool
    var announceMobileHotspots: Bool
    var announceRedLightCameras: Bool
    var announceSpeedLimit: Bool
    var showSpeedLimit: Bool
    var respectSilentSwitch: Bool

    /// The chosen `AVSpeechSynthesisVoice` identifier, or nil for "let
    /// Zonexplo pick the best installed one", which is the default.
    var voiceIdentifier: String?

    /// How fast the voice speaks, as a fraction of the system default.
    /// Exposed because "a bit quicker" and "a bit slower" are the two most
    /// common things anyone wants from a spoken alert, and neither is worth
    /// a support conversation.
    var speechRate: Double

    /// Anonymous usage analytics. Opt-out rather than opt-in, disclosed in
    /// onboarding, and gating the SDK itself rather than the call sites.
    var analyticsEnabled: Bool

    /// Start watching by itself once Core Motion is confident the phone is in a
    /// moving car. The commonest real-world failure is forgetting to press
    /// start, and a safety aid that needs remembering is one that will be
    /// forgotten on the drive it was needed.
    var autoStartWhenDriving: Bool

    /// Hold the screen on while watching the road.
    ///
    /// iOS locks the phone after about thirty seconds, which is shorter than
    /// any drive, so without this the sign, the camera banner and the zone bar
    /// are visible for the first half-minute and then never again. On by
    /// default because it costs nothing when it is not needed: iOS ignores the
    /// flag entirely unless Zonexplo is the app on screen, and most of the time
    /// it is not - the whole design is for it to sit behind a navigator.
    var keepScreenAwake: Bool

    /// Countries whose legal notice the driver has read and accepted. Stored so
    /// the warning appears once rather than nagging.
    var acceptedLegalCodes: [String]

    var hasSeenOnboarding: Bool

    /// Whether the driver had the app watching the road when it was last
    /// alive. Restored on launch, so a background relaunch from a geofence
    /// comes back watching rather than idle.
    var isWatching: Bool

    init(defaults: UserDefaults) {
        units = DistanceUnits(rawValue: defaults.string(forKey: Keys.units) ?? "") ?? .metric
        voiceEnabled = defaults.object(forKey: Keys.voiceEnabled) as? Bool ?? true
        announceZones = defaults.object(forKey: Keys.announceZones) as? Bool ?? true
        announcePointCameras = defaults.object(forKey: Keys.announcePointCameras) as? Bool ?? true
        announceMobileHotspots = defaults.object(forKey: Keys.announceMobileHotspots) as? Bool ?? true
        announceRedLightCameras = defaults.object(forKey: Keys.announceRedLightCameras) as? Bool ?? true
        announceSpeedLimit = defaults.object(forKey: Keys.announceSpeedLimit) as? Bool ?? true
        showSpeedLimit = defaults.object(forKey: Keys.showSpeedLimit) as? Bool ?? true
        respectSilentSwitch = defaults.object(forKey: Keys.respectSilentSwitch) as? Bool ?? false
        voiceIdentifier = defaults.string(forKey: Keys.voiceIdentifier)
        speechRate = defaults.object(forKey: Keys.speechRate) as? Double ?? 1.05
        analyticsEnabled = defaults.object(forKey: Keys.analyticsEnabled) as? Bool ?? true
        autoStartWhenDriving = defaults.object(forKey: Keys.autoStartWhenDriving) as? Bool ?? true
        keepScreenAwake = defaults.object(forKey: Keys.keepScreenAwake) as? Bool ?? true
        acceptedLegalCodes = defaults.stringArray(forKey: Keys.acceptedLegalCodes) ?? []
        hasSeenOnboarding = defaults.bool(forKey: Keys.hasSeenOnboarding)
        isWatching = defaults.bool(forKey: Keys.isWatching)
    }

    func persist(to defaults: UserDefaults) {
        defaults.set(units.rawValue, forKey: Keys.units)
        defaults.set(voiceEnabled, forKey: Keys.voiceEnabled)
        defaults.set(announceZones, forKey: Keys.announceZones)
        defaults.set(announcePointCameras, forKey: Keys.announcePointCameras)
        defaults.set(announceMobileHotspots, forKey: Keys.announceMobileHotspots)
        defaults.set(announceRedLightCameras, forKey: Keys.announceRedLightCameras)
        defaults.set(announceSpeedLimit, forKey: Keys.announceSpeedLimit)
        defaults.set(showSpeedLimit, forKey: Keys.showSpeedLimit)
        defaults.set(respectSilentSwitch, forKey: Keys.respectSilentSwitch)
        // set(nil:) removes the key, which is exactly what "automatic" means.
        defaults.set(voiceIdentifier, forKey: Keys.voiceIdentifier)
        defaults.set(speechRate, forKey: Keys.speechRate)
        defaults.set(analyticsEnabled, forKey: Keys.analyticsEnabled)
        defaults.set(autoStartWhenDriving, forKey: Keys.autoStartWhenDriving)
        defaults.set(keepScreenAwake, forKey: Keys.keepScreenAwake)
        defaults.set(acceptedLegalCodes, forKey: Keys.acceptedLegalCodes)
        defaults.set(hasSeenOnboarding, forKey: Keys.hasSeenOnboarding)
        defaults.set(isWatching, forKey: Keys.isWatching)
    }

    func hasAcceptedLegal(_ code: String) -> Bool { acceptedLegalCodes.contains(code) }

    mutating func acceptLegal(_ code: String) {
        guard !acceptedLegalCodes.contains(code) else { return }
        acceptedLegalCodes.append(code)
    }

    var driveSettings: DriveMonitor.Settings {
        DriveMonitor.Settings(
            units: units,
            voiceEnabled: voiceEnabled,
            announceZones: announceZones,
            announcePointCameras: announcePointCameras,
            announceMobileHotspots: announceMobileHotspots,
            announceRedLightCameras: announceRedLightCameras,
            announceSpeedLimit: announceSpeedLimit,
            showSpeedLimit: showSpeedLimit
        )
    }

    func voiceSettings(mutedForSession: Bool = false) -> VoiceCoach.Settings {
        var settings = VoiceCoach.Settings.default
        settings.enabled = voiceEnabled && !mutedForSession
        settings.respectSilentSwitch = respectSilentSwitch
        settings.voiceIdentifier = voiceIdentifier
        settings.rateScale = speechRate
        return settings
    }

    private enum Keys {
        static let units = "settings.units"
        static let voiceEnabled = "settings.voiceEnabled"
        static let announceZones = "settings.announceZones"
        static let announcePointCameras = "settings.announcePointCameras"
        static let announceMobileHotspots = "settings.announceMobileHotspots"
        static let announceRedLightCameras = "settings.announceRedLightCameras"
        static let announceSpeedLimit = "settings.announceSpeedLimit"
        static let showSpeedLimit = "settings.showSpeedLimit"
        static let respectSilentSwitch = "settings.respectSilentSwitch"
        static let voiceIdentifier = "settings.voiceIdentifier"
        static let speechRate = "settings.speechRate"
        static let analyticsEnabled = "settings.analyticsEnabled"
        static let autoStartWhenDriving = "settings.autoStartWhenDriving"
        static let keepScreenAwake = "settings.keepScreenAwake"
        static let acceptedLegalCodes = "settings.acceptedLegalCodes"
        static let hasSeenOnboarding = "settings.hasSeenOnboarding"
        static let isWatching = "settings.isWatching"
    }
}
