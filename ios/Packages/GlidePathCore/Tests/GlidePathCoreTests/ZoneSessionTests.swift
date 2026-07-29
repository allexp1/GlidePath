import XCTest
@testable import GlidePathCore

/// End-to-end drives through the state machine. Each one is a scenario from the
/// product brief rather than a unit of code.
final class ZoneSessionTests: XCTestCase {

    // MARK: - The happy path

    func testACleanDriveCompletesAndPasses() {
        let zone = TestFixtures.zone(lengthMeters: 10_000, limitKph: 100)
        let result = TestFixtures.drive(zone, steps: [.drive(speedKph: 95, distanceMeters: 10_000)])

        guard let outcome = result.outcome else {
            return XCTFail("expected the session to reach the exit camera")
        }
        XCTAssertTrue(outcome.passed)
        XCTAssertEqual(outcome.averageKph, 95, accuracy: 1.0)
        XCTAssertGreaterThan(outcome.marginSeconds, 0, "driving under the limit should leave time in hand")
    }

    /// The regression test for a real bug: a driver holding exactly the posted
    /// limit was being coached to slow down.
    ///
    /// Hold the limit exactly and the allowance works out to exactly the limit
    /// at every single point in the zone. Comparing it to the limit without any
    /// slack therefore lands on a knife edge, and the tier flipped on
    /// floating-point noise, producing "hold 95" at a driver doing a perfectly
    /// legal 100. Over a whole zone that is the app nagging someone who is
    /// doing nothing wrong, which is worse than saying nothing at all.
    func testHoldingExactlyTheLimitIsNeverCoachedToSlowDown() {
        let zone = TestFixtures.zone(lengthMeters: 10_000, limitKph: 100)
        let result = TestFixtures.drive(zone, steps: [.drive(speedKph: 100, distanceMeters: 10_000)])

        XCTAssertFalse(
            result.tiers.contains(.tight),
            "a driver holding the posted limit must never be told to slow down"
        )
        XCTAssertFalse(result.tiers.contains(.impossible))
        XCTAssertTrue(result.tiers.allSatisfy { $0 == .normal })

        for advice in result.advice {
            XCTAssertEqual(advice.targetSpeedKph, 100)
        }
    }

    /// The entry clock must start at the entry line, not at the geofence
    /// wake-up several hundred metres earlier. Starting early inflates elapsed
    /// time, which inflates the allowance, which coaches the driver too fast.
    func testEntryIsTimestampedAtTheLineNotAtTheWakeUp() {
        let zone = TestFixtures.zone(lengthMeters: 10_000, limitKph: 100)
        let options = DriveSimulator.Options(leadInMeters: 300)
        let result = TestFixtures.drive(
            zone,
            steps: [.drive(speedKph: 100, distanceMeters: 10_000)],
            options: options
        )

        guard let entered = result.enteredAt else {
            return XCTFail("expected an entry event")
        }
        // 300 m of lead-in at 100 km/h is 10.8 seconds.
        let expected = TestFixtures.referenceDate.addingTimeInterval(10.8)
        XCTAssertEqual(entered.timeIntervalSince1970, expected.timeIntervalSince1970, accuracy: 0.4)
    }

    // MARK: - Early speeder recovery

    /// The headline scenario. Blow the budget early, get coached down, come out
    /// legal.
    func testEarlySpeederIsCoachedBackUnderTheLimit() {
        let zone = TestFixtures.zone(lengthMeters: 10_000, limitKph: 100)
        let result = TestFixtures.drive(zone, steps: [
            .drive(speedKph: 130, distanceMeters: 5_000),
            .drive(speedKph: 80, distanceMeters: 5_000)
        ])

        guard let outcome = result.outcome else {
            return XCTFail("expected the session to reach the exit camera")
        }
        XCTAssertTrue(result.tiers.contains(.tight), "speeding early must produce tight coaching")
        XCTAssertTrue(outcome.passed, "holding the coached speed must land under the limit")
        XCTAssertEqual(outcome.averageKph, 99.05, accuracy: 0.6)
        XCTAssertEqual(result.tiers.last, .normal, "the driver should be told they are safe again")
    }

    /// The coached number has to be one the driver can actually hold. Take the
    /// first tight instruction, obey it exactly, and the section must pass.
    func testObeyingTheFirstTightInstructionIsEnoughToPass() {
        let zone = TestFixtures.zone(lengthMeters: 10_000, limitKph: 100)
        let probe = TestFixtures.drive(zone, steps: [
            .drive(speedKph: 140, distanceMeters: 4_000),
            .drive(speedKph: 60, distanceMeters: 6_000)
        ])

        let pastTheSprint = probe.advice.first {
            $0.tier == .tight && $0.allowance.distanceCoveredMeters > 3_900
        }
        guard let firstTight = pastTheSprint, let target = firstTight.targetSpeedKph else {
            return XCTFail("expected tight coaching after a 4 km sprint at 140")
        }

        let remaining = zone.distanceMeters - firstTight.allowance.distanceCoveredMeters
        let result = TestFixtures.drive(zone, steps: [
            .drive(speedKph: 140, distanceMeters: firstTight.allowance.distanceCoveredMeters),
            .drive(speedKph: target, distanceMeters: remaining)
        ])

        guard let outcome = result.outcome else {
            return XCTFail("expected the session to reach the exit camera")
        }
        XCTAssertTrue(
            outcome.passed,
            "coached \(target) km/h but averaged \(outcome.averageKph) against a \(zone.speedLimitKph) limit"
        )
    }

    // MARK: - Traffic

    /// Sitting in a jam is not speeding. Coaching goes quiet, and the stopped
    /// time hands the allowance straight back.
    func testTrafficJamSuppressesCoachingAndThenRestoresTheAllowance() {
        let zone = TestFixtures.zone(lengthMeters: 10_000, limitKph: 100)
        let result = TestFixtures.drive(zone, steps: [
            .drive(speedKph: 130, distanceMeters: 5_000),
            .stop(seconds: 120),
            .drive(speedKph: 100, distanceMeters: 5_000)
        ])

        guard let outcome = result.outcome else {
            return XCTFail("expected the session to reach the exit camera")
        }

        XCTAssertTrue(
            result.advice.contains { $0.isSuppressed },
            "a stationary car must not be given a target speed"
        )
        XCTAssertTrue(
            result.advice.contains { $0.isSuppressed && $0.targetSpeedKph == nil },
            "suppressed advice must carry no spoken number"
        )
        XCTAssertEqual(result.tiers.last, .normal, "the jam should have handed the allowance back")
        XCTAssertTrue(outcome.passed)
        XCTAssertEqual(outcome.averageKph, 82.1, accuracy: 1.5)
    }

    // MARK: - GPS quality

    /// Lateral GPS noise must not move the answer. This is the payoff for
    /// measuring progress by projection onto the road rather than by summing
    /// point-to-point hops, which would integrate the noise into the odometer.
    func testLateralGpsJitterDoesNotChangeTheOutcome() {
        let zone = TestFixtures.zone(lengthMeters: 10_000, limitKph: 100)
        let steps: [DriveSimulator.Step] = [
            .drive(speedKph: 130, distanceMeters: 5_000),
            .drive(speedKph: 80, distanceMeters: 5_000)
        ]

        let clean = TestFixtures.drive(zone, steps: steps)
        let noisy = TestFixtures.drive(
            zone,
            steps: steps,
            options: DriveSimulator.Options(jitterMeters: 25)
        )

        guard let cleanOutcome = clean.outcome, let noisyOutcome = noisy.outcome else {
            return XCTFail("both drives should reach the exit camera")
        }
        XCTAssertEqual(noisyOutcome.averageKph, cleanOutcome.averageKph, accuracy: 0.75)
        XCTAssertEqual(noisy.tiers.last, clean.tiers.last)
    }

    func testFixesTooInaccurateToTrustAreIgnored() {
        let zone = TestFixtures.zone(lengthMeters: 10_000, limitKph: 100)
        guard var session = ZoneSession(zone: zone) else {
            return XCTFail("expected a driveable zone")
        }

        let junk = LocationFix(
            coordinate: zone.entry,
            timestamp: TestFixtures.referenceDate,
            speedMps: 25,
            horizontalAccuracy: 250
        )
        XCTAssertTrue(session.ingest(junk).isEmpty)
        XCTAssertEqual(session.state, .armed)
    }

    // MARK: - Deviation

    /// One bad fix is normal. Under a bridge, beside a building, on
    /// re-acquisition. It must not end the session.
    func testASingleOffPathFixDoesNotCancelTheSession() {
        let zone = TestFixtures.zone(lengthMeters: 10_000, limitKph: 100)
        var fixes = TestFixtures.fixes(for: zone, steps: [.drive(speedKph: 90, distanceMeters: 10_000)])

        let index = fixes.count / 2
        fixes[index] = LocationFix(
            coordinate: fixes[index].coordinate.offset(meters: 300, bearingDegrees: 0),
            timestamp: fixes[index].timestamp,
            speedMps: fixes[index].speedMps,
            horizontalAccuracy: fixes[index].horizontalAccuracy,
            courseDegrees: fixes[index].courseDegrees
        )

        let result = TestFixtures.run(zone, fixes: fixes)
        XCTAssertNil(result.abandonReason, "a single stray fix must not cancel a session")
        XCTAssertNotNil(result.outcome)
    }

    /// Sustained divergence is a real turn-off, and the session should end.
    func testSustainedDivergenceCancelsTheSession() {
        let zone = TestFixtures.zone(lengthMeters: 10_000, limitKph: 100)
        var fixes = TestFixtures.fixes(for: zone, steps: [.drive(speedKph: 90, distanceMeters: 10_000)])

        // From half way, peel steadily away from the road for the next 20 fixes.
        let start = fixes.count / 2
        for offset in 0..<20 where start + offset < fixes.count {
            let index = start + offset
            let sideways = 40.0 + Double(offset) * 25
            fixes[index] = LocationFix(
                coordinate: fixes[index].coordinate.offset(meters: sideways, bearingDegrees: 0),
                timestamp: fixes[index].timestamp,
                speedMps: fixes[index].speedMps,
                horizontalAccuracy: fixes[index].horizontalAccuracy,
                courseDegrees: fixes[index].courseDegrees
            )
        }

        let result = TestFixtures.run(zone, fixes: fixes)
        XCTAssertEqual(result.abandonReason, .leftTheRoad)
        XCTAssertNil(result.outcome, "a cancelled session must not report an outcome")
    }

    // MARK: - Guards

    func testAZoneWithNoLengthCannotStartASession() {
        let broken = Zone(
            id: "broken",
            countryCode: "IL",
            entry: TestFixtures.origin,
            exit: TestFixtures.origin,
            distanceMeters: 0,
            speedLimitKph: 100
        )
        XCTAssertNil(ZoneSession(zone: broken))
    }

    func testAFinishedSessionIgnoresFurtherFixes() {
        let zone = TestFixtures.zone(lengthMeters: 10_000, limitKph: 100)
        guard var session = ZoneSession(zone: zone) else {
            return XCTFail("expected a driveable zone")
        }
        session.abandon(.cancelled)

        let fix = LocationFix(
            coordinate: zone.entry,
            timestamp: TestFixtures.referenceDate,
            speedMps: 25
        )
        XCTAssertTrue(session.ingest(fix).isEmpty)
        XCTAssertEqual(session.state, .abandoned(.cancelled))
    }
}
