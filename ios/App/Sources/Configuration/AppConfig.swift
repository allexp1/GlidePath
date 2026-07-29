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
                    SUPABASE_URL is not a valid URL: \(value)
                    In an xcconfig file a double slash starts a comment, so the scheme must be
                    written as https:/$()/your-ref.supabase.co
                    """
            }
        }
    }

    static var supabaseURL: URL {
        get throws {
            let raw = try string(for: "SUPABASE_URL")
            guard let url = URL(string: raw), url.scheme != nil, url.host() != nil else {
                throw ConfigurationError.malformedURL(raw)
            }
            return url
        }
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
