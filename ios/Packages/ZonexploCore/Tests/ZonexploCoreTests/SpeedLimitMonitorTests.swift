import XCTest
@testable import ZonexploCore

/// Every test here is about *not* speaking. The detection is arithmetic; the
/// product is the silence around it.
final class SpeedLimitMonitorTests: XCTestCase {
    private let now = TestFixtures.referenceDate

    private func fix(speedKph: Double, secondsIn: TimeInterval) -> LocationFix {
        LocationFix(
            coordinate: TestFixtures.origin,
            timestamp: now.addingTimeInterval(secondsIn),
            speedMps: Units.mps(fromKph: speedKph),
            horizontalAccuracy: 5,
            courseDegrees: 90
        )
    }

    /// Feeds a steady speed for `seconds` at 1 Hz and returns everything spoken.
    private func hold(
        _ speedKph: Double,
        limitKph: Double?,
        seconds: Int,
        from start: TimeInterval = 0,
        into monitor: inout SpeedLimitMonitor
    ) -> [SpeedLimitMonitor.Exceedance] {
        var spoken: [SpeedLimitMonitor.Exceedance] = []
        for second in 0..<seconds {
            if let exceedance = monitor.update(
                fix: fix(speedKph: speedKph, secondsIn: start + Double(second)),
                limitKph: limitKph
            ) {
                spoken.append(exceedance)
            }
        }
        return spoken
    }

    // MARK: - Tolerance

    func testDrivingAtTheLimitSaysNothing() {
        var monitor = SpeedLimitMonitor()
        XCTAssertTrue(hold(90, limitKph: 90, seconds: 30, into: &monitor).isEmpty)
    }

    /// Speedometers over-read by regulation, so a driver a few km/h over
    /// genuinely believes they are legal. Alerting there is how the feature
    /// gets switched off in week one.
    func testASmallOverspeedIsWithinTheAllowance() {
        var monitor = SpeedLimitMonitor()
        XCTAssertTrue(hold(95, limitKph: 90, seconds: 30, into: &monitor).isEmpty)
    }

    func testTheAllowanceGrowsWithTheLimit() {
        let thresholds = SpeedLimitMonitor.Thresholds.standard
        // Absolute floor on ordinary roads.
        XCTAssertEqual(thresholds.allowance(for: 50), 7, accuracy: 0.001)
        // Proportional once the limit is high enough for 7 to be trivial.
        XCTAssertEqual(thresholds.allowance(for: 130), 10.4, accuracy: 0.001)
    }

    func testAClearOverspeedIsAnnounced() {
        var monitor = SpeedLimitMonitor()
        let spoken = hold(110, limitKph: 90, seconds: 10, into: &monitor)

        XCTAssertEqual(spoken.count, 1)
        XCTAssertEqual(spoken.first?.limitKph, 90)
        XCTAssertEqual(spoken.first?.overByKph ?? 0, 20, accuracy: 0.01)
    }

    // MARK: - Sustained

    /// Overtaking. Over the tolerance, back under before it means anything.
    func testABriefOvershootIsNotAnnounced() {
        var monitor = SpeedLimitMonitor()
        XCTAssertTrue(hold(110, limitKph: 90, seconds: 3, into: &monitor).isEmpty)
        XCTAssertTrue(hold(88, limitKph: 90, seconds: 5, from: 3, into: &monitor).isEmpty)
    }

    func testDroppingBackUnderResetsTheSustainedPeriod() {
        var monitor = SpeedLimitMonitor()
        _ = hold(110, limitKph: 90, seconds: 3, into: &monitor)
        _ = hold(80, limitKph: 90, seconds: 1, from: 3, into: &monitor)

        // The clock starts again, so three more seconds over is still not enough.
        XCTAssertTrue(hold(110, limitKph: 90, seconds: 3, from: 4, into: &monitor).isEmpty)
    }

    // MARK: - Repetition

    func testTheSameExceedanceIsNotRepeatedEverySecond() {
        var monitor = SpeedLimitMonitor()
        let spoken = hold(110, limitKph: 90, seconds: 50, into: &monitor)
        XCTAssertEqual(spoken.count, 1, "they were told")
    }

    /// The first line lands four seconds in, once the overspeed has been held
    /// long enough to mean something; the second sixty seconds after that.
    func testItIsSaidAgainAfterTheRepeatInterval() {
        var monitor = SpeedLimitMonitor()
        let spoken = hold(110, limitKph: 90, seconds: 100, into: &monitor)
        XCTAssertEqual(spoken.count, 2)
    }

    /// Coming off a motorway into a town is the case this exists for: the driver
    /// is suddenly a long way over a much lower limit and must not have to wait
    /// out the motorway's cooldown to hear about it.
    func testANewLimitSpeaksWithoutWaitingOutTheOldCooldown() {
        var monitor = SpeedLimitMonitor()
        XCTAssertEqual(hold(110, limitKph: 90, seconds: 10, into: &monitor).count, 1)

        let inTown = hold(70, limitKph: 50, seconds: 10, from: 10, into: &monitor)
        XCTAssertEqual(inTown.count, 1)
        XCTAssertEqual(inTown.first?.limitKph, 50)
    }

    // MARK: - Silence

    func testNoLimitDataMeansSilence() {
        var monitor = SpeedLimitMonitor()
        XCTAssertTrue(hold(150, limitKph: nil, seconds: 60, into: &monitor).isEmpty)
    }

    func testCrawlingIsNeverAnnounced() {
        var monitor = SpeedLimitMonitor()
        // A 10 km/h living street limit and a car manoeuvring at 20. GPS speed
        // is unreliable down here and the exceedance may not even be real.
        XCTAssertTrue(hold(20, limitKph: 10, seconds: 60, into: &monitor).isEmpty)
    }

    func testAFixWithNoSpeedIsIgnored() {
        var monitor = SpeedLimitMonitor()
        let noSpeed = LocationFix(
            coordinate: TestFixtures.origin,
            timestamp: now,
            speedMps: nil,
            horizontalAccuracy: 5,
            courseDegrees: 90
        )
        XCTAssertNil(monitor.update(fix: noSpeed, limitKph: 50))
    }

    func testLeavingTheRoadClearsTheCooldown() {
        var monitor = SpeedLimitMonitor()
        XCTAssertEqual(hold(110, limitKph: 90, seconds: 10, into: &monitor).count, 1)

        // Off the mapped network for a while, then back onto the same limit.
        // That is a new event, not a continuation of the old one.
        _ = hold(110, limitKph: nil, seconds: 5, from: 10, into: &monitor)
        XCTAssertEqual(hold(110, limitKph: 90, seconds: 10, from: 15, into: &monitor).count, 1)
    }
}
