import XCTest
@testable import ZonexploCore

/// The allowance is the whole product in one equation. These tests pin down its
/// behaviour with numbers worked out by hand.
final class AllowanceTests: XCTestCase {
    private let zone = TestFixtures.zone(lengthMeters: 10_000, limitKph: 100)

    func testMinimumLegalTimeIsDistanceOverLimit() {
        // 10 km at 100 km/h is 360 seconds exactly.
        XCTAssertEqual(zone.minimumLegalSeconds, 360, accuracy: 0.001)
    }

    func testAtEntryTheAllowanceIsExactlyTheLimit() {
        let allowance = AllowanceCalculator.compute(zone: zone, distanceCovered: 0, elapsed: 0)
        XCTAssertEqual(allowance.maxRemainingAverageKph ?? 0, 100, accuracy: 0.001)
        XCTAssertEqual(allowance.remainingTimeBudgetSeconds, 360, accuracy: 0.001)
    }

    func testDrivingAtTheLimitKeepsTheAllowanceAtTheLimit() {
        // Half way through, on time.
        let allowance = AllowanceCalculator.compute(zone: zone, distanceCovered: 5_000, elapsed: 180)
        XCTAssertEqual(allowance.currentAverageKph, 100, accuracy: 0.001)
        XCTAssertEqual(allowance.maxRemainingAverageKph ?? 0, 100, accuracy: 0.001)
    }

    /// The counterintuitive core of the design: overspending time early leaves a
    /// large unspent budget over a short remaining distance, which forces a low
    /// allowance. This is the driver who has to dawdle.
    func testSpeedingEarlyCollapsesTheAllowance() {
        // 9 km covered in 216 s, which is 150 km/h.
        let allowance = AllowanceCalculator.compute(zone: zone, distanceCovered: 9_000, elapsed: 216)

        XCTAssertEqual(allowance.currentAverageKph, 150, accuracy: 0.01)
        XCTAssertEqual(allowance.remainingTimeBudgetSeconds, 144, accuracy: 0.001)
        // 1000 m must now take 144 s, which is 25 km/h.
        XCTAssertEqual(allowance.maxRemainingAverageKph ?? 0, 25, accuracy: 0.01)
    }

    /// Going slowly banks time. Once total elapsed passes the minimum legal
    /// time, the exit camera can no longer catch the driver whatever they do.
    func testDrivingSlowlyBanksTimeAndRemovesTheConstraint() {
        let allowance = AllowanceCalculator.compute(zone: zone, distanceCovered: 5_000, elapsed: 400)

        XCTAssertTrue(allowance.isBanked)
        XCTAssertNil(allowance.maxRemainingAverageKph, "a banked budget imposes no constraint")
        XCTAssertLessThan(allowance.remainingTimeBudgetSeconds, 0)
    }

    /// Sitting still increases the allowance, because the clock advances while
    /// the odometer does not.
    func testStoppingIncreasesTheAllowance() {
        let before = AllowanceCalculator.compute(zone: zone, distanceCovered: 6_000, elapsed: 180)
        let after = AllowanceCalculator.compute(zone: zone, distanceCovered: 6_000, elapsed: 240)

        guard let beforeAllowance = before.maxRemainingAverageKph,
              let afterAllowance = after.maxRemainingAverageKph else {
            return XCTFail("expected both allowances to still be constrained")
        }
        XCTAssertGreaterThan(afterAllowance, beforeAllowance)
    }

    func testProjectedFinalAverageWarnsBeforeTheExit() {
        // Sped early: holding the limit from here still lands over.
        let allowance = AllowanceCalculator.compute(zone: zone, distanceCovered: 9_000, elapsed: 216)
        // 216 s + 1000/27.78 = 252 s for 10 km, which is about 142.9 km/h.
        XCTAssertEqual(allowance.projectedFinalAverageKph, 142.86, accuracy: 0.1)
        XCTAssertGreaterThan(allowance.projectedFinalAverageKph, zone.speedLimitKph)
    }

    func testInputsAreClampedRatherThanTrusted() {
        let overshoot = AllowanceCalculator.compute(zone: zone, distanceCovered: 99_999, elapsed: 100)
        XCTAssertEqual(overshoot.distanceCoveredMeters, 10_000, accuracy: 0.001)
        XCTAssertEqual(overshoot.distanceRemainingMeters, 0, accuracy: 0.001)
        XCTAssertNil(overshoot.maxRemainingAverageKph)

        let negative = AllowanceCalculator.compute(zone: zone, distanceCovered: -500, elapsed: -10)
        XCTAssertEqual(negative.distanceCoveredMeters, 0, accuracy: 0.001)
        XCTAssertEqual(negative.elapsedSeconds, 0, accuracy: 0.001)
    }
}
