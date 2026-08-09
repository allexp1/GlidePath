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
    private(set) var currentRoadLimit: RoadLimitMatcher.Match?

    /// The smoothed speed the limit roundel shows. Smoothed rather than raw
    /// because a number flickering by three every second is unreadable at a
    /// glance, which is the only way it is ever read.
    private(set) var currentSpeedKph: Double?

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

    private var limitMatcher = RoadLimitMatcher()
    private var limitMonitor = SpeedLimitMonitor()
    private var speedSmoother = SpeedSmoother()

    /// Speed limits for the roads around the driver, reloaded as they move.
    private var nearbyRoadLimits: [RoadLimit] = []
    private var limitRefreshTask: Task<Void, Never>?
    private var lastLimitRefreshCentre: Coordinate?

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

    // MARK: - Posted speed limits

    /// How far the driver must move before the limit window is rebuilt.
    ///
    /// Much tighter than the geofence window, and it has to be: the window is
    /// only a few hundred metres wide because matching projects every candidate
    /// on every fix, so it goes stale in seconds at motorway speed.
    private static let limitRefreshThreshold: Double = 500

    /// Radius of the limit window. Wide enough to survive until the next
    /// refresh, narrow enough that a city centre does not load every side
    /// street within a kilometre.
    private static let limitWindowRadius: Double = 1_200

    private func updateRoadLimit(fix: LocationFix) {
        guard settings.showSpeedLimit else {
            currentRoadLimit = nil
            limitMatcher.reset()
            limitMonitor.reset()
            return
        }

        if needsLimitRefresh(at: fix.coordinate) {
            refreshRoadLimits(around: fix.coordinate)
        }

        let match = limitMatcher.update(fix: fix, candidates: nearbyRoadLimits)
        currentRoadLimit = match

        // Inside a zone the coaching engine owns the voice. It is already
        // telling the driver what speed to hold, worked out from the same road
        // and aimed at a camera that is actually there; a second voice saying
        // something adjacent about the same stretch of tarmac is noise at the
        // one moment the driver most needs to hear one clear number.
        guard session == nil else {
            _ = limitMonitor.update(fix: fix, limitKph: nil)
            return
        }

        guard let exceedance = limitMonitor.update(fix: fix, limitKph: match?.limitKph) else {
            return
        }
        guard settings.announceSpeedLimit else { return }

        speak(phrasebook.speedLimitExceeded(exceedance), urgent: false)
    }

    private func needsLimitRefresh(at coordinate: Coordinate) -> Bool {
        guard let centre = lastLimitRefreshCentre else { return true }
        return centre.distance(to: coordinate) > Self.limitRefreshThreshold
    }

    private func refreshRoadLimits(around coordinate: Coordinate) {
        // Claimed before the query starts, for the same reason the geofence
        // refresh does it: at 1 Hz, every fix arriving while a read is in
        // flight would launch another one.
        lastLimitRefreshCentre = coordinate

        limitRefreshTask?.cancel()
        limitRefreshTask = Task { [weak self] in
            guard let self else { return }
            let limits = (try? await store.roadLimits(
                near: coordinate,
                radiusMeters: Self.limitWindowRadius
            )) ?? []

            guard !Task.isCancelled else { return }
            self.nearbyRoadLimits = limits
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
        let approaches = approachMonitor.update(fix: fix, cameras: nearbyCameras)
        for approach in approaches {
            announce(approach)
        }
    }

    private func announce(_ approach: CameraApproach) {
        guard shouldAnnounce(approach.camera) else { return }
        guard let line = phrasebook.cameraApproach(approach) else { return }
        speak(line, urgent: approach.urgency == .imminent)
    }

    /// Which of the four "what to announce" switches governs this camera.
    ///
    /// Every type maps to exactly one switch. The previous version gated the
    /// whole approach path on `announcePointCameras` before consulting this,
    /// which made the red light and mobile switches unreachable: turning speed
    /// cameras off turned everything off.
    private func shouldAnnounce(_ camera: Camera) -> Bool {
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

    private func speak(_ line: String, urgent: Bool) {
        guard settings.voiceEnabled else { return }
        voice.speak(line, urgent: urgent)
    }
}
