import CoreLocation
import Foundation
import GlidePathCore

/// Chooses which twenty places on earth the phone is allowed to watch.
///
/// Core Location caps region monitoring at 20 regions per app, and it is a hard
/// cap: the 21st call silently fails. Israel alone has hundreds of cameras, so
/// the set has to be a moving window around the driver, rebuilt as they travel.
///
/// The selection is not simply "nearest 20". A missed point camera costs one
/// fine; a missed zone entry costs the whole feature the app exists for, so zone
/// entries are seeded first and point cameras fill whatever is left.
struct GeofenceManager {
    /// Core Location's limit. Not a tuning knob.
    static let maximumMonitoredRegions = 20

    /// Left free so a zone entry discovered mid-drive always has somewhere to
    /// go without evicting something first.
    static let headroom = 2

    /// Wide, because the geofence has to fire early enough for the receiver to
    /// wake, lock and settle before the driver reaches the real entry line.
    /// The crossing itself is timestamped from the fix stream, not from this,
    /// so being generous here costs nothing in accuracy.
    static let zoneEntryRadius: CLLocationDistance = 750

    static let cameraRadius: CLLocationDistance = 350

    /// How far the driver must move before the window is worth rebuilding.
    /// Rebuilding is cheap but not free, and thrashing the region list is a
    /// good way to lose a wake-up.
    static let refreshThreshold: CLLocationDistance = 5_000

    enum Target: Equatable {
        case zoneEntry(zoneID: String)
        case camera(cameraID: String)

        /// Encoded into the region identifier so a background wake-up knows
        /// what it woke up for without a database round trip.
        var identifier: String {
            switch self {
            case let .zoneEntry(zoneID): return "zone:\(zoneID)"
            case let .camera(cameraID): return "camera:\(cameraID)"
            }
        }

        static func from(identifier: String) -> Target? {
            let parts = identifier.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { return nil }
            switch parts[0] {
            case "zone": return .zoneEntry(zoneID: String(parts[1]))
            case "camera": return .camera(cameraID: String(parts[1]))
            default: return nil
            }
        }
    }

    private(set) var lastRefreshCentre: Coordinate?

    init() {}

    /// True when the driver has moved far enough that the window should move.
    func needsRefresh(at coordinate: Coordinate) -> Bool {
        guard let centre = lastRefreshCentre else { return true }
        return centre.distance(to: coordinate) > Self.refreshThreshold
    }

    /// Claims the refresh before the asynchronous work starts.
    ///
    /// Without this, every fix arriving while a database query is in flight
    /// sees a stale centre and kicks off another one, which at 1 Hz is dozens
    /// of redundant queries and a real chance of losing a wake-up while the
    /// region list is being rewritten.
    mutating func noteRefreshStarted(at coordinate: Coordinate) {
        lastRefreshCentre = coordinate
    }

    /// Builds the region set for a position.
    ///
    /// - Parameters:
    ///   - cameras: candidates. Zone markers are ignored; zone entries are
    ///     monitored through `zones` instead, which carries the geometry.
    mutating func regions(
        around coordinate: Coordinate,
        zones: [Zone],
        cameras: [Camera]
    ) -> [CLCircularRegion] {
        lastRefreshCentre = coordinate

        let budget = Self.maximumMonitoredRegions - Self.headroom

        let nearestZones = zones
            .map { (zone: $0, distance: coordinate.distance(to: $0.entry)) }
            .sorted { $0.distance < $1.distance }
            .prefix(budget)
            .map(\.zone)

        let remaining = max(budget - nearestZones.count, 0)

        let nearestCameras = cameras
            .filter { $0.verified && !$0.type.isZoneMarker }
            .map { (camera: $0, distance: coordinate.distance(to: $0.coordinate)) }
            .sorted { $0.distance < $1.distance }
            .prefix(remaining)
            .map(\.camera)

        var regions: [CLCircularRegion] = nearestZones.map { zone in
            region(
                identifier: Target.zoneEntry(zoneID: zone.id).identifier,
                centre: zone.entry,
                radius: Self.zoneEntryRadius
            )
        }

        regions += nearestCameras.map { camera in
            region(
                identifier: Target.camera(cameraID: camera.id).identifier,
                centre: camera.coordinate,
                radius: Self.cameraRadius
            )
        }

        return regions
    }

    private func region(
        identifier: String,
        centre: Coordinate,
        radius: CLLocationDistance
    ) -> CLCircularRegion {
        let region = CLCircularRegion(
            center: CLLocationCoordinate2D(latitude: centre.latitude, longitude: centre.longitude),
            radius: radius,
            identifier: identifier
        )
        region.notifyOnEntry = true
        // Exit matters as much as entry: it is what lets the app drop back out
        // of precise tracking when a driver passes a camera without entering a
        // zone, rather than burning the battery until they notice.
        region.notifyOnExit = true
        return region
    }
}
