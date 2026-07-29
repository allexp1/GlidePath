import CoreLocation
import Foundation
import GlidePathCore
import Observation

/// Where the app gets its camera data. Implemented by the local database, so
/// the monitor works identically offline.
protocol CameraDataStore: Sendable {
    func zones(near coordinate: Coordinate, radiusMeters: Double, limit: Int) async throws -> [Zone]
    func cameras(near coordinate: Coordinate, radiusMeters: Double, limit: Int) async throws -> [Camera]
    func zone(id: String) async throws -> Zone?
}

/// What the driver actually hears. Implemented by the audio layer.
@MainActor
protocol CoachVoice: AnyObject {
    func speak(_ line: String, urgent: Bool)
    func stop()
}

/// The thing that runs while you drive.
///
/// It owns the loop: watch geofences cheaply, wake into precise tracking when a
/// zone is near, hand fixes to the engine, say what the engine decides, and drop
/// back to cheap watching when the zone is done. Every decision about *what* to
/// say lives in GlidePathCore; this is the plumbing that makes it happen at the
/// right moment with the right power budget.
@MainActor
@Observable
final class DriveMonitor {
    // MARK: - Observable state

    private(set) var currentAdvice: CoachingAdvice?
    private(set) var activeZone: Zone?
    private(set) var lastOutcome: ZoneOutcome?
    private(set) var nearbyCameras: [Camera] = []
    private(set) var nearbyZones: [Zone] = []
    private(set) var isMonitoring = false

    /// True while precise tracking is on, which the UI surfaces so the battery
    /// cost is never a surprise.
    var isInZone: Bool { session != nil }

    // MARK: - Collaborators

    private let location: LocationService
    private let store: CameraDataStore
    private let voice: CoachVoice
    private var phrasebook: Phrasebook

    private var geofences = GeofenceManager()
    private var session: ZoneSession?
    private var announcer = CoachingAnnouncer()
    private var approachMonitor = CameraApproachMonitor()
    private var refreshTask: Task<Void, Never>?

    /// Zones whose entry geofence has fired and which we are watching for a
    /// real crossing. Keyed by zone id.
    private var armedZoneIDs: Set<String> = []

    var settings: Settings {
        didSet { phrasebook = Phrasebook(units: settings.units) }
    }

    struct Settings: Equatable {
        var units: DistanceUnits = .metric
        var voiceEnabled = true
        var announceZones = true
        var announcePointCameras = true
        var announceMobileHotspots = true
        var announceRedLightCameras = true

        static let `default` = Settings()
    }

    init(
        location: LocationService,
        store: CameraDataStore,
        voice: CoachVoice,
        settings: Settings = .default
    ) {
        self.location = location
        self.store = store
        self.voice = voice
        self.settings = settings
        self.phrasebook = Phrasebook(units: settings.units)

        location.onFix = { [weak self] fix in
            self?.handle(fix: fix)
        }
        location.onRegionEntered = { [weak self] identifier in
            self?.handleRegionEntered(identifier)
        }
        location.onRegionExited = { [weak self] identifier in
            self?.handleRegionExited(identifier)
        }
    }

    // MARK: - Lifecycle

    func start() {
        guard !isMonitoring else { return }
        isMonitoring = true
        location.startStandbyTracking()

        // A relaunch can happen anywhere, including in the middle of a zone.
        // Region monitoring only reports crossings, so without this an app
        // relaunched inside a geofence would never know it was there.
        location.requestStateForAllRegions()
    }

    func stop() {
        isMonitoring = false
        refreshTask?.cancel()
        endSession(reason: .cancelled, speak: false)
        location.stopAll()
        voice.stop()
    }

    // MARK: - Fixes

    private func handle(fix: LocationFix) {
        if session != nil {
            advanceSession(with: fix)
        } else {
            checkForEntry(fix: fix)
            announceApproachingCameras(fix: fix)
        }

        if geofences.needsRefresh(at: fix.coordinate) {
            refreshGeofences(around: fix.coordinate)
        }
    }

    /// Feeds the engine and says whatever it decides.
    private func advanceSession(with fix: LocationFix) {
        guard var current = session else { return }

        let events = current.ingest(fix)
        session = current

        for event in events {
            switch event {
            case .entered:
                if settings.announceZones, let zone = activeZone {
                    speak(phrasebook.zoneEntry(zone), urgent: true)
                }

            case let .advice(advice):
                currentAdvice = advice
                guard announcer.shouldAnnounce(advice, at: fix.timestamp) else { continue }
                if let line = phrasebook.coaching(advice) {
                    speak(line, urgent: advice.tier != .normal)
                }

            case let .completed(outcome):
                lastOutcome = outcome
                if settings.announceZones {
                    speak(phrasebook.zoneExit(outcome), urgent: false)
                }
                finishSession()

            case let .abandoned(reason):
                if let line = phrasebook.zoneAbandoned(reason) {
                    speak(line, urgent: false)
                }
                finishSession()
            }
        }
    }

    /// Outside a zone, the geofence is the trigger, but a driver can also
    /// simply arrive: the app may have been launched mid-journey, or the region
    /// may have failed to fire. Arming on proximity as well costs nothing.
    private func checkForEntry(fix: LocationFix) {
        guard session == nil else { return }

        let candidate = nearbyZones
            .filter { armedZoneIDs.contains($0.id) || fix.coordinate.distance(to: $0.entry) < 1_500 }
            .min { lhs, rhs in
                fix.coordinate.distance(to: lhs.entry) < fix.coordinate.distance(to: rhs.entry)
            }

        guard let zone = candidate else { return }
        guard fix.coordinate.distance(to: zone.entry) < 1_500 else { return }
        beginSession(for: zone, firstFix: fix)
    }

    private func announceApproachingCameras(fix: LocationFix) {
        guard settings.announcePointCameras else { return }

        let approaches = approachMonitor.update(fix: fix, cameras: nearbyCameras)
        for approach in approaches {
            guard shouldAnnounce(approach.camera) else { continue }
            guard let line = phrasebook.cameraApproach(approach) else { continue }
            speak(line, urgent: approach.urgency == .imminent)
        }
    }

    private func shouldAnnounce(_ camera: Camera) -> Bool {
        switch camera.type {
        case .mobileHotspot: return settings.announceMobileHotspots
        case .redLight: return settings.announceRedLightCameras
        default: return true
        }
    }

    // MARK: - Sessions

    private func beginSession(for zone: Zone, firstFix: LocationFix) {
        guard var newSession = ZoneSession(zone: zone) else {
            // Undriveable geometry. Nothing to do but leave it alone; the data
            // is wrong and pretending otherwise would coach from a bad distance.
            return
        }

        activeZone = zone
        announcer.reset()
        location.startPreciseTracking()

        newSession.ingest(firstFix)
        session = newSession
    }

    private func finishSession() {
        session = nil
        activeZone = nil
        currentAdvice = nil
        announcer.reset()
        armedZoneIDs.removeAll()
        location.stopPreciseTracking()
    }

    private func endSession(reason: AbandonReason, speak shouldSpeak: Bool) {
        guard var current = session else { return }
        let event = current.abandon(reason)
        session = current

        if shouldSpeak, case .abandoned(let abandoned)? = event,
           let line = phrasebook.zoneAbandoned(abandoned) {
            self.speak(line, urgent: false)
        }
        finishSession()
    }

    // MARK: - Geofences

    private func handleRegionEntered(_ identifier: String) {
        guard let target = GeofenceManager.Target.from(identifier: identifier) else { return }

        switch target {
        case let .zoneEntry(zoneID):
            armedZoneIDs.insert(zoneID)
            // Wake the receiver now, well before the entry line, so it has
            // locked and settled by the time the crossing actually happens.
            // The crossing itself is timestamped from the fix stream.
            location.startPreciseTracking()
            Task { await loadZoneIfNeeded(zoneID) }

        case .camera:
            // Point cameras do not need precise tracking; the standby stream is
            // enough to time a warning.
            break
        }
    }

    private func handleRegionExited(_ identifier: String) {
        guard let target = GeofenceManager.Target.from(identifier: identifier) else { return }

        if case let .zoneEntry(zoneID) = target {
            armedZoneIDs.remove(zoneID)
            // Left the approach without ever entering: stop burning battery.
            if session == nil, armedZoneIDs.isEmpty {
                location.stopPreciseTracking()
            }
        }
    }

    private func loadZoneIfNeeded(_ zoneID: String) async {
        guard !nearbyZones.contains(where: { $0.id == zoneID }) else { return }
        guard let zone = try? await store.zone(id: zoneID) else { return }
        nearbyZones.append(zone)
    }

    /// Rebuilds the twenty-region window around the driver.
    private func refreshGeofences(around coordinate: Coordinate) {
        refreshTask?.cancel()
        geofences.noteRefreshStarted(at: coordinate)
        refreshTask = Task { [weak self] in
            guard let self else { return }

            let zones = (try? await store.zones(near: coordinate, radiusMeters: 60_000, limit: 40)) ?? []
            let cameras = (try? await store.cameras(near: coordinate, radiusMeters: 40_000, limit: 200)) ?? []

            guard !Task.isCancelled else { return }

            self.nearbyZones = zones
            self.nearbyCameras = cameras

            let regions = self.geofences.regions(around: coordinate, zones: zones, cameras: cameras)
            self.location.replaceMonitoredRegions(with: regions)
        }
    }

    private func speak(_ line: String, urgent: Bool) {
        guard settings.voiceEnabled else { return }
        voice.speak(line, urgent: urgent)
    }
}
