import XCTest
@testable import Zonexplo

/// The flags are computed from the country code rather than stored, which is the
/// right call - a stored table of 243 emoji is a table that can drift - but it
/// does mean a bad code produces a bad glyph rather than a compile error. These
/// pin the arithmetic and, more importantly, the fallback.
final class CountryFlagTests: XCTestCase {
    func testLaunchCountries() {
        XCTAssertEqual(CountryFlag.emoji(for: "IL"), "🇮🇱")
        XCTAssertEqual(CountryFlag.emoji(for: "MD"), "🇲🇩")
        XCTAssertEqual(CountryFlag.emoji(for: "LT"), "🇱🇹")
    }

    /// Both ends of the alphabet, since the whole thing is offset arithmetic.
    func testTheEdgesOfTheAlphabet() {
        XCTAssertEqual(CountryFlag.emoji(for: "AD"), "🇦🇩")
        XCTAssertEqual(CountryFlag.emoji(for: "ZW"), "🇿🇼")
    }

    /// The seed CLI takes a code from the command line and the catalogue stores
    /// them uppercase, but nothing in between enforces the case.
    func testLowercaseIsAccepted() {
        XCTAssertEqual(CountryFlag.emoji(for: "il"), CountryFlag.emoji(for: "IL"))
    }

    /// XK is not an assigned ISO code, but it is what OpenStreetMap calls Kosovo
    /// and it is in the catalogue on purpose. Its flag is not in the regional
    /// indicator set, so what comes back is two letters in boxes - which is
    /// still better than a blank row, and is why this is asserted rather than
    /// left to chance.
    func testKosovoProducesSomething() {
        XCTAssertFalse(CountryFlag.emoji(for: "XK").isEmpty)
    }

    /// Anything that is not two letters must not produce a mangled glyph, and
    /// must not crash on the arithmetic.
    func testRubbishFallsBackToAPlainFlag() {
        for input in ["", "I", "ISR", "1L", "I1", "il ", "--"] {
            XCTAssertEqual(CountryFlag.emoji(for: input), "🏳️", "input: \(input)")
        }
    }
}
