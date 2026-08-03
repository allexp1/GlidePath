import CoreLocation
import Foundation
import GlidePathCore
import Observation

/// Everything that touches CoreLocation.
///
/// Two tracking modes while watching, because the difference in battery cost is
/// the difference between an app you leave running and one you uninstall:
///
/// - **Drive.** Continuous updates whose accuracy and distance filter scale
///   with how close the nearest camera is. This is the mode the app is in
///   whenever the driver has pressed start.
/// - **Precise.** Best-for-navigation, no distance filter. Only inside a zone,
///   where the whole product depends on knowing exactly where the entry line
///   was crossed and how far along the road the driver is.
///
/// Significant-location changes run underneath both. They cost nothing extra
/// while continuous updates are already going, and they are what brings the app
/// back if iOS terminates it.
///
/// They are not, however, enough to warn anybody about anything on their own,
/// and the first version of this file assumed they were. A camera warning is
/// computed per fix against a window at most 900 m wide; significant-location
/// changes arrive every 500 m at best and often only every few kilometres. The
/// fix stream and the thing it fed were an order of magnitude apart, so a fix
/// almost never landed inside the window and the app was silent for whole drives
/// while appearing to work perfectly.
@MainActor
@Observable
final class LocationService: NSObject {
    /// What the receiver is being asked for right now.
    enum TrackingMode: Equatable {
        case off
        case drive
        case precise
    }

    /// The accuracy/filter pairs drive mode moves between.
    ///
    /// Buckets rather than a continuous function: every change of
    /// `desiredAccuracy` restarts the receiver's internal duty cycle, so
    /// recomputing it on each fix would be worse than leaving it alone.
    enum DriveResolution: Equatable {
        /// Nothing within a few kilometres. Cheap enough to hold all day.
        case coarse
        /// Something is coming. Enough fixes to time an announcement.
        case approach
        /// A camera is close, or a zone is live.
        case fine

        var desiredAccuracy: CLLocationAccuracy {
            switch self {
            case .coarse: return kCLLocationAccuracyHundredMeters
            case .approach: return kCLLocationAccuracyNearestTenMeters
            case .fine: return kCLLocationAccuracyBestForNavigation
            }
        }

        var distanceFilter: CLLocationDistance {
            switch self {
            case .coarse: return 200
            case .approach: return 40
            case .fine: return kCLDistanceFilterNone
            }
        }

        /// Chosen from the distance to the nearest thing worth announcing.
        ///
        /// The approach threshold is comfortably wider than the widest warning
        /// window (900 m), so the receiver is already awake and settled by the
        /// time the window opens rather than sharpening up inside it.
        static func forNearestFeature(meters: Double?) -> DriveResolution {
            guard let meters else { return .coarse }
            if meters <= 1_500 { return .fine }
            if meters <= 6_000 { return .approach }
            return .coarse
        }
    }
    /// Region monitoring is what wakes the app when it is not running, so the
    /// app has to be relaunchable into the background - hence "Always".
    private(set) var authorizationStatus: CLAuthorizationStatus
    private(set) var accuracyAuthorization: CLAccuracyAuthorization
    private(set) var latestFix: LocationFix?
    private(set) var mode: TrackingMode = .off
    private(set) var driveResolution: DriveResolution = .coarse

    /// How many fixes have arrived since tracking started. Surfaced so the
    /// settings screen can answer "is it actually receiving anything", which is
    /// the first question when a driver reports hearing nothing.
    private(set) var fixCount = 0

    var isTrackingPrecisely: Bool { mode == .precise }

    // These are annotated @MainActor rather than left bare. The closures are
    // only ever invoked from main-actor code, and saying so in the type is what
    // lets a subscriber call its own main-actor methods from inside them
    // without a concurrency violation.

    /// Called for every usable fix.
    var onFix: (@MainActor (LocationFix) -> Void)?

    /// Called with a monitored region's identifier when it is entered.
    var onRegionEntered: (@MainActor (String) -> Void)?
    var onRegionExited: (@MainActor (String) -> Void)?

    private let manager: CLLocationManager
    private var permissionContinuation: CheckedContinuation<CLAuthorizationStatus, Never>?

    override init() {
        manager = CLLocationManager()
        authorizationStatus = manager.authorizationStatus
        accuracyAuthorization = manager.accuracyAuthorization
        super.init()

        manager.delegate = self
        manager.pausesLocationUpdatesAutomatically = false
        manager.activityType = .automotiveNavigation
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    var monitoredRegions: Set<CLRegion> { manager.monitoredRegions }

    // MARK: - Permission

    /// Asks for "when in use" first, then escalates.
    ///
    /// iOS will not show the Always prompt cold: it has to be requested after
    /// When In Use has been granted, and even then it often appears later as a
    /// system-initiated upgrade prompt rather than immediately. Asking in the
    /// wrong order gets you a silent no.
    func requestWhenInUse() async -> CLAuthorizationStatus {
        guard authorizationStatus == .notDetermined else { return authorizationStatus }

        return await withCheckedContinuation { continuation in
            permissionContinuation = continuation
            manager.requestWhenInUseAuthorization()
        }
    }

    func requestAlways() {
        guard authorizationStatus == .authorizedWhenInUse else { return }
        manager.requestAlwaysAuthorization()
    }

    /// Asks for one-off precise location when the driver has granted only
    /// reduced accuracy. Reduced accuracy is fatally imprecise here: it can be
    /// kilometres out, which makes both the entry timestamp and the distance
    /// along the road meaningless.
    func requestTemporaryPreciseAccuracy() {
        guard accuracyAuthorization == .reducedAccuracy else { return }
        // The purpose key matches NSLocationTemporaryUsageDescriptionDictionary
        // in Info.plist. The result arrives through
        // locationManagerDidChangeAuthorization rather than a return value.
        manager.requestTemporaryFullAccuracyAuthorization(withPurposeKey: "ZonePrecision")
    }

    // MARK: - Tracking modes

    /// The mode the app is in while it is watching the road.
    ///
    /// Continuous updates, starting fine so the first fix arrives in seconds
    /// rather than after the first 200 m of driving. `DriveMonitor` relaxes it
    /// on the next fix once it knows there is nothing nearby.
    ///
    /// Significant-location changes stay on underneath. They cost nothing extra
    /// while continuous updates are running and they are the only thing that
    /// brings the app back if iOS terminates it.
    func startDriveTracking() {
        guard hasAnyAuthorization else { return }

        manager.startMonitoringSignificantLocationChanges()
        enableBackgroundUpdatesIfAllowed()
        manager.showsBackgroundLocationIndicator = true

        mode = .drive
        apply(resolution: .fine, force: true)
        manager.startUpdatingLocation()
    }

    /// Retunes drive mode for how far away the nearest camera or zone is.
    ///
    /// A no-op in precise mode: a live zone always wants everything the
    /// receiver has, whatever else happens to be nearby.
    func setDriveResolution(nearestFeatureMeters: Double?) {
        guard mode == .drive else { return }
        apply(resolution: .forNearestFeature(meters: nearestFeatureMeters), force: false)
    }

    /// Full accuracy, for the duration of a zone.
    func startPreciseTracking() {
        guard hasAnyAuthorization else { return }

        manager.allowsBackgroundLocationUpdates = authorizationStatus == .authorizedAlways
        manager.showsBackgroundLocationIndicator = true

        mode = .precise
        apply(resolution: .fine, force: true)
        manager.startUpdatingLocation()
    }

    /// Drops back to drive mode rather than stopping.
    ///
    /// Stopping outright is what the first version did, and it is wrong now:
    /// leaving a zone does not mean the driver has stopped driving, and the
    /// point cameras after the zone need the same fix stream the zone did.
    func stopPreciseTracking() {
        guard mode == .precise else { return }
        mode = .drive
        apply(resolution: .approach, force: true)
    }

    func stopAll() {
        manager.stopUpdatingLocation()
        manager.stopMonitoringSignificantLocationChanges()
        manager.showsBackgroundLocationIndicator = false
        for region in manager.monitoredRegions {
            manager.stopMonitoring(for: region)
        }
        mode = .off
        fixCount = 0
    }

    private func apply(resolution: DriveResolution, force: Bool) {
        guard force || resolution != driveResolution else { return }
        driveResolution = resolution
        manager.desiredAccuracy = resolution.desiredAccuracy
        manager.distanceFilter = resolution.distanceFilter
    }

    private func enableBackgroundUpdatesIfAllowed() {
        // Only meaningful with Always, and the source of the background
        // wake-ups the whole design depends on. Setting it under When In Use
        // throws at runtime rather than failing quietly.
        manager.allowsBackgroundLocationUpdates = authorizationStatus == .authorizedAlways
    }

    // MARK: - Region monitoring

    /// Core Location allows 20 monitored regions per app, and GeofenceManager
    /// owns deciding which 20. This just applies the decision.
    ///
    /// Uses the classic region-monitoring API rather than CLMonitor. It is
    /// formally deprecated but fully functional, and it is the path with the
    /// longest track record of relaunching a terminated app into the
    /// background, which is the behaviour GlidePath actually depends on.
    /// Migrating to CLMonitor is tracked in the README.
    func replaceMonitoredRegions(with regions: [CLCircularRegion]) {
        let wanted = Dictionary(regions.map { ($0.identifier, $0) }, uniquingKeysWith: { first, _ in first })
        let current = manager.monitoredRegions

        for region in current where wanted[region.identifier] == nil {
            manager.stopMonitoring(for: region)
        }

        let currentIdentifiers = Set(current.map(\.identifier))
        for region in regions where !currentIdentifiers.contains(region.identifier) {
            manager.startMonitoring(for: region)
        }
    }

    /// Region monitoring reports entry only on a *crossing*. A driver already
    /// inside a region when it starts being monitored is never announced, which
    /// happens every time the app relaunches mid-zone.
    func requestStateForAllRegions() {
        for region in manager.monitoredRegions {
            manager.requestState(for: region)
        }
    }

    private var hasAnyAuthorization: Bool {
        authorizationStatus == .authorizedAlways || authorizationStatus == .authorizedWhenInUse
    }
}

// MARK: - CLLocationManagerDelegate

// The delegate methods are nonisolated and hop onto the main actor explicitly.
// CoreLocation delivers callbacks on the queue the manager was created on, and
// this manager is created on the main actor, so the assumption holds.
extension LocationService: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        // Read the values out here rather than reaching through `manager`
        // inside the closure. CLLocationManager is not Sendable, so capturing
        // it would mean sending a non-Sendable reference across an isolation
        // boundary; the two enums it yields are values and cross freely.
        let status = manager.authorizationStatus
        let accuracy = manager.accuracyAuthorization

        MainActor.assumeIsolated {
            authorizationStatus = status
            accuracyAuthorization = accuracy

            if let continuation = permissionContinuation, authorizationStatus != .notDetermined {
                permissionContinuation = nil
                continuation.resume(returning: authorizationStatus)
            }
        }
    }

    nonisolated func locationManager(
        _ manager: CLLocationManager,
        didUpdateLocations locations: [CLLocation]
    ) {
        MainActor.assumeIsolated {
            for location in locations {
                let coordinate = Coordinate(
                    latitude: location.coordinate.latitude,
                    longitude: location.coordinate.longitude
                )
                let previous = latestFix

                let fix = LocationFix(
                    coordinate: coordinate,
                    timestamp: location.timestamp,
                    speedMps: location.speed >= 0
                        ? location.speed
                        : derivedSpeed(to: coordinate, at: location.timestamp, from: previous),
                    horizontalAccuracy: location.horizontalAccuracy,
                    courseDegrees: location.course >= 0
                        ? location.course
                        : derivedCourse(to: coordinate, from: previous)
                )
                latestFix = fix
                fixCount += 1
                onFix?(fix)
            }
        }
    }

    /// Speed worked out from the previous fix, for receivers that did not
    /// report one.
    ///
    /// Doppler speed is missing on any fix that did not come from a live GNSS
    /// solution, which includes most significant-location-change and
    /// cell/wi-fi fixes. Everything downstream converts speed into a warning
    /// distance, and a nil speed collapses that distance to the 120 m floor -
    /// about four seconds at motorway pace. A two-point average is coarse, but
    /// it is the difference between a warning and no warning.
    ///
    /// Deliberately conservative: a stale or duplicated fix produces no
    /// estimate rather than a wild one.
    private func derivedSpeed(
        to coordinate: Coordinate,
        at timestamp: Date,
        from previous: LocationFix?
    ) -> Double? {
        guard let previous else { return nil }

        let elapsed = timestamp.timeIntervalSince(previous.timestamp)
        guard elapsed > 0.5, elapsed <= 30 else { return nil }

        let speed = previous.coordinate.distance(to: coordinate) / elapsed
        // 90 m/s is 324 km/h. Anything above that is a jumped fix, not a car.
        guard speed <= 90 else { return nil }
        return speed
    }

    /// Course from the previous fix, for the same reason.
    ///
    /// Only over a baseline long enough to mean something: below about 20 m the
    /// bearing between two fixes is mostly GPS noise, and a wrong course makes
    /// `Camera.facesTraffic` discard a camera the driver is heading straight at.
    private func derivedCourse(to coordinate: Coordinate, from previous: LocationFix?) -> Double? {
        guard let previous else { return nil }
        guard previous.coordinate.distance(to: coordinate) >= 20 else { return nil }
        return previous.coordinate.bearing(to: coordinate)
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
        // CLRegion is not Sendable either, and only its identifier is needed.
        let identifier = region.identifier
        MainActor.assumeIsolated {
            onRegionEntered?(identifier)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
        let identifier = region.identifier
        MainActor.assumeIsolated {
            onRegionExited?(identifier)
        }
    }

    nonisolated func locationManager(
        _ manager: CLLocationManager,
        didDetermineState state: CLRegionState,
        for region: CLRegion
    ) {
        let identifier = region.identifier
        MainActor.assumeIsolated {
            if state == .inside {
                onRegionEntered?(identifier)
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // A transient failure is normal in a tunnel or a car park. The engine
        // already drops unusable fixes, so there is nothing to do but log.
        print("[GlidePath] location error: \(error.localizedDescription)")
    }

    nonisolated func locationManager(
        _ manager: CLLocationManager,
        monitoringDidFailFor region: CLRegion?,
        withError error: Error
    ) {
        let identifier = region?.identifier ?? "unknown"
        print("[GlidePath] region monitoring failed for \(identifier): \(error.localizedDescription)")
    }
}
