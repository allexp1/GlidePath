import CoreLocation
import Foundation
import ZonexploCore
import Observation

/// Where the app gets its camera data. Implemented by the local database, so
/// the monitor works identically offline.
protocol CameraDataStore: Sendable {
    func zones(near coordinate: Coordinate, radiusMeters: Double, limit: Int) async throws -> [Zone]
    func cameras(near coordinate: Coordinate, radiusMeters: Double, limit: Int) async throws -> [Camera]
    func zone(id: String) async throws -> Zone?
    func roadLimits(near coordinate: Coordinate, radiusMeters: Double) async throws -> [RoadLimit]
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
/// say lives in ZonexploCore; this is the plumbing that makes it happen at the
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

    /// The road the driver is currently held to be on, and its posted limit.
    /// Nil is normal and common: no limit data downloaded, or a road nobody has
    /// tagged.
    ///
    /// `internal(set)` rather than `private(set)` only because the code that
    /// writes it lives in `DriveMonitor+Limits`. Nothing outside this type
    /// should be assigning it.
    internal(set) var currentRoadLimit: RoadLimitMatcher.Match?

    /// The smoothed speed the limit roundel shows. Smoothed rather than raw
    /// because a number flickering by three every second is unreadable at a
    /// glance, which is the only way it is ever read.
    private(set) var currentSpeedKph: Double?

    /// The camera being approached, for the on-screen warning.
    ///
    /// Cleared once passed rather than left to fade: a banner still showing a
    /// camera the driver went by two minutes ago is worse than no banner,
    /// because it teaches them the screen is stale.
    internal(set) var currentApproach: CameraApproach?

    /// True while precise tracking is on, which the UI surfaces so the battery
    /// cost is never a surprise.
    var isInZone: Bool { session != nil }

    /// Why there is no speed limit roundel on screen.
    ///
    /// An absent sign is indistinguishable from a broken app, and the two
    /// reasons it can be absent need opposite responses: a road nobody tagged
    /// is nothing to act on, whereas an area with no limits downloaded is a
    /// thirty-second fix in Settings that nobody will ever guess at. Both look
    /// identical from the driver's seat, which is how a partial download stays
    /// invisible for a whole trip.
    enum LimitStatus: Equatable {
        /// A limit is on screen, or the driver turned the feature off, or the
        /// app is not watching. Nothing to explain either way.
        case notApplicable
        /// The window around the driver has not come back from the database yet.
        case waiting
        /// The window came back empty. Almost always a country, or part of one,
        /// that was never downloaded.
        case noneNearby
        /// Limits are loaded here, but this particular road has none.
        case notPosted
    }

    var limitStatus: LimitStatus {
        guard isMonitoring, settings.showSpeedLimit, currentRoadLimit == nil else {
            return .notApplicable
        }
        guard hasLoadedLimitWindow else { return .waiting }
        return nearbyRoadLimits.isEmpty ? .noneNearby : .notPosted
    }

    // MARK: - Collaborators

    private let location: LocationService
    let store: CameraDataStore
    private let voice: CoachVoice
    var phrasebook: Phrasebook

    private var geofences = GeofenceManager()
    private var session: ZoneSession?
    private var announcer = CoachingAnnouncer()
    var approachMonitor = CameraApproachMonitor()
    private var refreshTask: Task<Void, Never>?

    var limitMatcher = RoadLimitMatcher()
    var limitMonitor = SpeedLimitMonitor()
    private var speedSmoother = SpeedSmoother()

    /// Speed limits for the roads around the driver, reloaded as they move.
    var nearbyRoadLimits: [RoadLimit] = []
    var limitRefreshTask: Task<Void, Never>?
    var lastLimitRefreshCentre: Coordinate?

    /// Whether a limit window has ever come back. Without it, "nothing loaded
    /// yet" and "nothing here to load" are the same empty array, and the UI
    /// would tell a driver to go and download something a hundred milliseconds
    /// before the data arrived.
    var hasLoadedLimitWindow = false

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

        /// Speak when the driver has been over the posted limit for a few
        /// seconds. Separate from `showSpeedLimit`, because wanting the number
        /// on screen and wanting to be told about it are different wants.
        var announceSpeedLimit = true

        /// Track the limit at all. Off means the matcher never runs, which also
        /// removes the roundel and the per-fix lookup.
        var showSpeedLimit = true

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

        // Drive mode, not standby. Warnings are computed per fix against a
        // window at most 900 m wide, and significant-location changes do not
        // arrive anywhere near often enough to land inside one. Standby is for
        // when the app is not watching.
        location.startDriveTracking()

        // Seed the camera set and the region window from wherever the phone
        // already believes it is, so the first stretch of a drive is covered
        // before the first fresh fix arrives.
        if let fix = location.latestFix {
            refreshGeofences(around: fix.coordinate)
        }

        // A relaunch can happen anywhere, including in the middle of a zone.
        // Region monitoring only reports crossings, so without this an app
        // relaunched inside a geofence would never know it was there.
        location.requestStateForAllRegions()
    }

    func stop() {
        isMonitoring = false
        refreshTask?.cancel()
        limitRefreshTask?.cancel()
        endSession(reason: .cancelled, speak: false)
        location.stopAll()
        voice.stop()

        limitMatcher.reset()
        limitMonitor.reset()
        speedSmoother.reset()
        currentRoadLimit = nil
        currentSpeedKph = nil
        lastLimitRefreshCentre = nil
        nearbyRoadLimits = []
        hasLoadedLimitWindow = false
    }

    // MARK: - Fixes

    private func handle(fix: LocationFix) {
        if let speedKph = fix.speedKph {
            speedSmoother.add(speedKph: speedKph, at: fix.timestamp)
            currentSpeedKph = speedSmoother.smoothedKph
        }

        if session != nil {
            advanceSession(with: fix)
        } else {
            checkForEntry(fix: fix)
            announceApproachingCameras(fix: fix)
            // Only outside a zone. Inside one the receiver is already giving
            // everything it has and must not be turned down.
            location.setDriveResolution(nearestFeatureMeters: distanceToNearestFeature(from: fix))
        }

        updateRoadLimit(fix: fix)

        if geofences.needsRefresh(at: fix.coordinate) {
            refreshGeofences(around: fix.coordinate)
        }
    }

    /// Distance to the nearest thing the app would speak about, which is what
    /// decides how hard the receiver is worked. Nil when there is nothing
    /// loaded nearby at all.
    private func distanceToNearestFeature(from fix: LocationFix) -> Double? {
        let cameraDistance = nearbyCameras
            .lazy
            .filter { !$0.type.isZoneMarker }
            .map { fix.coordinate.distance(to: $0.coordinate) }
            .min()

        let zoneDistance = nearbyZones
            .lazy
            .map { fix.coordinate.distance(to: $0.entry) }
            .min()

        return [cameraDistance, zoneDistance].compactMap { $0 }.min()
    }

    /// Feeds the engine and says whatever it decides.
    private func advanceSession(with fix: LocationFix) {
        guard var current = session else { return }

        let events = current.ingest(fix)
        session = current

        for event in events {
            switch event {
            case .entered:
                Diagnostics.shared.record(
                    .zone,
                    "entered \(activeZone?.name ?? "an unnamed zone"), "
                        + "announcements \(settings.announceZones ? "on" : "OFF")"
                )
                if settings.announceZones, let zone = activeZone {
                    speak(phrasebook.zoneEntry(zone), urgent: true)
                }

            case let .advice(advice):
                currentAdvice = advice
                guard announcer.shouldAnnounce(advice, at: fix.timestamp) else {
                    Diagnostics.shared.record(
                        .zone,
                        "advice computed (\(advice.tier)) but held back - too soon after the last line"
                    )
                    continue
                }
                if let line = phrasebook.coaching(advice) {
                    speak(line, urgent: advice.tier != .normal)
                }

            case let .completed(outcome):
                lastOutcome = outcome
                Diagnostics.shared.record(
                    .zone,
                    "completed: averaged \(Int(outcome.averageKph.rounded())) in a "
                        + "\(Int(outcome.limitKph.rounded())), \(outcome.passed ? "passed" : "over")"
                )
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

    /// Which of the four "what to announce" switches governs this camera.
    ///
    /// Every type maps to exactly one switch. The previous version gated the
    /// whole approach path on `announcePointCameras` before consulting this,
    /// which made the red light and mobile switches unreachable: turning speed
    /// cameras off turned everything off.
    func shouldAnnounce(_ camera: Camera) -> Bool {
        switch camera.type {
        case .mobileHotspot:
            return settings.announceMobileHotspots
        case .redLight:
            return settings.announceRedLightCameras
        case .fixed, .combined, .seatbeltPhone, .busLane:
            return settings.announcePointCameras
        case .zoneEntry, .zoneExit:
            // Zone markers are the section's own cameras. The zone switch owns
            // them, and the approach monitor skips them anyway.
            return settings.announceZones
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

        case let .camera(cameraID):
            // The backstop for a warning the fix stream did not manage to
            // deliver: a tunnel, a cold start, a receiver that had not settled.
            // Normally the ordinary window has already spoken by 350 m and
            // `announceGeofenceCrossing` returns nil, so this stays silent.
            guard session == nil else { return }
            guard let fix = location.latestFix else { return }
            guard let camera = nearbyCameras.first(where: { $0.id == cameraID }) else { return }

            if let approach = approachMonitor.announceGeofenceCrossing(of: camera, at: fix) {
                announce(approach)
            }
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

    func speak(_ line: String, urgent: Bool) {
        guard settings.voiceEnabled else { return }
        voice.speak(line, urgent: urgent)
    }
}
