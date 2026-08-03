import XCTest
@testable import GlidePathCore

/// The cases that decide whether "the limit on this road" is a useful number or
/// a flickering one. Every test here is a shape of road that actually exists.
final class RoadLimitMatcherTests: XCTestCase {
    private let origin = TestFixtures.origin
    private let now = TestFixtures.referenceDate

    // MARK: - Fixtures

    /// A straight road heading `bearing`, offset `offsetMeters` sideways from
    /// the origin, sampled densely enough that projection is about the matcher
    /// rather than about the polyline.
    private func road(
        id: String,
        limitKph: Double,
        bearing: Double = 90,
        offsetMeters: Double = 0,
        lengthMeters: Double = 3_000,
        forward: Double? = nil,
        backward: Double? = nil
    ) -> RoadLimit {
        // Offset perpendicular to the road's own direction, so "20 m to the
        // side" means the same thing whichever way the road runs.
        let start = origin.offset(meters: offsetMeters, bearingDegrees: bearing + 90)

        var coordinates: [Coordinate] = []
        var distance = 0.0
        while distance <= lengthMeters {
            coordinates.append(start.offset(meters: distance, bearingDegrees: bearing))
            distance += 100
        }

        guard let path = RoadPath(coordinates: coordinates) else {
            fatalError("road fixture produced an unusable polyline")
        }

        return RoadLimit(
            id: id,
            countryCode: "LT",
            path: path,
            limitKph: limitKph,
            forwardLimitKph: forward,
            backwardLimitKph: backward
        )
    }

    /// A fix `alongMeters` down the origin road, `offsetMeters` to its side.
    private func fix(
        alongMeters: Double,
        offsetMeters: Double = 0,
        course: Double? = 90,
        secondsIn: TimeInterval = 0
    ) -> LocationFix {
        let onLine = origin.offset(meters: alongMeters, bearingDegrees: 90)
        return LocationFix(
            coordinate: onLine.offset(meters: offsetMeters, bearingDegrees: 180),
            timestamp: now.addingTimeInterval(secondsIn),
            speedMps: Units.mps(fromKph: 90),
            horizontalAccuracy: 5,
            courseDegrees: course
        )
    }

    // MARK: - The basics

    func testMatchesTheRoadUnderTheCar() {
        var matcher = RoadLimitMatcher()
        let match = matcher.update(fix: fix(alongMeters: 500), candidates: [road(id: "a", limitKph: 90)])

        XCTAssertEqual(match?.road.id, "a")
        XCTAssertEqual(match?.limitKph, 90)
    }

    func testARoadOutsideTheCorridorIsNotACandidate() {
        var matcher = RoadLimitMatcher()
        // 80 m away is well past anything GPS error plus a carriageway explains.
        let parallel = road(id: "far", limitKph: 50, offsetMeters: 80)

        XCTAssertNil(matcher.update(fix: fix(alongMeters: 500), candidates: [parallel]))
    }

    /// The junction case. A cross street passes through the driver's exact
    /// position and is therefore nearer than the road they are on, and distance
    /// alone would hand them its limit.
    func testTheCrossStreetAtAJunctionIsRejectedOnHeading() {
        var matcher = RoadLimitMatcher()
        let mainRoad = road(id: "main", limitKph: 90, bearing: 90)
        let crossStreet = road(id: "cross", limitKph: 30, bearing: 0, offsetMeters: 0)

        // Driving east, so the northbound cross street runs across the course.
        let match = matcher.update(
            fix: fix(alongMeters: 0, course: 90),
            candidates: [crossStreet, mainRoad]
        )

        XCTAssertEqual(match?.road.id, "main")
        XCTAssertEqual(match?.limitKph, 90)
    }

    /// A two-way road is the same road whichever way it is driven. Direction
    /// decides which *limit* applies, not which road it is.
    func testDrivingAgainstTheGeometryStillMatches() {
        var matcher = RoadLimitMatcher()
        let eastbound = road(id: "a", limitKph: 90, bearing: 90)

        let match = matcher.update(fix: fix(alongMeters: 500, course: 270), candidates: [eastbound])
        XCTAssertEqual(match?.road.id, "a")
    }

    func testAFixWithNoCourseStillMatches() {
        var matcher = RoadLimitMatcher()
        // Stopped at a light: the receiver reports no course, and blanking the
        // limit every time the car stopped would be its own bug.
        let match = matcher.update(fix: fix(alongMeters: 500, course: nil), candidates: [road(id: "a", limitKph: 90)])
        XCTAssertEqual(match?.road.id, "a")
    }

    // MARK: - Hysteresis

    /// The motorway-and-service-road case: two roads a driver could plausibly be
    /// on, with different limits, close enough for noise to swap them.
    func testASingleStrayFixDoesNotChangeRoads() {
        var matcher = RoadLimitMatcher()
        let motorway = road(id: "motorway", limitKph: 130)
        let serviceRoad = road(id: "service", limitKph: 50, offsetMeters: 25)
        let candidates = [motorway, serviceRoad]

        XCTAssertEqual(matcher.update(fix: fix(alongMeters: 100), candidates: candidates)?.road.id, "motorway")

        // One fix that lands nearer the service road, as GPS routinely does.
        let strayed = matcher.update(fix: fix(alongMeters: 200, offsetMeters: 20), candidates: candidates)
        XCTAssertEqual(strayed?.road.id, "motorway", "one bad fix must not swap the limit")

        XCTAssertEqual(matcher.update(fix: fix(alongMeters: 300), candidates: candidates)?.road.id, "motorway")
    }

    func testASustainedChangeOfRoadIsAdopted() {
        var matcher = RoadLimitMatcher()
        let motorway = road(id: "motorway", limitKph: 130)
        let serviceRoad = road(id: "service", limitKph: 50, offsetMeters: 25)
        let candidates = [motorway, serviceRoad]

        _ = matcher.update(fix: fix(alongMeters: 100), candidates: candidates)

        // Genuinely moved across onto the service road and stayed there.
        _ = matcher.update(fix: fix(alongMeters: 200, offsetMeters: 24), candidates: candidates)
        let settled = matcher.update(fix: fix(alongMeters: 300, offsetMeters: 25), candidates: candidates)

        XCTAssertEqual(settled?.road.id, "service")
        XCTAssertEqual(settled?.limitKph, 50)
    }

    func testTheFirstRoadOfAJourneyIsTakenImmediately() {
        var matcher = RoadLimitMatcher()
        // Nothing to flap away from, so waiting for confirmation would only
        // delay the first limit for no benefit.
        XCTAssertNotNil(matcher.update(fix: fix(alongMeters: 0), candidates: [road(id: "a", limitKph: 90)]))
    }

    func testTheLimitIsHeldThroughABriefLossOfMatchAndThenDropped() {
        var matcher = RoadLimitMatcher()
        let candidates = [road(id: "a", limitKph: 90)]
        _ = matcher.update(fix: fix(alongMeters: 100), candidates: candidates)

        // A tunnel, a cutting, a fix that landed in a field. Holding the limit
        // through it beats blanking the roundel and putting it back.
        XCTAssertEqual(matcher.update(fix: fix(alongMeters: 200), candidates: [])?.road.id, "a")
        XCTAssertEqual(matcher.update(fix: fix(alongMeters: 300), candidates: [])?.road.id, "a")
        XCTAssertEqual(matcher.update(fix: fix(alongMeters: 400), candidates: [])?.road.id, "a")

        // Four in a row is no longer a glitch: the driver has left the road.
        XCTAssertNil(matcher.update(fix: fix(alongMeters: 500), candidates: []))
    }

    // MARK: - Directional limits

    func testForwardAndBackwardLimitsFollowTheDirectionOfTravel() {
        var eastbound = RoadLimitMatcher()
        var westbound = RoadLimitMatcher()
        let asymmetric = [road(id: "a", limitKph: 90, forward: 110, backward: 70)]

        XCTAssertEqual(
            eastbound.update(fix: fix(alongMeters: 500, course: 90), candidates: asymmetric)?.limitKph,
            110
        )
        XCTAssertEqual(
            westbound.update(fix: fix(alongMeters: 500, course: 270), candidates: asymmetric)?.limitKph,
            70
        )
    }

    /// With no course there is no way to pick a side, and the fallback is the
    /// higher of the two on purpose: a silence is a smaller failure than telling
    /// a driver they are over a limit that does not apply to their carriageway.
    func testAnUnknownDirectionFallsBackToTheBaseLimit() {
        var matcher = RoadLimitMatcher()
        let asymmetric = [road(id: "a", limitKph: 90, forward: 110, backward: 70)]

        XCTAssertEqual(
            matcher.update(fix: fix(alongMeters: 500, course: nil), candidates: asymmetric)?.limitKph,
            90
        )
    }

    func testNearestInsideTheCorridorWins() {
        var matcher = RoadLimitMatcher()
        let near = road(id: "near", limitKph: 90, offsetMeters: 2)
        let alsoClose = road(id: "alsoClose", limitKph: 50, offsetMeters: 22)

        XCTAssertEqual(
            matcher.update(fix: fix(alongMeters: 500), candidates: [alsoClose, near])?.road.id,
            "near"
        )
    }

    func testResetForgetsTheCurrentRoad() {
        var matcher = RoadLimitMatcher()
        _ = matcher.update(fix: fix(alongMeters: 100), candidates: [road(id: "a", limitKph: 90)])
        XCTAssertNotNil(matcher.current)

        matcher.reset()
        XCTAssertNil(matcher.current)
    }
}
