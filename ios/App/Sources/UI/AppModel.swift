import Foundation
import ZonexploCore
import Observation
import SwiftUI

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
        if !wasWatching { Analytics.capture(.watchStarted) }
    }

    func stopMonitoring() {
        let wasWatching = settings.isWatching
        settings.isWatching = false
        monitor?.stop()
        if wasWatching { Analytics.capture(.watchStopped) }
    }

    /// Starting and stopping the SDK from the toggle, so "off" means the
    /// library is shut down rather than merely unused.
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

    private func applySettings() {
        applyAnalyticsSetting()
        voice.settings = settings.voiceSettings
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
        defaults.set(hasSeenOnboarding, forKey: Keys.hasSeenOnboarding)
        defaults.set(isWatching, forKey: Keys.isWatching)
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

    var voiceSettings: VoiceCoach.Settings {
        var settings = VoiceCoach.Settings.default
        settings.enabled = voiceEnabled
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
        static let hasSeenOnboarding = "settings.hasSeenOnboarding"
        static let isWatching = "settings.isWatching"
    }
}
