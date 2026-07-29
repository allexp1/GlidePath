import XCTest
@testable import GlidePath

/// The config surface is the first thing anyone touches and was the least
/// tested thing in the repo. These are the forms people actually type.
final class AppConfigTests: XCTestCase {
    private func resolve(_ raw: String) throws -> String {
        try AppConfig.resolveSupabaseURL(raw).absoluteString
    }

    /// The recommended form: no scheme, so nothing for xcconfig to eat.
    func testBareHostGetsHttps() throws {
        XCTAssertEqual(try resolve("abcdefghijkl.supabase.co"), "https://abcdefghijkl.supabase.co")
    }

    func testBareProjectRefIsExpanded() throws {
        XCTAssertEqual(try resolve("abcdefghijkl"), "https://abcdefghijkl.supabase.co")
    }

    func testAFullURLIsAcceptedWhenTheSlashesSurvived() throws {
        XCTAssertEqual(try resolve("https://abcdefghijkl.supabase.co"), "https://abcdefghijkl.supabase.co")
    }

    func testTrailingSlashesAreTrimmed() throws {
        XCTAssertEqual(try resolve("https://abcdefghijkl.supabase.co//"), "https://abcdefghijkl.supabase.co")
        XCTAssertEqual(try resolve("abcdefghijkl.supabase.co/"), "https://abcdefghijkl.supabase.co")
    }

    func testSurroundingWhitespaceIsIgnored() throws {
        XCTAssertEqual(try resolve("  abcdefghijkl.supabase.co  "), "https://abcdefghijkl.supabase.co")
    }

    func testASelfHostedURLIsLeftAlone() throws {
        XCTAssertEqual(try resolve("https://supabase.example.com"), "https://supabase.example.com")
    }

    // MARK: - The failures

    /// The exact value an xcconfig produces from `https://host`: the `//` is
    /// treated as a comment and everything after it disappears. Nothing can be
    /// recovered, so it has to be reported rather than guessed at.
    func testABareSchemeIsRejected() {
        XCTAssertThrowsError(try resolve("https:"))
        XCTAssertThrowsError(try resolve("http:"))
    }

    func testEmptyIsRejected() {
        XCTAssertThrowsError(try resolve(""))
        XCTAssertThrowsError(try resolve("   "))
    }

    func testANonHttpSchemeIsRejected() {
        XCTAssertThrowsError(try resolve("ftp://abcdefghijkl.supabase.co"))
    }

    /// The error has to name the file and the fix, because this screen is the
    /// only thing standing between a new developer and an app that silently
    /// shows no cameras.
    func testTheErrorExplainsWhatToDo() {
        do {
            _ = try resolve("https:")
            XCTFail("expected a bare scheme to throw")
        } catch {
            let message = error.localizedDescription
            XCTAssertTrue(message.contains("Config.xcconfig"), message)
            XCTAssertTrue(message.contains("SUPABASE_URL"), message)
        }
    }
}
