import XCTest
@testable import GlidePathCore

final class CameraApproachTests: XCTestCase {
    private let cameraSite = TestFixtures.origin.offset(meters: 5_000, bearingDegrees: 90)

    private func camera(
        id: String = "cam",
        type: CameraType = .fixed,
        direction: Double? = 90,
        limitKph: Double? = 90
    ) -> Camera {
        Camera(
            id: id,
            countryCode: "MD",
            coordinate: cameraSite,
            type: type,
            directionDegrees: direction,
            speedLimitKph: limitKph
        )
    }

    /// Approaching from the west at `speedKph`, `metresAway` short of the site.
    private func fix(metresAway: Double, speedKph: Double = 108, course: Double = 90) -> LocationFix {
        LocationFix(
            coordinate: cameraSite.offset(meters: metresAway, bearingDegrees: 270),
            timestamp: TestFixtures.referenceDate,
            speedMps: Units.mps(fromKph: speedKph),
            horizontalAccuracy: 5,
            courseDegrees: course
        )
    }

    func testNothingIsSaidWhileStillFarOut() {
        var monitor = CameraApproachMonitor()
        // 108 km/h is 30 m/s, so the advance threshold sits at 720 m.
        XCTAssertTrue(monitor.update(fix: fix(metresAway: 850), cameras: [camera()]).isEmpty)
    }

    func testAdvanceThenImminentEachFireOnce() {
        var monitor = CameraApproachMonitor()
        let target = camera()

        XCTAssertTrue(monitor.update(fix: fix(metresAway: 850), cameras: [target]).isEmpty)

        let advance = monitor.update(fix: fix(metresAway: 700), cameras: [target])
        XCTAssertEqual(advance.count, 1)
        XCTAssertEqual(advance.first?.urgency, .advance)

        XCTAssertTrue(
            monitor.update(fix: fix(metresAway: 600), cameras: [target]).isEmpty,
            "the same warning must not repeat every second"
        )

        let imminent = monitor.update(fix: fix(metresAway: 250), cameras: [target])
        XCTAssertEqual(imminent.count, 1)
        XCTAssertEqual(imminent.first?.urgency, .imminent)

        XCTAssertTrue(monitor.update(fix: fix(metresAway: 100), cameras: [target]).isEmpty)
    }

    /// Thresholds are times, not distances: the same camera has to be announced
    /// further out when the driver is going faster.
    func testWarningDistanceScalesWithSpeed() {
        var fast = CameraApproachMonitor()
        var slow = CameraApproachMonitor()
        let target = camera()

        XCTAssertFalse(fast.update(fix: fix(metresAway: 700, speedKph: 108), cameras: [target]).isEmpty)
        XCTAssertTrue(
            slow.update(fix: fix(metresAway: 700, speedKph: 50), cameras: [target]).isEmpty,
            "at 50 km/h, 700 m away is nearly a minute of driving"
        )
    }

    func testSlowDriversStillGetSomeWarning() {
        var monitor = CameraApproachMonitor()
        // 20 km/h would put the advance threshold at 133 m, but the floor holds
        // it at 120 m so a crawling driver is not told at the last instant.
        let approaches = monitor.update(fix: fix(metresAway: 130, speedKph: 20), cameras: [camera()])
        XCTAssertFalse(approaches.isEmpty)
    }

    func testCamerasFacingTheOtherCarriagewayAreIgnored() {
        var monitor = CameraApproachMonitor()
        let westbound = camera(direction: 270)
        XCTAssertTrue(monitor.update(fix: fix(metresAway: 400), cameras: [westbound]).isEmpty)
    }

    func testCamerasWithNoRecordedDirectionAlwaysWarn() {
        var monitor = CameraApproachMonitor()
        XCTAssertFalse(monitor.update(fix: fix(metresAway: 400), cameras: [camera(direction: nil)]).isEmpty)
    }

    func testZoneMarkersAreLeftToTheZoneSession() {
        var monitor = CameraApproachMonitor()
        let entry = camera(type: .zoneEntry)
        let exit = camera(id: "cam2", type: .zoneExit)
        XCTAssertTrue(monitor.update(fix: fix(metresAway: 300), cameras: [entry, exit]).isEmpty)
    }

    func testOverspeedIsReportedForSpeedEnforcingCamerasOnly() {
        var speedCamera = CameraApproachMonitor()
        let overspeeding = fix(metresAway: 200, speedKph: 120)

        let speedResult = speedCamera.update(fix: overspeeding, cameras: [camera(limitKph: 90)])
        XCTAssertEqual(speedResult.first?.overLimitByKph ?? 0, 30, accuracy: 0.01)

        var redLight = CameraApproachMonitor()
        let redResult = redLight.update(fix: overspeeding, cameras: [camera(type: .redLight, limitKph: 90)])
        XCTAssertNil(
            redResult.first?.overLimitByKph,
            "a red light camera does not care how fast you are going"
        )
    }

    func testMobileHotspotsAreAnnouncedEarlier() {
        var monitor = CameraApproachMonitor()
        // 720 m is the normal advance threshold; the 1.5x advisory multiplier
        // pushes a hotspot out past it.
        let approaches = monitor.update(
            fix: fix(metresAway: 850),
            cameras: [camera(type: .mobileHotspot, limitKph: nil)]
        )
        XCTAssertEqual(approaches.first?.urgency, .advance)
    }

    // MARK: - The geofence backstop

    /// The camera geofence exists so a warning still happens when the fix stream
    /// did not manage one: a cold start, a tunnel, a receiver that had not
    /// settled. Before this path existed the region fired and was discarded, and
    /// the app was silent for a whole drive.
    func testAGeofenceCrossingAnnouncesACameraTheFixStreamMissed() {
        var monitor = CameraApproachMonitor()
        let approach = monitor.announceGeofenceCrossing(of: camera(), at: fix(metresAway: 350))

        XCTAssertEqual(approach?.camera.id, "cam")
        XCTAssertEqual(approach?.urgency, .advance)
    }

    /// A geofence radius is fixed while the warning window is a function of
    /// speed, so a crossing says nothing about how much time is left. Claiming
    /// urgency the data does not support is how an app teaches drivers to ignore
    /// it.
    func testAGeofenceCrossingIsNeverReportedAsImminent() {
        var monitor = CameraApproachMonitor()
        let crawling = fix(metresAway: 350, speedKph: 5)
        XCTAssertEqual(monitor.announceGeofenceCrossing(of: camera(), at: crawling)?.urgency, .advance)
    }

    func testAGeofenceCrossingDoesNotRepeatWhatWasAlreadySaid() {
        var monitor = CameraApproachMonitor()
        let target = camera()

        XCTAssertFalse(monitor.update(fix: fix(metresAway: 700), cameras: [target]).isEmpty)
        XCTAssertNil(
            monitor.announceGeofenceCrossing(of: target, at: fix(metresAway: 350)),
            "the ordinary window already spoke; the backstop must stay quiet"
        )
    }

    func testTheOrdinaryWindowDoesNotRepeatWhatTheGeofenceSaid() {
        var monitor = CameraApproachMonitor()
        let target = camera()

        XCTAssertNotNil(monitor.announceGeofenceCrossing(of: target, at: fix(metresAway: 350)))
        XCTAssertTrue(
            monitor.update(fix: fix(metresAway: 300), cameras: [target]).isEmpty,
            "both paths share the announced set, so neither doubles up on the other"
        )
    }

    func testAGeofenceCrossingRespectsTheCameraDirection() {
        var monitor = CameraApproachMonitor()
        let westbound = camera(direction: 270)
        XCTAssertNil(monitor.announceGeofenceCrossing(of: westbound, at: fix(metresAway: 350)))
    }

    func testAGeofenceCrossingLeavesZoneMarkersAlone() {
        var monitor = CameraApproachMonitor()
        XCTAssertNil(
            monitor.announceGeofenceCrossing(of: camera(type: .zoneEntry), at: fix(metresAway: 350))
        )
    }

    func testResultsComeBackNearestFirst() {
        var monitor = CameraApproachMonitor()
        let near = Camera(
            id: "near",
            countryCode: "MD",
            coordinate: cameraSite.offset(meters: 400, bearingDegrees: 270),
            type: .fixed,
            directionDegrees: 90,
            speedLimitKph: 90
        )
        let far = camera(id: "far")

        let approaches = monitor.update(fix: fix(metresAway: 700), cameras: [far, near])
        XCTAssertEqual(approaches.count, 2)
        XCTAssertEqual(approaches.first?.camera.id, "near")
    }
}
