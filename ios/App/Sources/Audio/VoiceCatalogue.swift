import AVFoundation
import Foundation

/// One installed voice, reduced to the four things choosing between them needs.
///
/// A value type rather than `AVSpeechSynthesisVoice` so the choosing rules are
/// testable. The real class can only be obtained from the system, and what it
/// hands back depends on which voices that particular phone has downloaded,
/// which is the one thing a test must be able to control.
struct VoiceOption: Equatable, Identifiable, Sendable {
    /// Ranked rather than carrying `AVSpeechSynthesisVoiceQuality`, for the
    /// same reason: the ordering is the logic, and it should be assertable.
    enum Quality: Int, Comparable, Sendable {
        case standard
        case enhanced
        case premium

        static func < (lhs: Quality, rhs: Quality) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    let id: String
    let name: String
    /// BCP-47, as `AVSpeechSynthesisVoice` reports it: `en-GB`, `he-IL`.
    let language: String
    let quality: Quality
}

/// Which of the installed voices GlidePath should speak with.
///
/// An `AVSpeechUtterance` with no voice set gets the compact one, and the
/// compact voice is the robotic voice everybody recognises. It is not what the
/// phone is capable of: iOS ships compact for every language and downloads
/// enhanced and premium ones on request, and those are a different class of
/// thing that costs nothing at runtime once installed. Taking the default is
/// therefore choosing the worst voice on the device by omission.
///
/// So GlidePath asks for the best installed voice instead, and lets the driver
/// override it. Three families are excluded before anything is offered, each
/// for a reason that only shows up in the field - see `selectable`.
enum VoiceCatalogue {
    /// The voices worth offering, best first.
    ///
    /// Ordering is quality descending, then name, so the list is stable across
    /// launches. A picker that reshuffles itself is a picker nobody trusts.
    static func selectable(from voices: [VoiceOption]) -> [VoiceOption] {
        voices
            .filter(isSelectable)
            .sorted { lhs, rhs in
                if lhs.quality != rhs.quality { return lhs.quality > rhs.quality }
                if lhs.language != rhs.language { return lhs.language < rhs.language }
                return lhs.name < rhs.name
            }
    }

    /// The selectable voices that can speak this language at all, best first.
    ///
    /// Matched on the language, not the region, so a British phone is still
    /// offered the American and Australian voices. They read English correctly;
    /// they just sound like somewhere else.
    static func matching(_ voices: [VoiceOption], language: String) -> [VoiceOption] {
        let code = languageCode(language.lowercased())
        return selectable(from: voices).filter { languageCode($0.language.lowercased()) == code }
    }

    /// The voice to speak with, or nil to leave it to the system.
    ///
    /// Language first, quality second. A premium voice reading a language it
    /// does not speak is unintelligible, where a compact one in the right
    /// language is merely plain. Within the language the exact region wins, so
    /// a British driver gets the British accent when it is installed.
    static func best(from voices: [VoiceOption], preferring language: String) -> VoiceOption? {
        let pool = matching(voices, language: language)
        let wanted = language.lowercased()
        return pool.first { $0.language.lowercased() == wanted } ?? pool.first
    }

    /// Whether anything better than compact is installed for this language.
    ///
    /// Drives the hint that sends the driver to iOS Settings. It deliberately
    /// runs over `selectable` output, because a Siri voice is reported as
    /// premium and cannot be used - counting it would suppress the hint for
    /// someone who has no usable upgrade at all.
    static func hasUpgradedVoice(in voices: [VoiceOption], for language: String) -> Bool {
        matching(voices, language: language).contains { $0.quality > .standard }
    }

    /// `en` from `en-GB`, and `yue` from `yue-HK`.
    ///
    /// Splitting rather than taking the first two characters: three-letter
    /// codes exist, and truncating `yue` to `yu` matches Yiddish.
    private static func languageCode(_ language: String) -> String {
        language.split(separator: "-").first.map(String.init) ?? language
    }

    private static func isSelectable(_ voice: VoiceOption) -> Bool {
        let identifier = voice.id.lowercased()

        // Siri's voices are listed but reserved. `AVSpeechSynthesisVoice(identifier:)`
        // returns nil for them in a third-party app, so the utterance silently
        // falls back to the compact default - a setting that looks like it
        // works, changes nothing, and reads as a broken picker.
        if identifier.contains("siri") { return false }

        // Albert, Bubbles, Zarvox and the rest. A camera warning in a novelty
        // voice reads as a bug rather than a joke.
        if identifier.hasPrefix("com.apple.speech.synthesis.voice.") { return false }

        // The legacy synthesiser, and the most robotic thing on the phone.
        if identifier.contains("eloquence") { return false }

        return true
    }
}

// MARK: - The system's voices

extension VoiceCatalogue {
    /// Every usable voice this phone currently has, best first.
    ///
    /// Not cached here: the driver can install a voice in iOS Settings while
    /// GlidePath is in the background, and a list that cannot change until the
    /// next launch is how a download appears to have failed. `VoiceCoach` holds
    /// the snapshot and refreshes it when the settings screen appears.
    static var installed: [VoiceOption] {
        selectable(from: AVSpeechSynthesisVoice.speechVoices().map(VoiceOption.init))
    }

    /// The language GlidePath's phrases are actually written in, with the
    /// driver's region attached so the accent follows the phone.
    ///
    /// Deliberately not `AVSpeechSynthesisVoice.currentLanguageCode()`, which
    /// reports the *phone's* language. The Phrasebook is English. On a Hebrew
    /// phone that call returns `he-IL`, and a Hebrew voice reading "Hold 80 for
    /// the next 4 kilometres" is not accented English, it is noise - far worse
    /// than the compact English voice it would have replaced. The bundle's
    /// localisation is the honest answer, and it starts following the
    /// Phrasebook automatically on the day the app is translated.
    static var spokenLanguage: String {
        let base = Bundle.main.preferredLocalizations.first ?? "en"
        guard let region = Locale.current.region?.identifier else { return base }
        return "\(base)-\(region)"
    }
}

extension VoiceOption {
    init(_ voice: AVSpeechSynthesisVoice) {
        self.init(
            id: voice.identifier,
            name: voice.name,
            language: voice.language,
            quality: Quality(voice.quality)
        )
    }
}

extension VoiceOption.Quality {
    init(_ quality: AVSpeechSynthesisVoiceQuality) {
        switch quality {
        case .premium: self = .premium
        case .enhanced: self = .enhanced
        default: self = .standard
        }
    }

    var label: String {
        switch self {
        case .premium: return "Premium"
        case .enhanced: return "Enhanced"
        case .standard: return "Compact"
        }
    }
}
