import CoreLocation
import ZonexploCore
import XCTest
@testable import Zonexplo

/// The twenty-region cap is a hard Core Location limit and the 21st call fails
/// silently, so getting the selection wrong produces an app that simply stops
/// warning about things with no error anywhere. Worth testing properly.
final class GeofenceManagerTests: XCTestCase {
    private let origin = Coordinate(latitude: 32.0, longitude: 34.8)

    private func camera(_ index: Int, metresEast: Double) -> Camera {
        Camera(
            id: "camera-\(index)",
            countryCode: "IL",
            coordinate: origin.offset(meters: metresEast, bearingDegrees: 90),
            type: .fixed,
            speedLimitKph: 90
        )
    }

    private func zone(_ index: Int, metresEast: Double) -> Zone {
        let entry = origin.offset(meters: metresEast, bearingDegrees: 90)
        return Zone(
            id: "zone-\(index)",
            countryCode: "IL",
            entry: entry,
            exit: entry.offset(meters: 5_000, bearingDegrees: 90),
            distanceMeters: 5_000,
            speedLimitKph: 110
        )
    }

    func testTheRegionSetNeverExceedsCoreLocationsLimit() {
        var manager = GeofenceManager()
        let cameras = (0..<200).map { camera($0, metresEast: Double($0) * 500) }
        let zones = (0..<40).map { zone($0, metresEast: Double($0) * 1_200) }

        let regions = manager.regions(around: origin, zones: zones, cameras: cameras)

        XCTAssertLessThanOrEqual(regions.count, GeofenceManager.maximumMonitoredRegions)
        XCTAssertEqual(Set(regions.map(\.identifier)).count, regions.count, "identifiers must be unique")
    }

    /// A missed point camera costs one fine. A missed zone entry costs the
    /// feature the app exists for, so zones are seeded before cameras.
    func testZonesAreSeededBeforePointCameras() {
        var manager = GeofenceManager()
        // Every camera is closer than every zone, and yet the zones must win.
        let cameras = (0..<50).map { camera($0, metresEast: Double($0) + 10) }
        let zones = (0..<5).map { zone($0, metresEast: 30_000 + Double($0) * 1_000) }

        let regions = manager.regions(around: origin, zones: zones, cameras: cameras)
        let zoneRegions = regions.filter { $0.identifier.hasPrefix("zone:") }

        XCTAssertEqual(zoneRegions.count, 5)
    }

    func testTheNearestCamerasAreChosen() {
        var manager = GeofenceManager()
        let cameras = (0..<100).map { camera($0, metresEast: Double($0 + 1) * 1_000) }

        let regions = manager.regions(around: origin, zones: [], cameras: cameras)
        let identifiers = Set(regions.map(\.identifier))

        XCTAssertTrue(identifiers.contains("camera:camera-0"), "the closest camera must always be monitored")
        XCTAssertFalse(identifiers.contains("camera:camera-99"), "a camera 100 km away must not take a slot")
    }

    func testUnverifiedCamerasDoNotConsumeSlots() {
        var manager = GeofenceManager()
        let ghost = Camera(
            id: "ghost",
            countryCode: "IL",
            coordinate: origin,
            type: .fixed,
            verified: false
        )
        let real = camera(1, metresEast: 2_000)

        let regions = manager.regions(around: origin, zones: [], cameras: [ghost, real])
        XCTAssertEqual(regions.map(\.identifier), ["camera:camera-1"])
    }

    /// Zone entry and exit markers are handled by the zone itself; monitoring
    /// them again would burn two of twenty slots per zone for nothing.
    func testZoneMarkerCamerasAreIgnored() {
        var manager = GeofenceManager()
        let marker = Camera(
            id: "marker",
            countryCode: "IL",
            coordinate: origin,
            type: .zoneEntry,
            zoneID: "zone-0"
        )

        let regions = manager.regions(around: origin, zones: [], cameras: [marker])
        XCTAssertTrue(regions.isEmpty)
    }

    func testIdentifiersRoundTrip() {
        let zoneTarget = GeofenceManager.Target.zoneEntry(zoneID: "abc-123")
        XCTAssertEqual(GeofenceManager.Target.from(identifier: zoneTarget.identifier), zoneTarget)

        let cameraTarget = GeofenceManager.Target.camera(cameraID: "def-456")
        XCTAssertEqual(GeofenceManager.Target.from(identifier: cameraTarget.identifier), cameraTarget)

        XCTAssertNil(GeofenceManager.Target.from(identifier: "nonsense"))
    }

    /// A UUID contains no colons, but the parser splitting on the first one
    /// only matters if it is actually limited to one split. This pins that
    /// down against a future identifier scheme that does contain colons.
    func testIdentifiersSurviveColonsInTheId() {
        let target = GeofenceManager.Target.zoneEntry(zoneID: "manual/route:6:north")
        XCTAssertEqual(GeofenceManager.Target.from(identifier: target.identifier), target)
    }

    func testTheWindowOnlyMovesOnceTheDriverHasTravelled() {
        var manager = GeofenceManager()
        XCTAssertTrue(manager.needsRefresh(at: origin), "the first fix always needs a window")

        _ = manager.regions(around: origin, zones: [], cameras: [])
        XCTAssertFalse(manager.needsRefresh(at: origin.offset(meters: 1_000, bearingDegrees: 90)))
        XCTAssertTrue(manager.needsRefresh(at: origin.offset(meters: 20_000, bearingDegrees: 90)))
    }

    func testZoneEntryRegionsAreWideEnoughToWakeTheReceiver() {
        var manager = GeofenceManager()
        let regions = manager.regions(around: origin, zones: [zone(0, metresEast: 1_000)], cameras: [])

        guard let region = regions.first else { return XCTFail("expected a zone region") }
        // At 110 km/h a 750 m radius is roughly 25 seconds of warning, which is
        // what the GPS needs to wake, lock and settle before the entry line.
        XCTAssertGreaterThanOrEqual(region.radius, 500)
    }
}
