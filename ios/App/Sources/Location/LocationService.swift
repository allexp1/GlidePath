import CoreLocation
import Foundation
import GlidePathCore
import Observation

/// Everything that touches CoreLocation.
///
/// Two accuracy modes, because the difference in battery cost is the difference
/// between an app you leave running and one you uninstall:
///
/// - **Standby.** Significant-location changes plus region monitoring. Costs
///   almost nothing, and is enough to notice the driver approaching a zone.
/// - **Precise.** Best-for-navigation continuous updates. Only inside a zone,
///   where the whole product depends on knowing exactly where the entry line
///   was crossed and how far along the road the driver is.
@MainActor
@Observable
final class LocationService: NSObject {
    /// Region monitoring is what wakes the app when it is not running, so the
    /// app has to be relaunchable into the background - hence "Always".
    private(set) var authorizationStatus: CLAuthorizationStatus
    private(set) var accuracyAuthorization: CLAccuracyAuthorization
    private(set) var latestFix: LocationFix?
    private(set) var isTrackingPrecisely = false

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

    /// The low-power default: enough to notice a zone coming, cheap enough to
    /// leave on all day.
    func startStandbyTracking() {
        guard hasAnyAuthorization else { return }

        manager.stopUpdatingLocation()
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.startMonitoringSignificantLocationChanges()

        if authorizationStatus == .authorizedAlways {
            // Only meaningful with Always, and the source of the background
            // wake-ups the whole design depends on.
            manager.allowsBackgroundLocationUpdates = true
        }

        isTrackingPrecisely = false
    }

    /// Full accuracy, for the duration of a zone.
    func startPreciseTracking() {
        guard hasAnyAuthorization else { return }

        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.distanceFilter = kCLDistanceFilterNone
        manager.allowsBackgroundLocationUpdates = authorizationStatus == .authorizedAlways
        manager.showsBackgroundLocationIndicator = true
        manager.startUpdatingLocation()

        isTrackingPrecisely = true
    }

    func stopPreciseTracking() {
        guard isTrackingPrecisely else { return }
        manager.stopUpdatingLocation()
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.showsBackgroundLocationIndicator = false
        isTrackingPrecisely = false
    }

    func stopAll() {
        manager.stopUpdatingLocation()
        manager.stopMonitoringSignificantLocationChanges()
        for region in manager.monitoredRegions {
            manager.stopMonitoring(for: region)
        }
        isTrackingPrecisely = false
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
        MainActor.assumeIsolated {
            authorizationStatus = manager.authorizationStatus
            accuracyAuthorization = manager.accuracyAuthorization

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
                let fix = LocationFix(
                    coordinate: Coordinate(
                        latitude: location.coordinate.latitude,
                        longitude: location.coordinate.longitude
                    ),
                    timestamp: location.timestamp,
                    speedMps: location.speed >= 0 ? location.speed : nil,
                    horizontalAccuracy: location.horizontalAccuracy,
                    courseDegrees: location.course >= 0 ? location.course : nil
                )
                latestFix = fix
                onFix?(fix)
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
        MainActor.assumeIsolated {
            onRegionEntered?(region.identifier)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
        MainActor.assumeIsolated {
            onRegionExited?(region.identifier)
        }
    }

    nonisolated func locationManager(
        _ manager: CLLocationManager,
        didDetermineState state: CLRegionState,
        for region: CLRegion
    ) {
        MainActor.assumeIsolated {
            if state == .inside {
                onRegionEntered?(region.identifier)
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
