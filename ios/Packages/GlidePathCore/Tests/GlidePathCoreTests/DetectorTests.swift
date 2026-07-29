import XCTest
@testable import GlidePathCore

final class CrossingDetectorTests: XCTestCase {
    private let start = TestFixtures.referenceDate

    func testCrossingTimeIsInterpolatedBetweenFixes() {
        var detector = CrossingDetector()

        XCTAssertNil(detector.update(signedDistance: -40, at: start))
        // 40 m before to 60 m after in 10 seconds: the line was crossed 40% in.
        let crossing = detector.update(signedDistance: 60, at: start.addingTimeInterval(10))

        guard let crossing else { return XCTFail("expected a crossing") }
        XCTAssertEqual(crossing.timeIntervalSince(start), 4.0, accuracy: 0.001)
        XCTAssertTrue(detector.hasCrossed)
    }

    func testCrossingIsReportedOnlyOnce() {
        var detector = CrossingDetector()
        detector.update(signedDistance: -10, at: start)
        XCTAssertNotNil(detector.update(signedDistance: 10, at: start.addingTimeInterval(2)))
        XCTAssertNil(detector.update(signedDistance: 50, at: start.addingTimeInterval(3)))
    }

    func testApproachingWithoutCrossingReportsNothing() {
        var detector = CrossingDetector()
        detector.update(signedDistance: -400, at: start)
        XCTAssertNil(detector.update(signedDistance: -200, at: start.addingTimeInterval(5)))
        XCTAssertNil(detector.update(signedDistance: -20, at: start.addingTimeInterval(10)))
        XCTAssertFalse(detector.hasCrossed)
    }

    /// Joining late, already past the line, is the one case with nothing to
    /// interpolate. Taking the fix time is late rather than early, which is the
    /// safe direction to be wrong: a late start shortens elapsed time, which
    /// tightens the allowance rather than loosening it.
    func testFirstFixAlreadyPastTheLineUsesTheFixTime() {
        var detector = CrossingDetector()
        let crossing = detector.update(signedDistance: 120, at: start)
        XCTAssertEqual(crossing, start)
    }

    func testResetClearsState() {
        var detector = CrossingDetector()
        detector.update(signedDistance: -10, at: start)
        detector.update(signedDistance: 10, at: start.addingTimeInterval(1))
        detector.reset()
        XCTAssertFalse(detector.hasCrossed)
    }
}

final class DeviationDetectorTests: XCTestCase {
    private let start = TestFixtures.referenceDate

    func testStayingOnPathNeverFires() {
        var detector = DeviationDetector(thresholdMeters: 60, confirmationSeconds: 5)
        for second in 0..<30 {
            let fired = detector.update(crossTrackDistance: 15, at: start.addingTimeInterval(Double(second)))
            XCTAssertFalse(fired)
        }
    }

    func testDivergenceMustPersistBeforeItFires() {
        var detector = DeviationDetector(thresholdMeters: 60, confirmationSeconds: 5)

        XCTAssertFalse(detector.update(crossTrackDistance: 200, at: start))
        XCTAssertFalse(detector.update(crossTrackDistance: 200, at: start.addingTimeInterval(2)))
        XCTAssertFalse(detector.update(crossTrackDistance: 200, at: start.addingTimeInterval(4.9)))
        XCTAssertTrue(detector.update(crossTrackDistance: 200, at: start.addingTimeInterval(5)))
    }

    func testOneFixBackOnPathResetsTheClock() {
        var detector = DeviationDetector(thresholdMeters: 60, confirmationSeconds: 5)

        XCTAssertFalse(detector.update(crossTrackDistance: 200, at: start))
        XCTAssertFalse(detector.update(crossTrackDistance: 200, at: start.addingTimeInterval(4)))
        XCTAssertFalse(detector.update(crossTrackDistance: 5, at: start.addingTimeInterval(4.5)))
        XCTAssertNil(detector.divergingSince)

        // The clock restarts from here, so the old 4 seconds do not count.
        XCTAssertFalse(detector.update(crossTrackDistance: 200, at: start.addingTimeInterval(5)))
        XCTAssertFalse(detector.update(crossTrackDistance: 200, at: start.addingTimeInterval(8)))
        XCTAssertTrue(detector.update(crossTrackDistance: 200, at: start.addingTimeInterval(10)))
    }

    func testDivergenceDurationIsReportedForTheUi() {
        var detector = DeviationDetector(thresholdMeters: 60, confirmationSeconds: 5)
        detector.update(crossTrackDistance: 200, at: start)

        XCTAssertEqual(detector.divergenceDuration(at: start.addingTimeInterval(3)) ?? -1, 3, accuracy: 0.001)
        detector.update(crossTrackDistance: 1, at: start.addingTimeInterval(4))
        XCTAssertNil(detector.divergenceDuration(at: start.addingTimeInterval(4)))
    }
}

final class SpeedSmootherTests: XCTestCase {
    private let start = TestFixtures.referenceDate

    func testEmptySmootherReportsNoSamples() {
        let smoother = SpeedSmoother(window: 4)
        XCTAssertFalse(smoother.hasSamples)
        XCTAssertEqual(smoother.smoothedKph, 0)
    }

    func testSmoothingAveragesTheWindow() {
        var smoother = SpeedSmoother(window: 4)
        smoother.add(speedKph: 100, at: start)
        smoother.add(speedKph: 90, at: start.addingTimeInterval(1))
        smoother.add(speedKph: 110, at: start.addingTimeInterval(2))
        XCTAssertEqual(smoother.smoothedKph, 100, accuracy: 0.001)
    }

    func testSamplesOlderThanTheWindowAreDropped() {
        var smoother = SpeedSmoother(window: 4)
        smoother.add(speedKph: 200, at: start)
        smoother.add(speedKph: 50, at: start.addingTimeInterval(10))
        XCTAssertEqual(smoother.smoothedKph, 50, accuracy: 0.001)
    }
}
