import XCTest
@testable import ZonexploCore

final class CoachingTierTests: XCTestCase {
    private let engine = CoachingEngine(policy: .standard)

    private func advice(
        zone: Zone,
        covered: Double,
        elapsed: TimeInterval,
        smoothedKph: Double? = 90
    ) -> CoachingAdvice {
        let allowance = AllowanceCalculator.compute(zone: zone, distanceCovered: covered, elapsed: elapsed)
        return engine.advise(zone: zone, allowance: allowance, smoothedSpeedKph: smoothedKph)
    }

    // MARK: - Tier selection

    func testNormalTierCoachesTheLimit() {
        let zone = TestFixtures.zone(lengthMeters: 10_000, limitKph: 100)
        let result = advice(zone: zone, covered: 5_000, elapsed: 180)

        XCTAssertEqual(result.tier, .normal)
        XCTAssertEqual(result.targetSpeedKph, 100)
        XCTAssertNil(result.recovery)
    }

    func testBankedTimeStillCoachesTheLimitNotSomethingFaster() {
        let zone = TestFixtures.zone(lengthMeters: 10_000, limitKph: 100)
        // Crawled the first half: the camera can no longer catch them.
        let result = advice(zone: zone, covered: 5_000, elapsed: 500)

        XCTAssertEqual(result.tier, .normal)
        XCTAssertEqual(result.targetSpeedKph, 100, "never coach above the posted limit, banked or not")
    }

    func testTightTierCoachesTheRecoverableSpeed() {
        let zone = TestFixtures.zone(lengthMeters: 10_000, limitKph: 100)
        // 5 km at 130 km/h takes 138.46 s, leaving 221.54 s for 5 km = 81.3 km/h.
        let result = advice(zone: zone, covered: 5_000, elapsed: 138.46)

        XCTAssertEqual(result.tier, .tight)
        // Rounded down to a number a driver can hold, never up.
        XCTAssertEqual(result.targetSpeedKph, 80)
        XCTAssertNil(result.recovery)
    }

    func testTargetIsRoundedDownSoItIsNeverAboveTheTrueAllowance() {
        let zone = TestFixtures.zone(lengthMeters: 10_000, limitKph: 100)
        let result = advice(zone: zone, covered: 5_000, elapsed: 138.46)

        guard let allowance = result.allowance.maxRemainingAverageKph,
              let target = result.targetSpeedKph else {
            return XCTFail("expected a constrained tight-tier advice")
        }
        XCTAssertLessThanOrEqual(target, allowance, "a rounded-up target would coach the driver into a fine")
    }

    func testImpossibleTierTriggersBelowTheFloor() {
        let zone = TestFixtures.zone(lengthMeters: 10_000, limitKph: 100)
        // 9 km at 150 km/h. The remaining km would have to be driven at 25 km/h.
        let result = advice(zone: zone, covered: 9_000, elapsed: 216)

        XCTAssertEqual(result.tier, .impossible)
        XCTAssertNotNil(result.recovery)
    }

    // MARK: - The safety floor

    func testFloorIsHalfTheLimitOnAFastRoad() {
        let zone = TestFixtures.zone(limitKph: 110)
        XCTAssertEqual(SafetyPolicy.standard.coachingFloorKph(for: zone), 55, accuracy: 0.001)
    }

    func testFloorRespectsAPostedLegalMinimum() {
        let zone = TestFixtures.zone(limitKph: 110, minimumSpeedKph: 70)
        XCTAssertEqual(SafetyPolicy.standard.coachingFloorKph(for: zone), 70, accuracy: 0.001)
    }

    func testAbsoluteFloorAppliesOnSlowRoads() {
        let zone = TestFixtures.zone(limitKph: 50)
        // Half of 50 is 25, below the 30 km/h absolute floor.
        XCTAssertEqual(SafetyPolicy.standard.coachingFloorKph(for: zone), 30, accuracy: 0.001)
    }

    func testFloorNeverExceedsTheLimitItself() {
        let zone = TestFixtures.zone(limitKph: 20)
        XCTAssertEqual(
            SafetyPolicy.standard.coachingFloorKph(for: zone), 20, accuracy: 0.001,
            "a floor above the limit would coach the driver to speed"
        )
    }

    /// The hard safety rule, swept across the whole space rather than spot
    /// checked. Zonexplo must never ask for a dangerous crawl, no matter how
    /// badly the driver has blown the budget.
    func testNoAdviceIsEverBelowTheSafetyFloor() {
        for limit in [30.0, 50, 70, 80, 90, 100, 110, 130] {
            let zone = TestFixtures.zone(lengthMeters: 10_000, limitKph: limit)
            let floor = SafetyPolicy.standard.coachingFloorKph(for: zone)

            for coveredStep in stride(from: 0.0, through: 9_900, by: 300) {
                for elapsed in stride(from: 1.0, through: 900, by: 25) {
                    let result = advice(zone: zone, covered: coveredStep, elapsed: elapsed)
                    guard let target = result.targetSpeedKph else { continue }
                    XCTAssertGreaterThanOrEqual(
                        target, floor,
                        "limit \(limit), covered \(coveredStep) m, elapsed \(elapsed) s produced \(target)"
                    )
                    XCTAssertLessThanOrEqual(target, limit, "never coach above the posted limit")
                }
            }
        }
    }

    // MARK: - Recovery

    func testImpossibleTierDirectsToARestStopAhead() {
        let base = TestFixtures.zone(lengthMeters: 10_000, limitKph: 100)
        let stop = TestFixtures.restStop(at: 9_000, in: base)
        let zone = TestFixtures.zone(lengthMeters: 10_000, limitKph: 100, restStops: [stop])

        // 8 km in 180 s is 160 km/h. The last 2 km would have to be driven at
        // 40 km/h, below the 50 km/h floor for a 100 km/h road.
        let result = advice(zone: zone, covered: 8_000, elapsed: 180)

        XCTAssertEqual(result.tier, .impossible)
        guard case let .pause(seconds, restStop, distanceToStop)? = result.recovery else {
            return XCTFail("expected a pause recovery, got \(String(describing: result.recovery))")
        }
        // 180 s of budget minus the 72 s the last 2 km take at the limit.
        XCTAssertEqual(seconds, 108, accuracy: 0.5)
        XCTAssertGreaterThan(seconds, 0, "an impossible tier always needs a strictly positive pause")
        XCTAssertEqual(restStop.id, stop.id)
        XCTAssertEqual(distanceToStop, 1_000, accuracy: 1)
    }

    func testARestStopTooCloseToReactToIsNotOffered() {
        let base = TestFixtures.zone(lengthMeters: 10_000, limitKph: 100)
        // 100 m ahead: the driver would be past it before the sentence finished.
        let stop = TestFixtures.restStop(at: 8_100, in: base)
        let zone = TestFixtures.zone(lengthMeters: 10_000, limitKph: 100, restStops: [stop])

        let result = advice(zone: zone, covered: 8_000, elapsed: 180)
        guard case .unrecoverable? = result.recovery else {
            return XCTFail("a stop 100 m ahead is not something a driver can act on")
        }
    }

    func testImpossibleTierIsHonestWhenThereIsNowhereToStop() {
        let zone = TestFixtures.zone(lengthMeters: 10_000, limitKph: 100)
        let result = advice(zone: zone, covered: 9_000, elapsed: 216)

        XCTAssertEqual(result.tier, .impossible)
        guard case .unrecoverable? = result.recovery else {
            return XCTFail("expected an honest unrecoverable verdict, got \(String(describing: result.recovery))")
        }
    }

    func testRestStopsAlreadyBehindTheDriverAreNotOffered() {
        let base = TestFixtures.zone(lengthMeters: 10_000, limitKph: 100)
        let stop = TestFixtures.restStop(at: 2_000, in: base)
        let zone = TestFixtures.zone(lengthMeters: 10_000, limitKph: 100, restStops: [stop])

        let result = advice(zone: zone, covered: 9_000, elapsed: 216)
        guard case .unrecoverable? = result.recovery else {
            return XCTFail("a stop 7 km behind the driver is not a recovery option")
        }
    }

    /// The pause figure has to actually work. Taking it and then driving the
    /// rest at the limit must land the driver at or under the average.
    func testTheOfferedPauseIsLongEnoughToWork() {
        let base = TestFixtures.zone(lengthMeters: 10_000, limitKph: 100)
        let stop = TestFixtures.restStop(at: 9_000, in: base)
        let zone = TestFixtures.zone(lengthMeters: 10_000, limitKph: 100, restStops: [stop])

        let result = advice(zone: zone, covered: 8_000, elapsed: 180)
        guard case let .pause(seconds, _, _)? = result.recovery else {
            return XCTFail("expected a pause recovery")
        }

        let remaining = zone.distanceMeters - 8_000
        let drivingTime = remaining / Units.mps(fromKph: zone.speedLimitKph)
        let totalTime = 180 + seconds + drivingTime
        let finalAverage = Units.kph(fromMps: zone.distanceMeters / totalTime)

        XCTAssertLessThanOrEqual(finalAverage, zone.speedLimitKph + 0.001)
    }

    // MARK: - Jam suppression

    func testCoachingIsSuppressedInStopStartTraffic() {
        let zone = TestFixtures.zone(lengthMeters: 10_000, limitKph: 100)
        let result = advice(zone: zone, covered: 5_000, elapsed: 138.46, smoothedKph: 4)

        XCTAssertTrue(result.isSuppressed)
        XCTAssertNil(result.targetSpeedKph, "a target speed is noise when the driver cannot move")
        XCTAssertEqual(result.tier, .tight, "the tier is still computed, only the speaking stops")
    }

    /// A receiver that withholds speed must not be read as a stationary car, or
    /// coaching would go silent for the whole drive.
    func testUnknownSpeedIsNotTreatedAsStationary() {
        let zone = TestFixtures.zone(lengthMeters: 10_000, limitKph: 100)
        let result = advice(zone: zone, covered: 5_000, elapsed: 180, smoothedKph: nil)

        XCTAssertFalse(result.isSuppressed)
        XCTAssertEqual(result.targetSpeedKph, 100)
    }
}
