import XCTest
@testable import ZonexploCore

/// The lookup behind "what is the limit where this camera stands".
///
/// The interesting cases are all refusals. Returning a number is easy; the
/// value of this thing is that it declines to when the roads around the point
/// do not agree, because the number goes on screen next to a camera and a
/// driver may act on it without seeing a sign.
final class RoadLimitLookupTests: XCTestCase {
    private let origin = TestFixtures.origin

    /// A straight road heading `bearing`, shifted `offsetMeters` sideways.
    private func road(
        id: String,
        limitKph: Double,
        bearing: Double = 90,
        offsetMeters: Double = 0,
        forward: Double? = nil,
        backward: Double? = nil
    ) -> RoadLimit {
        let start = origin.offset(meters: offsetMeters, bearingDegrees: bearing + 90)

        var coordinates: [Coordinate] = []
        var distance = 0.0
        while distance <= 2_000 {
            coordinates.append(start.offset(meters: distance, bearingDegrees: bearing))
            distance += 100
        }

        guard let path = RoadPath(coordinates: coordinates) else {
            fatalError("road fixture produced an unusable polyline")
        }

        return RoadLimit(
            id: id,
            countryCode: "IL",
            name: "Test Road \(id)",
            roadRef: "R\(id)",
            path: path,
            limitKph: limitKph,
            forwardLimitKph: forward,
            backwardLimitKph: backward
        )
    }

    /// A camera on a road with nothing else near it.
    func testTakesTheLimitOfTheRoadItStandsOn() {
        let point = origin.offset(meters: 500, bearingDegrees: 90)
        let result = RoadLimitLookup.limit(at: point, candidates: [road(id: "a", limitKph: 90)])

        XCTAssertEqual(result?.limitKph, 90)
        XCTAssertEqual(result?.offsetMeters ?? .infinity, 0, accuracy: 1)
    }

    /// The case this exists to get right. A motorway and its slip road both run
    /// under the corridor; taking the nearest would put 60 next to a camera
    /// that enforces 110, or the reverse.
    func testRefusesWhenNeighbouringRoadsDisagree() {
        let point = origin.offset(meters: 500, bearingDegrees: 90)
        let candidates = [
            road(id: "motorway", limitKph: 110),
            road(id: "slip", limitKph: 60, offsetMeters: 12)
        ]
        XCTAssertNil(RoadLimitLookup.limit(at: point, candidates: candidates))
    }

    /// Two carriageways of the same motorway are not a disagreement, and
    /// refusing there would throw away the answer on exactly the roads where
    /// average-speed cameras live.
    func testAgreeingCarriagewaysStillAnswer() {
        let point = origin.offset(meters: 500, bearingDegrees: 90)
        let candidates = [
            road(id: "north", limitKph: 110),
            road(id: "south", limitKph: 110, offsetMeters: 18)
        ]
        XCTAssertEqual(RoadLimitLookup.limit(at: point, candidates: candidates)?.limitKph, 110)
    }

    /// A road further away than the corridor is not the road the camera is on,
    /// and must not veto the one that is.
    func testRoadsOutsideTheCorridorAreIgnoredEntirely() {
        let point = origin.offset(meters: 500, bearingDegrees: 90)
        let candidates = [
            road(id: "here", limitKph: 50),
            road(id: "far", limitKph: 100, offsetMeters: 120)
        ]
        XCTAssertEqual(RoadLimitLookup.limit(at: point, candidates: candidates)?.limitKph, 50)
    }

    func testNothingNearbyReturnsNothing() {
        let point = origin.offset(meters: 500, bearingDegrees: 90)
        XCTAssertNil(RoadLimitLookup.limit(at: point, candidates: []))
        XCTAssertNil(
            RoadLimitLookup.limit(
                at: point,
                candidates: [road(id: "far", limitKph: 80, offsetMeters: 400)]
            )
        )
    }

    /// A camera watches one direction, and on a road whose carriageways differ
    /// that is the direction whose limit it enforces.
    func testDirectionalRoadUsesTheDirectionTheCameraFaces() {
        let point = origin.offset(meters: 500, bearingDegrees: 90)
        let dual = road(id: "dual", limitKph: 100, forward: 100, backward: 70)

        XCTAssertEqual(RoadLimitLookup.limit(at: point, facing: 90, candidates: [dual])?.limitKph, 100)
        XCTAssertEqual(RoadLimitLookup.limit(at: point, facing: 270, candidates: [dual])?.limitKph, 70)

        // With no direction recorded, the road's own undirected value stands.
        XCTAssertEqual(RoadLimitLookup.limit(at: point, candidates: [dual])?.limitKph, 100)
    }
}
