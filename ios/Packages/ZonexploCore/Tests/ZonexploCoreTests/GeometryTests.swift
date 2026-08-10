import XCTest
@testable import ZonexploCore

final class GeometryTests: XCTestCase {
    func testDistanceBetweenKnownPoints() {
        let start = TestFixtures.origin
        let east = start.offset(meters: 1_000, bearingDegrees: 90)
        XCTAssertEqual(start.distance(to: east), 1_000, accuracy: 0.5)
    }

    func testBearingIsClockwiseFromNorth() {
        let start = TestFixtures.origin
        XCTAssertEqual(start.bearing(to: start.offset(meters: 500, bearingDegrees: 90)), 90, accuracy: 0.5)
        XCTAssertEqual(start.bearing(to: start.offset(meters: 500, bearingDegrees: 0)), 0, accuracy: 0.5)
        XCTAssertEqual(start.bearing(to: start.offset(meters: 500, bearingDegrees: 270)), 270, accuracy: 0.5)
    }

    func testPathRejectsDegenerateInput() {
        XCTAssertNil(RoadPath(coordinates: []))
        XCTAssertNil(RoadPath(coordinates: [TestFixtures.origin]))
        XCTAssertNil(RoadPath(coordinates: [TestFixtures.origin, TestFixtures.origin]))
    }

    func testCumulativeDistancesMatchTotalLength() {
        let path = TestFixtures.straightPath(lengthMeters: 5_000)
        XCTAssertEqual(path.totalDistance, 5_000, accuracy: 2)
        XCTAssertEqual(path.cumulativeDistances.first, 0)
        XCTAssertEqual(path.cumulativeDistances.count, path.coordinates.count)
    }

    /// The two halves must cover the road exactly once and meet at the cut.
    /// A gap here draws as a break in the section on the map, which reads as
    /// "the zone ends and starts again" rather than "you are here".
    func testSplitHalvesMeetAtTheCut() {
        let path = TestFixtures.straightPath(lengthMeters: 5_000)
        let (covered, remaining) = path.split(atDistance: 1_750)

        XCTAssertGreaterThanOrEqual(covered.count, 2)
        XCTAssertGreaterThanOrEqual(remaining.count, 2)
        XCTAssertEqual(covered.last?.distance(to: remaining[0]) ?? .infinity, 0, accuracy: 0.001)
        XCTAssertEqual(covered[0].distance(to: path.start), 0, accuracy: 0.001)
        XCTAssertEqual(remaining[remaining.count - 1].distance(to: path.end), 0, accuracy: 0.001)

        let cut = covered[covered.count - 1]
        XCTAssertEqual(path.project(cut).distanceAlong, 1_750, accuracy: 2)
    }

    /// At the ends one half is empty rather than a stub, so nothing is drawn
    /// for a section not yet entered or already finished.
    func testSplitAtTheEndsGivesOneEmptyHalf() {
        let path = TestFixtures.straightPath(lengthMeters: 5_000)

        let atStart = path.split(atDistance: 0)
        XCTAssertTrue(atStart.covered.isEmpty)
        XCTAssertEqual(atStart.remaining.count, path.coordinates.count)

        let past = path.split(atDistance: 9_000)
        XCTAssertEqual(past.covered.count, path.coordinates.count)
        XCTAssertTrue(past.remaining.isEmpty)
    }

    func testProjectionRecoversDistanceAlong() {
        let path = TestFixtures.straightPath(lengthMeters: 5_000)
        let point = path.coordinate(atDistance: 1_750)
        let projection = path.project(point)

        XCTAssertEqual(projection.distanceAlong, 1_750, accuracy: 2)
        XCTAssertEqual(projection.crossTrackDistance, 0, accuracy: 1)
    }

    /// The property the whole odometer relies on: moving sideways off the road
    /// changes the cross-track distance and leaves the along-track distance
    /// alone.
    func testLateralOffsetMovesCrossTrackNotAlongTrack() {
        let path = TestFixtures.straightPath(lengthMeters: 5_000)
        let onRoad = path.coordinate(atDistance: 2_000)
        let offRoad = onRoad.offset(meters: 40, bearingDegrees: 0)

        let projection = path.project(offRoad)
        XCTAssertEqual(projection.distanceAlong, 2_000, accuracy: 3)
        XCTAssertEqual(projection.crossTrackDistance, 40, accuracy: 2)
    }

    func testExtendedProjectionIsNegativeBeforeTheStart() {
        let path = TestFixtures.straightPath(lengthMeters: 5_000)
        let approaching = path.start.offset(meters: 250, bearingDegrees: 270)
        let projection = path.project(approaching)

        XCTAssertEqual(projection.extendedDistanceAlong, -250, accuracy: 2)
        XCTAssertEqual(projection.distanceAlong, 0, accuracy: 2, "the clamped value stops at the start")
    }

    func testExtendedProjectionOvershootsPastTheEnd() {
        let path = TestFixtures.straightPath(lengthMeters: 5_000)
        let past = path.end.offset(meters: 180, bearingDegrees: 90)
        let projection = path.project(past)

        XCTAssertEqual(projection.extendedDistanceAlong, 5_180, accuracy: 3)
        XCTAssertEqual(projection.distanceAlong, path.totalDistance, accuracy: 2)
    }

    func testCoordinateAtDistanceClampsToTheEnds() {
        let path = TestFixtures.straightPath(lengthMeters: 5_000)
        XCTAssertEqual(path.coordinate(atDistance: -100), path.start)
        XCTAssertEqual(path.coordinate(atDistance: 99_999), path.end)
    }

    func testUnitConversionsRoundTrip() {
        XCTAssertEqual(Units.kph(fromMps: Units.mps(fromKph: 137)), 137, accuracy: 0.0001)
        XCTAssertEqual(Units.mps(fromKph: 36), 10, accuracy: 0.0001)
    }

    func testCoachableSpeedAlwaysRoundsDown() {
        XCTAssertEqual((81.3).roundedDownToCoachableSpeed(), 80)
        XCTAssertEqual((84.9).roundedDownToCoachableSpeed(), 80)
        XCTAssertEqual((85.0).roundedDownToCoachableSpeed(), 85)
    }
}
