import Foundation
import GlidePathCore
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

            // A failed catalogue refresh is not a failed launch. Whatever was
            // downloaded before still works, which is the entire point.
            await sync.syncInstalledCountries()
        } catch {
            startup = .failed(error.localizedDescription)
        }
    }

    func startMonitoring() {
        monitor?.start()
    }

    func stopMonitoring() {
        monitor?.stop()
    }

    private func applySettings() {
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
    var respectSilentSwitch: Bool
    var hasSeenOnboarding: Bool

    init(defaults: UserDefaults) {
        units = DistanceUnits(rawValue: defaults.string(forKey: Keys.units) ?? "") ?? .metric
        voiceEnabled = defaults.object(forKey: Keys.voiceEnabled) as? Bool ?? true
        announceZones = defaults.object(forKey: Keys.announceZones) as? Bool ?? true
        announcePointCameras = defaults.object(forKey: Keys.announcePointCameras) as? Bool ?? true
        announceMobileHotspots = defaults.object(forKey: Keys.announceMobileHotspots) as? Bool ?? true
        announceRedLightCameras = defaults.object(forKey: Keys.announceRedLightCameras) as? Bool ?? true
        respectSilentSwitch = defaults.object(forKey: Keys.respectSilentSwitch) as? Bool ?? false
        hasSeenOnboarding = defaults.bool(forKey: Keys.hasSeenOnboarding)
    }

    func persist(to defaults: UserDefaults) {
        defaults.set(units.rawValue, forKey: Keys.units)
        defaults.set(voiceEnabled, forKey: Keys.voiceEnabled)
        defaults.set(announceZones, forKey: Keys.announceZones)
        defaults.set(announcePointCameras, forKey: Keys.announcePointCameras)
        defaults.set(announceMobileHotspots, forKey: Keys.announceMobileHotspots)
        defaults.set(announceRedLightCameras, forKey: Keys.announceRedLightCameras)
        defaults.set(respectSilentSwitch, forKey: Keys.respectSilentSwitch)
        defaults.set(hasSeenOnboarding, forKey: Keys.hasSeenOnboarding)
    }

    var driveSettings: DriveMonitor.Settings {
        DriveMonitor.Settings(
            units: units,
            voiceEnabled: voiceEnabled,
            announceZones: announceZones,
            announcePointCameras: announcePointCameras,
            announceMobileHotspots: announceMobileHotspots,
            announceRedLightCameras: announceRedLightCameras
        )
    }

    var voiceSettings: VoiceCoach.Settings {
        var settings = VoiceCoach.Settings.default
        settings.enabled = voiceEnabled
        settings.respectSilentSwitch = respectSilentSwitch
        return settings
    }

    private enum Keys {
        static let units = "settings.units"
        static let voiceEnabled = "settings.voiceEnabled"
        static let announceZones = "settings.announceZones"
        static let announcePointCameras = "settings.announcePointCameras"
        static let announceMobileHotspots = "settings.announceMobileHotspots"
        static let announceRedLightCameras = "settings.announceRedLightCameras"
        static let respectSilentSwitch = "settings.respectSilentSwitch"
        static let hasSeenOnboarding = "settings.hasSeenOnboarding"
    }
}
