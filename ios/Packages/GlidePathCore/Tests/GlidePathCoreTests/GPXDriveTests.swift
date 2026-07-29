import XCTest
@testable import GlidePathCore

/// Replays a recorded track through the engine, which is the closest thing to a
/// real drive that runs in CI. Regenerate the fixture with
/// `node scripts/generate-test-gpx.mjs`.
final class GPXDriveTests: XCTestCase {

    /// The zone the fixture was generated against: 6 km due east from
    /// 32.0/34.8, limit 90 km/h.
    private func fixtureZone(restStops: [RestStop] = []) -> Zone {
        let path = TestFixtures.straightPath(lengthMeters: 6_000)
        return Zone(
            id: "gpx-zone",
            countryCode: "IL",
            name: "GPX Test Section",
            roadRef: "Route 6",
            entry: path.start,
            exit: path.end,
            distanceMeters: path.totalDistance,
            speedLimitKph: 90,
            directionDegrees: 90,
            path: path,
            restStops: restStops
        )
    }

    private func loadTrack() throws -> GPXTrack {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "test_zone_drive", withExtension: "gpx", subdirectory: "Fixtures"),
            "GPX fixture is missing from the test bundle"
        )
        return try GPXTrack(gpx: try String(contentsOf: url, encoding: .utf8))
    }

    func testFixtureParsesIntoUsableFixes() throws {
        let track = try loadTrack()

        XCTAssertGreaterThan(track.fixes.count, 200)
        XCTAssertTrue(track.fixes.allSatisfy { $0.horizontalAccuracy > 0 })
        XCTAssertTrue(track.fixes.allSatisfy { ($0.speedMps ?? -1) > 0 })

        // Timestamps must be strictly increasing, or every duration is a lie.
        for index in 1..<track.fixes.count {
            XCTAssertGreaterThan(
                track.fixes[index].timestamp,
                track.fixes[index - 1].timestamp
            )
        }
    }

    /// The full journey the product exists for: enter, get told you are over,
    /// get a number to hold, hold it, come out clean.
    func testSimulatedDriveCoachesThroughTheTiersAndPasses() throws {
        let track = try loadTrack()
        let zone = fixtureZone()
        let result = TestFixtures.run(zone, fixes: track.fixes)

        guard let outcome = result.outcome else {
            return XCTFail("the recorded drive should reach the exit camera")
        }

        XCTAssertNotNil(result.enteredAt)
        XCTAssertTrue(result.tiers.contains(.tight), "3 km at 120 in a 90 zone must produce tight coaching")
        XCTAssertEqual(outcome.averageKph, 88.4, accuracy: 1.0)
        XCTAssertTrue(outcome.passed)
        XCTAssertGreaterThan(outcome.marginSeconds, 0)
    }

    /// The coached number in the middle of the zone must be the one the driver
    /// then actually holds in the second half of the fixture.
    func testTheCoachedSpeedMatchesWhatSavesTheDrive() throws {
        let track = try loadTrack()
        let zone = fixtureZone()
        let result = TestFixtures.run(zone, fixes: track.fixes)

        let midZone = result.advice.first {
            $0.allowance.distanceCoveredMeters > 2_950 && $0.tier == .tight
        }
        guard let midZone, let target = midZone.targetSpeedKph else {
            return XCTFail("expected tight coaching at the half way point")
        }
        XCTAssertEqual(target, 70, "half way through, 70 km/h is what lands under a 90 average")
    }

    /// Every spoken line across a whole drive has to be well formed. This is the
    /// cheapest guard against a phrasing change that produces "Hold ." at 120.
    func testEverySpokenLineIsWellFormed() throws {
        let track = try loadTrack()
        let zone = fixtureZone()
        let result = TestFixtures.run(zone, fixes: track.fixes)
        let phrasebook = Phrasebook(units: .metric)

        var spoken = 0
        for advice in result.advice {
            guard let line = phrasebook.coaching(advice) else { continue }
            spoken += 1
            XCTAssertFalse(line.isEmpty)
            XCTAssertTrue(line.hasSuffix("."), "\(line) should be a complete sentence")
            XCTAssertFalse(line.contains("  "), "\(line) has a doubled space")
            XCTAssertFalse(line.contains(" ."), "\(line) has a dangling number")
        }
        XCTAssertGreaterThan(spoken, 0)
    }

    /// GPS noise on a real recording must not change the verdict either.
    func testReplayIsStableUnderAddedNoise() throws {
        let track = try loadTrack()
        let zone = fixtureZone()

        let clean = TestFixtures.run(zone, fixes: track.fixes)
        let noisy = TestFixtures.run(zone, fixes: jitter(track.fixes, meters: 20))

        guard let cleanOutcome = clean.outcome, let noisyOutcome = noisy.outcome else {
            return XCTFail("both replays should reach the exit camera")
        }
        XCTAssertEqual(noisyOutcome.averageKph, cleanOutcome.averageKph, accuracy: 1.0)
        XCTAssertEqual(noisyOutcome.passed, cleanOutcome.passed)
    }

    /// Deterministic lateral noise, alternating side to side so it cannot be
    /// mistaken for a genuine departure from the road.
    private func jitter(_ fixes: [LocationFix], meters: Double) -> [LocationFix] {
        fixes.enumerated().map { index, fix in
            let bearing: Double = index.isMultiple(of: 2) ? 0 : 180
            let magnitude = meters * (0.4 + Double(index % 5) / 5.0)
            return LocationFix(
                coordinate: fix.coordinate.offset(meters: magnitude, bearingDegrees: bearing),
                timestamp: fix.timestamp,
                speedMps: fix.speedMps,
                horizontalAccuracy: fix.horizontalAccuracy,
                courseDegrees: fix.courseDegrees
            )
        }
    }
}
