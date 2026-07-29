import Foundation

/// Build-time configuration, read back at runtime.
///
/// The values arrive via Config.xcconfig, which XcodeGen wires into every build
/// configuration, and which project.yml copies into Info.plist. That chain is
/// what lets a new developer edit exactly one file and build.
enum AppConfig {
    enum ConfigurationError: LocalizedError {
        case missing(String)
        case placeholder(String)
        case malformedURL(String)

        var errorDescription: String? {
            switch self {
            case let .missing(key):
                return "\(key) is missing from Info.plist. Did you run `make project` after editing Config.xcconfig?"
            case let .placeholder(key):
                return "\(key) still holds its placeholder value. Fill it in in Config.xcconfig."
            case let .malformedURL(value):
                return """
                    SUPABASE_URL could not be understood: "\(value)"

                    Set it in Config.xcconfig to just the host, with no scheme:
                      SUPABASE_URL = your-project-ref.supabase.co
                    """
            }
        }
    }

    static var supabaseURL: URL {
        get throws {
            try Self.resolveSupabaseURL(try string(for: "SUPABASE_URL"))
        }
    }

    /// Turns whatever ended up in Config.xcconfig into a usable URL.
    ///
    /// This is deliberately forgiving, because the obvious thing to type is the
    /// one thing that does not work. An xcconfig file treats `//` as a comment
    /// wherever it appears, so `https://abc.supabase.co` is silently truncated
    /// to `https:` before the app ever sees it. Working around that used to mean
    /// writing the scheme as `https:/$()/abc.supabase.co`, which is an
    /// unreasonable thing to expect anyone to know.
    ///
    /// So the recommended form has no scheme at all and therefore no `//` to be
    /// eaten. All of these now work:
    ///
    ///     your-project-ref.supabase.co     recommended
    ///     your-project-ref                 just the ref
    ///     https://your-project-ref.supabase.co
    ///     https:/$()/your-project-ref.supabase.co
    static func resolveSupabaseURL(_ raw: String) throws -> URL {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.hasSuffix("/") { value.removeLast() }

        guard !value.isEmpty else { throw ConfigurationError.malformedURL(raw) }

        // A bare scheme is the signature of the comment-truncation problem.
        // Nothing can be recovered from it, so say so plainly.
        if value == "https:" || value == "http:" {
            throw ConfigurationError.malformedURL(raw)
        }

        let candidate: String
        if value.contains("://") {
            candidate = value
        } else if value.contains(".") {
            candidate = "https://\(value)"
        } else {
            // No dots at all: treat it as a project ref.
            candidate = "https://\(value).supabase.co"
        }

        guard let url = URL(string: candidate),
              url.scheme?.hasPrefix("http") == true,
              let host = url.host(),
              host.contains(".") else {
            throw ConfigurationError.malformedURL(raw)
        }
        return url
    }

    static var supabaseAnonKey: String {
        get throws { try string(for: "SUPABASE_ANON_KEY") }
    }

    /// True when the app has enough configuration to talk to Supabase. The UI
    /// uses this to show a setup screen instead of failing silently with an
    /// empty country list, which is a genuinely baffling first run.
    static var isConfigured: Bool {
        do {
            _ = try supabaseURL
            _ = try supabaseAnonKey
            return true
        } catch {
            return false
        }
    }

    static var configurationProblem: String? {
        do {
            _ = try supabaseURL
            _ = try supabaseAnonKey
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private static func string(for key: String) throws -> String {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String,
              !value.isEmpty else {
            throw ConfigurationError.missing(key)
        }
        guard !value.hasPrefix("YOUR-"), !value.contains("YOUR-PROJECT-REF") else {
            throw ConfigurationError.placeholder(key)
        }
        return value
    }
}
