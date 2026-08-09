import XCTest
@testable import Zonexplo

/// Choosing a voice is the difference between the app sounding like a satnav
/// and sounding like a 1990s answering machine, and every rule below exists
/// because getting it wrong is silent: a bad choice still speaks, just badly.
final class VoiceCatalogueTests: XCTestCase {
    private func voice(
        _ id: String,
        _ name: String = "Voice",
        _ language: String = "en-GB",
        _ quality: VoiceOption.Quality = .standard
    ) -> VoiceOption {
        VoiceOption(id: id, name: name, language: language, quality: quality)
    }

    // MARK: - Quality

    func testTheBestQualityVoiceForTheLanguageWins() {
        let pool = [
            voice("com.apple.voice.compact.en-GB.Daniel", "Daniel", "en-GB", .standard),
            voice("com.apple.voice.premium.en-GB.Serena", "Serena", "en-GB", .premium),
            voice("com.apple.voice.enhanced.en-GB.Kate", "Kate", "en-GB", .enhanced)
        ]
        XCTAssertEqual(VoiceCatalogue.best(from: pool, preferring: "en-GB")?.name, "Serena")
    }

    /// The accent the driver expects beats a better voice speaking the wrong
    /// one. A premium American voice reading British road numbers is more
    /// jarring than a compact British one, and for Hebrew against English it
    /// stops being a matter of taste.
    func testTheExactLanguageBeatsAHigherQualityVoiceInAnother() {
        let pool = [
            voice("com.apple.voice.premium.en-US.Ava", "Ava", "en-US", .premium),
            voice("com.apple.voice.compact.en-GB.Daniel", "Daniel", "en-GB", .standard)
        ]
        XCTAssertEqual(VoiceCatalogue.best(from: pool, preferring: "en-GB")?.name, "Daniel")
    }

    /// Same language, different region, is still far better than falling back
    /// to whatever the system hands out.
    func testAnotherRegionOfTheSameLanguageIsUsedWhenTheExactOneIsMissing() {
        let pool = [
            voice("com.apple.voice.enhanced.en-AU.Karen", "Karen", "en-AU", .enhanced),
            voice("com.apple.voice.compact.fr-FR.Thomas", "Thomas", "fr-FR", .standard)
        ]
        XCTAssertEqual(VoiceCatalogue.best(from: pool, preferring: "en-GB")?.name, "Karen")
    }

    /// Three-letter language codes must not be truncated to two.
    func testLanguageMatchingSplitsOnTheSeparatorRatherThanTakingTwoCharacters() {
        let pool = [
            voice("com.apple.voice.compact.yue-CN.Sinji", "Sinji", "yue-CN", .standard),
            voice("com.apple.voice.compact.yi-DE.Yaakov", "Yaakov", "yi-DE", .standard)
        ]
        XCTAssertEqual(VoiceCatalogue.best(from: pool, preferring: "yue-HK")?.name, "Sinji")
    }

    func testNoVoiceForTheLanguageMeansNoChoiceRatherThanAWrongOne() {
        let pool = [voice("com.apple.voice.compact.fr-FR.Thomas", "Thomas", "fr-FR", .standard)]
        XCTAssertNil(VoiceCatalogue.best(from: pool, preferring: "he-IL"))
    }

    // MARK: - The voices that must never be offered

    /// Siri's voices are listed by `speechVoices()` and cannot be instantiated
    /// by anyone but Apple. Offering one produces a setting that appears to
    /// work, changes nothing, and leaves the driver concluding the picker is
    /// broken - because `AVSpeechSynthesisVoice(identifier:)` returns nil and
    /// the utterance quietly falls back to the compact default.
    func testSiriVoicesAreNeverOffered() {
        let pool = [
            voice("com.apple.ttsbundle.siri_Nicky_en-US_compact", "Nicky", "en-US", .enhanced),
            voice("com.apple.voice.compact.en-US.Samantha", "Samantha", "en-US", .standard)
        ]
        XCTAssertEqual(VoiceCatalogue.selectable(from: pool).map(\.name), ["Samantha"])
        XCTAssertEqual(VoiceCatalogue.best(from: pool, preferring: "en-US")?.name, "Samantha")
    }

    /// Albert, Bubbles, Zarvox and the rest are jokes. A camera warning read by
    /// a novelty voice is worse than no warning, because it reads as a bug.
    func testNoveltyVoicesAreNeverOffered() {
        let pool = [
            voice("com.apple.speech.synthesis.voice.Albert", "Albert", "en-US", .standard),
            voice("com.apple.voice.compact.en-US.Samantha", "Samantha", "en-US", .standard)
        ]
        XCTAssertEqual(VoiceCatalogue.selectable(from: pool).map(\.name), ["Samantha"])
    }

    /// Eloquence is the legacy synthesiser, and it is the single most robotic
    /// thing installed on the phone.
    func testEloquenceVoicesAreNeverOffered() {
        let pool = [
            voice("com.apple.eloquence.en-US.Reed", "Reed", "en-US", .standard),
            voice("com.apple.voice.compact.en-US.Samantha", "Samantha", "en-US", .standard)
        ]
        XCTAssertEqual(VoiceCatalogue.selectable(from: pool).map(\.name), ["Samantha"])
    }

    // MARK: - What the picker is allowed to list

    /// The picker offers every English voice on a British phone, not only the
    /// British ones - they all read English, they just sound like somewhere
    /// else, and hiding them would hide most of the good ones.
    func testMatchingKeepsEveryRegionOfTheLanguageAndDropsTheRest() {
        let pool = [
            voice("com.apple.voice.compact.en-GB.Daniel", "Daniel", "en-GB", .standard),
            voice("com.apple.voice.premium.en-US.Ava", "Ava", "en-US", .premium),
            voice("com.apple.voice.enhanced.fr-FR.Thomas", "Thomas", "fr-FR", .enhanced)
        ]
        XCTAssertEqual(
            VoiceCatalogue.matching(pool, language: "en-GB").map(\.name),
            ["Ava", "Daniel"]
        )
    }

    // MARK: - Ordering and the upgrade hint

    func testSelectableVoicesComeBackBestFirstAndDeterministically() {
        let pool = [
            voice("com.apple.voice.compact.en-GB.Daniel", "Daniel", "en-GB", .standard),
            voice("com.apple.voice.premium.en-GB.Serena", "Serena", "en-GB", .premium),
            voice("com.apple.voice.enhanced.en-GB.Arthur", "Arthur", "en-GB", .enhanced),
            voice("com.apple.voice.enhanced.en-GB.Kate", "Kate", "en-GB", .enhanced)
        ]
        XCTAssertEqual(
            VoiceCatalogue.selectable(from: pool).map(\.name),
            ["Serena", "Arthur", "Kate", "Daniel"]
        )
    }

    /// Drives the "your phone can do better than this" hint. Only an upgrade in
    /// the language actually being spoken counts.
    func testTheUpgradeHintOnlyCountsVoicesInTheSpokenLanguage() {
        let onlyCompact = [voice("com.apple.voice.compact.en-GB.Daniel", "Daniel", "en-GB", .standard)]
        XCTAssertFalse(VoiceCatalogue.hasUpgradedVoice(in: onlyCompact, for: "en-GB"))

        let upgradedElsewhere = onlyCompact + [
            voice("com.apple.voice.premium.fr-FR.Thomas", "Thomas", "fr-FR", .premium)
        ]
        XCTAssertFalse(VoiceCatalogue.hasUpgradedVoice(in: upgradedElsewhere, for: "en-GB"))

        let upgradedHere = onlyCompact + [
            voice("com.apple.voice.enhanced.en-GB.Kate", "Kate", "en-GB", .enhanced)
        ]
        XCTAssertTrue(VoiceCatalogue.hasUpgradedVoice(in: upgradedHere, for: "en-GB"))
    }

    /// A Siri voice is enhanced and unusable, so it must not be what convinces
    /// the app the driver already has a good voice installed.
    func testAnUnusableVoiceDoesNotSatisfyTheUpgradeHint() {
        let pool = [
            voice("com.apple.voice.compact.en-GB.Daniel", "Daniel", "en-GB", .standard),
            voice("com.apple.ttsbundle.siri_Martha_en-GB_compact", "Martha", "en-GB", .premium)
        ]
        XCTAssertFalse(VoiceCatalogue.hasUpgradedVoice(in: pool, for: "en-GB"))
    }
}
