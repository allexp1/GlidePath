import XCTest
@testable import GlidePathCore

/// Phrasing is product behaviour, not decoration: what the driver hears is the
/// entire interface while the phone is in a pocket.
final class PhrasebookTests: XCTestCase {
    private let phrasebook = Phrasebook(units: .metric)
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

    // MARK: - Numbers

    func testDistancesDropAPointlessDecimal() {
        XCTAssertEqual(phrasebook.distancePhrase(4_000), "4 kilometres")
        XCTAssertEqual(phrasebook.distancePhrase(4_300), "4.3 kilometres")
        XCTAssertEqual(phrasebook.distancePhrase(1_000), "1 kilometre")
        XCTAssertEqual(phrasebook.distancePhrase(540), "500 metres")
        XCTAssertEqual(phrasebook.distancePhrase(20), "100 metres", "never promise less warning than exists")
    }

    func testDurationsAreRoundedToSomethingSayable() {
        XCTAssertEqual(phrasebook.durationPhrase(38), "40 seconds")
        XCTAssertEqual(phrasebook.durationPhrase(4), "10 seconds", "a floor of ten, so a pause sounds real")
        XCTAssertEqual(phrasebook.durationPhrase(62), "one minute")
        XCTAssertEqual(phrasebook.durationPhrase(108), "2 minutes")
    }

    func testImperialUnitsConvert() {
        let imperial = Phrasebook(units: .imperial)
        XCTAssertEqual(imperial.speedPhrase(100), "62")
        XCTAssertEqual(imperial.distancePhrase(1_609.344), "1 mile")
    }

    // MARK: - Coaching lines

    func testNormalTierReassures() {
        let zone = TestFixtures.zone(lengthMeters: 10_000, limitKph: 90)
        let line = phrasebook.coaching(advice(zone: zone, covered: 5_000, elapsed: 200))
        XCTAssertEqual(line, "You are fine. Hold 90.")
    }

    func testTightTierLeadsWithTheInstruction() {
        let zone = TestFixtures.zone(lengthMeters: 10_000, limitKph: 100)
        let line = phrasebook.coaching(advice(zone: zone, covered: 5_000, elapsed: 138.46))
        XCTAssertEqual(line, "Hold 80 for the next 5 kilometres.")
    }

    func testSuppressedAdviceSaysNothingAtAll() {
        let zone = TestFixtures.zone(lengthMeters: 10_000, limitKph: 100)
        let line = phrasebook.coaching(advice(zone: zone, covered: 5_000, elapsed: 138.46, smoothedKph: 3))
        XCTAssertNil(line, "a driver stuck in traffic should hear silence, not a target")
    }

    func testImpossibleTierWithARestStopGivesTheDriverSomethingToDo() {
        let base = TestFixtures.zone(lengthMeters: 10_000, limitKph: 100)
        let stop = TestFixtures.restStop(at: 9_000, in: base)
        let zone = TestFixtures.zone(lengthMeters: 10_000, limitKph: 100, restStops: [stop])

        let line = phrasebook.coaching(advice(zone: zone, covered: 8_000, elapsed: 180))
        guard let line else { return XCTFail("expected a spoken recovery") }

        XCTAssertTrue(line.contains("cannot make this one by driving"))
        XCTAssertTrue(line.contains("1 kilometre"))
        XCTAssertTrue(line.contains("2 minute"))
    }

    func testImpossibleTierAdmitsDefeatWhenThereIsNothingToBeDone() {
        let zone = TestFixtures.zone(lengthMeters: 10_000, limitKph: 100)
        let line = phrasebook.coaching(advice(zone: zone, covered: 9_000, elapsed: 216))
        guard let line else { return XCTFail("expected an honest verdict") }

        XCTAssertTrue(line.contains("already lost"))
        XCTAssertTrue(line.contains("Drive normally."), "never leave the driver coasting dangerously")
    }

    // MARK: - Zone lifecycle

    func testZoneEntryStatesLengthAndLimit() {
        let zone = TestFixtures.zone(lengthMeters: 4_000, limitKph: 90)
        XCTAssertEqual(phrasebook.zoneEntry(zone), "Average speed zone. 4 kilometres at 90.")
    }

    func testZoneExitReportsTheAverage() {
        let outcome = ZoneOutcome(
            zoneID: "z",
            zoneDistanceMeters: 10_000,
            averageKph: 88,
            limitKph: 90,
            elapsedSeconds: 409,
            enteredAt: TestFixtures.referenceDate,
            exitedAt: TestFixtures.referenceDate.addingTimeInterval(409)
        )
        XCTAssertEqual(phrasebook.zoneExit(outcome), "Zone clear. You averaged 88.")
    }

    func testZoneExitDoesNotPretendAFailWasAPass() {
        let outcome = ZoneOutcome(
            zoneID: "z",
            zoneDistanceMeters: 10_000,
            averageKph: 104,
            limitKph: 90,
            elapsedSeconds: 346,
            enteredAt: TestFixtures.referenceDate,
            exitedAt: TestFixtures.referenceDate.addingTimeInterval(346)
        )
        XCTAssertEqual(phrasebook.zoneExit(outcome), "Zone ended. You averaged 104, about 14 over.")
    }

    func testCancellingByHandIsNotAnnounced() {
        XCTAssertNil(phrasebook.zoneAbandoned(.cancelled), "the user just did this, they know")
        XCTAssertNotNil(phrasebook.zoneAbandoned(.leftTheRoad))
        XCTAssertNotNil(phrasebook.zoneAbandoned(.lostSignal))
    }

    // MARK: - Point cameras

    func testAdvanceWarningNamesTheCameraAndTheLimit() {
        let camera = Camera(
            id: "c1",
            countryCode: "MD",
            coordinate: TestFixtures.origin,
            type: .fixed,
            speedLimitKph: 50
        )
        let approach = CameraApproach(
            camera: camera,
            distanceMeters: 400,
            urgency: .advance,
            overLimitByKph: nil
        )
        XCTAssertEqual(phrasebook.cameraApproach(approach), "Speed camera in 400 metres, 50.")
    }

    func testImminentWarningTellsAnOverspeedingDriverByHowMuch() {
        let camera = Camera(
            id: "c1",
            countryCode: "MD",
            coordinate: TestFixtures.origin,
            type: .fixed,
            speedLimitKph: 50
        )
        let approach = CameraApproach(
            camera: camera,
            distanceMeters: 150,
            urgency: .imminent,
            overLimitByKph: 18
        )
        XCTAssertEqual(phrasebook.cameraApproach(approach), "Speed camera ahead. Ease off, you are 18 over.")
    }

    func testMobileHotspotsAreWordedAsGuessesNotFacts() {
        let camera = Camera(
            id: "c2",
            countryCode: "MD",
            coordinate: TestFixtures.origin,
            type: .mobileHotspot
        )
        let approach = CameraApproach(
            camera: camera,
            distanceMeters: 600,
            urgency: .advance,
            overLimitByKph: nil
        )
        XCTAssertEqual(phrasebook.cameraApproach(approach), "Mobile camera spot in 600 metres.")
    }

    func testNonSpeedCamerasAreNamedForWhatTheyActuallyCatch() {
        for (type, expected) in [
            (CameraType.redLight, "Red light camera ahead."),
            (CameraType.seatbeltPhone, "Seat belt and phone camera ahead."),
            (CameraType.busLane, "Bus lane camera ahead.")
        ] {
            let camera = Camera(id: "c", countryCode: "IL", coordinate: TestFixtures.origin, type: type)
            let approach = CameraApproach(
                camera: camera,
                distanceMeters: 120,
                urgency: .imminent,
                overLimitByKph: nil
            )
            XCTAssertEqual(phrasebook.cameraApproach(approach), expected)
        }
    }

    // MARK: - Posted speed limits

    func testTheLimitIsSpokenBeforeTheExcess() {
        let exceedance = SpeedLimitMonitor.Exceedance(limitKph: 90, speedKph: 102)
        // The limit first: it is the fact the driver may not have. How far over
        // they are is only the reason to act on it, and leading with it leaves
        // them working out "over what" at the wrong moment.
        XCTAssertEqual(phrasebook.speedLimitExceeded(exceedance), "Limit 90. You are 12 over.")
    }

    func testBothNumbersConvertTogetherInMiles() {
        let imperial = Phrasebook(units: .imperial)
        let exceedance = SpeedLimitMonitor.Exceedance(limitKph: 80, speedKph: 96)
        // 80 km/h is 50 mph and the 16 km/h excess is 10 mph. A converted limit
        // beside an unconverted excess would be a plausible-looking sentence
        // that is simply wrong.
        XCTAssertEqual(imperial.speedLimitExceeded(exceedance), "Limit 50. You are 10 over.")
    }

    func testTheLimitLineNeverMentionsACameraOrAFine() {
        let exceedance = SpeedLimitMonitor.Exceedance(limitKph: 50, speedKph: 70)
        let line = phrasebook.speedLimitExceeded(exceedance)
        // The app has no evidence anything is enforcing this stretch, and
        // inventing a consequence for a number it cannot source is how a safety
        // aid turns into nagging.
        for word in ["camera", "fine", "police", "caught"] {
            XCTAssertFalse(line.lowercased().contains(word), "\(line) should not mention \(word)")
        }
    }
}
