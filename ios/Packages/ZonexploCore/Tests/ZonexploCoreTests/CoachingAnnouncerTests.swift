import XCTest
@testable import ZonexploCore

/// How talkative the app is, pinned down. These are product decisions as much
/// as code, which is exactly why they are tested.
final class CoachingAnnouncerTests: XCTestCase {
    private let start = TestFixtures.referenceDate
    private let zone = TestFixtures.zone(lengthMeters: 10_000, limitKph: 100)
    private let engine = CoachingEngine(policy: .standard)

    private func advice(
        covered: Double,
        elapsed: TimeInterval,
        smoothedKph: Double? = 90
    ) -> CoachingAdvice {
        let allowance = AllowanceCalculator.compute(zone: zone, distanceCovered: covered, elapsed: elapsed)
        return engine.advise(zone: zone, allowance: allowance, smoothedSpeedKph: smoothedKph)
    }

    func testTheFirstAdviceIsAlwaysSpoken() {
        var announcer = CoachingAnnouncer()
        XCTAssertTrue(announcer.shouldAnnounce(advice(covered: 100, elapsed: 4), at: start))
    }

    func testIdenticalAdviceIsNotRepeatedEverySecond() {
        var announcer = CoachingAnnouncer()
        XCTAssertTrue(announcer.shouldAnnounce(advice(covered: 100, elapsed: 4), at: start))

        for second in 1...30 {
            let spoken = announcer.shouldAnnounce(
                advice(covered: 100, elapsed: 4),
                at: start.addingTimeInterval(Double(second))
            )
            XCTAssertFalse(spoken, "repeated at second \(second)")
        }
    }

    /// The most important thing the app ever says.
    func testATierChangeIsAlwaysSpoken() {
        var announcer = CoachingAnnouncer()
        XCTAssertTrue(announcer.shouldAnnounce(advice(covered: 2_000, elapsed: 72), at: start))

        // Now badly over: the tier flips to impossible.
        XCTAssertTrue(
            announcer.shouldAnnounce(
                advice(covered: 9_000, elapsed: 216),
                at: start.addingTimeInterval(10)
            )
        )
    }

    func testTheAppNeverTalksOverItself() {
        var announcer = CoachingAnnouncer()
        XCTAssertTrue(announcer.shouldAnnounce(advice(covered: 2_000, elapsed: 72), at: start))

        // A tier change two seconds later still waits for the minimum gap.
        XCTAssertFalse(
            announcer.shouldAnnounce(
                advice(covered: 9_000, elapsed: 216),
                at: start.addingTimeInterval(2)
            )
        )
    }

    func testAMateriallyDifferentTargetIsSpoken() {
        var announcer = CoachingAnnouncer()
        // Tight tier, target 80.
        XCTAssertTrue(announcer.shouldAnnounce(advice(covered: 5_000, elapsed: 138.46), at: start))

        // Still tight, but the allowance has dropped to a 65 target.
        let tighter = advice(covered: 6_500, elapsed: 190)
        XCTAssertEqual(tighter.tier, .tight)
        XCTAssertTrue(announcer.shouldAnnounce(tighter, at: start.addingTimeInterval(15)))
    }

    func testATrivialTargetChangeIsNotWorthInterrupting() {
        var announcer = CoachingAnnouncer()
        var first = advice(covered: 5_000, elapsed: 138.46)
        XCTAssertTrue(announcer.shouldAnnounce(first, at: start))

        // Same tier, same rounded target: nothing has changed for the driver.
        first = advice(covered: 5_100, elapsed: 141)
        XCTAssertEqual(first.targetSpeedKph, 80)
        XCTAssertFalse(announcer.shouldAnnounce(first, at: start.addingTimeInterval(15)))
    }

    func testTightCoachingRepeatsSoonerThanNormalCoaching() {
        var tight = CoachingAnnouncer()
        let tightAdvice = advice(covered: 5_000, elapsed: 138.46)
        XCTAssertEqual(tightAdvice.tier, .tight)
        XCTAssertTrue(tight.shouldAnnounce(tightAdvice, at: start))
        XCTAssertFalse(tight.shouldAnnounce(tightAdvice, at: start.addingTimeInterval(44)))
        XCTAssertTrue(tight.shouldAnnounce(tightAdvice, at: start.addingTimeInterval(46)))

        var normal = CoachingAnnouncer()
        let normalAdvice = advice(covered: 5_000, elapsed: 180)
        XCTAssertEqual(normalAdvice.tier, .normal)
        XCTAssertTrue(normal.shouldAnnounce(normalAdvice, at: start))
        XCTAssertFalse(normal.shouldAnnounce(normalAdvice, at: start.addingTimeInterval(46)))
        XCTAssertTrue(normal.shouldAnnounce(normalAdvice, at: start.addingTimeInterval(121)))
    }

    func testAJamSilencesTheAppEntirely() {
        var announcer = CoachingAnnouncer()
        XCTAssertTrue(announcer.shouldAnnounce(advice(covered: 5_000, elapsed: 138.46), at: start))

        for second in stride(from: 10, through: 300, by: 10) {
            let spoken = announcer.shouldAnnounce(
                advice(covered: 5_000, elapsed: 138.46 + Double(second), smoothedKph: 2),
                at: start.addingTimeInterval(Double(second))
            )
            XCTAssertFalse(spoken, "spoke during a jam at second \(second)")
        }
    }

    /// Coming out of a jam, the driver has been told nothing for several
    /// minutes and the allowance has changed completely. They get a fresh
    /// instruction rather than silence.
    func testTheAppSpeaksAgainAsSoonAsTheJamClears() {
        var announcer = CoachingAnnouncer()
        XCTAssertTrue(announcer.shouldAnnounce(advice(covered: 5_000, elapsed: 138.46), at: start))
        XCTAssertFalse(
            announcer.shouldAnnounce(
                advice(covered: 5_000, elapsed: 200, smoothedKph: 1),
                at: start.addingTimeInterval(60)
            )
        )

        XCTAssertTrue(
            announcer.shouldAnnounce(
                advice(covered: 5_000, elapsed: 260),
                at: start.addingTimeInterval(120)
            )
        )
    }
}
