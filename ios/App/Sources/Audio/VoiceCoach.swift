import AVFoundation
import Foundation
import GlidePathCore
import Observation

/// The voice.
///
/// GlidePath is designed to run behind a navigation app with the phone in a
/// cradle or a pocket, so the audio session is the whole interface most of the
/// time. Three things matter and everything here serves them:
///
/// - **Duck, do not stop.** Music, podcasts and the navigator you are actually
///   following keep playing, quieter, for the second and a half GlidePath needs.
/// - **Urgency preempts.** "Speed camera ahead" must not queue behind a
///   leisurely average-speed update.
/// - **Deactivate afterwards.** Holding the session open keeps everything else
///   ducked indefinitely, which is the single most obnoxious thing an app like
///   this can do.
@MainActor
@Observable
final class VoiceCoach: NSObject, CoachVoice {
    struct Settings: Equatable {
        var enabled = true

        /// Speech rate as a fraction of AVSpeechUtterance's default. Slightly
        /// quicker than default: these are short, predictable phrases and a
        /// driver wants them over with.
        var rateScale: Double = 1.05

        var volume: Double = 1.0

        /// BCP-47 tag, or nil to follow the system voice.
        var voiceIdentifier: String?

        /// When true the silent switch silences GlidePath.
        ///
        /// Off by default, matching every navigation app: a driver who has
        /// muted their phone for a meeting still wants to be told about the
        /// camera. Anyone who disagrees can turn it on in Settings.
        var respectSilentSwitch = false

        static let `default` = Settings()
    }

    var settings: Settings

    private let synthesizer = AVSpeechSynthesizer()
    private var isSessionActive = false

    /// Set while an utterance is in flight, so the session is only released
    /// once nothing is speaking.
    private var pendingUtterances = 0

    init(settings: Settings = .default) {
        self.settings = settings
        super.init()
        synthesizer.delegate = self
    }

    // MARK: - CoachVoice

    func speak(_ line: String, urgent: Bool) {
        guard settings.enabled, !line.isEmpty else { return }

        if urgent, synthesizer.isSpeaking {
            // An immediate stop clips mid-word, which sounds broken. Ending at
            // the current word is fast enough and sounds deliberate.
            synthesizer.stopSpeaking(at: .word)
            pendingUtterances = 0
        }

        activateSession()

        let utterance = AVSpeechUtterance(string: line)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * Float(settings.rateScale)
        utterance.volume = Float(settings.volume)
        utterance.postUtteranceDelay = 0

        if let identifier = settings.voiceIdentifier {
            utterance.voice = AVSpeechSynthesisVoice(identifier: identifier)
                ?? AVSpeechSynthesisVoice(language: identifier)
        }

        pendingUtterances += 1
        synthesizer.speak(utterance)
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        pendingUtterances = 0
        deactivateSession()
    }

    /// Speaks a line for the settings screen preview without touching the
    /// urgency queue.
    func preview() {
        speak("Hold 80 for the next 4 kilometres.", urgent: false)
    }

    // MARK: - Audio session

    private func activateSession() {
        guard !isSessionActive else { return }

        let session = AVAudioSession.sharedInstance()
        do {
            // .playback rather than .ambient so the silent switch does not
            // suppress a safety prompt, unless the driver has asked for that.
            //
            // .duckOthers lowers music. .interruptSpokenAudioAndMixWithOthers
            // pauses podcasts and audiobooks outright, because ducking speech
            // under speech is unintelligible, and resumes them afterwards.
            let category: AVAudioSession.Category = settings.respectSilentSwitch ? .ambient : .playback
            try session.setCategory(
                category,
                mode: .voicePrompt,
                options: [.duckOthers, .interruptSpokenAudioAndMixWithOthers]
            )
            try session.setActive(true)
            isSessionActive = true
        } catch {
            // Losing the session means losing the voice, not the app. The UI
            // still shows live numbers, so failing quietly is right here.
            print("[GlidePath] could not activate the audio session: \(error.localizedDescription)")
        }
    }

    private func deactivateSession() {
        guard isSessionActive, pendingUtterances == 0 else { return }

        do {
            // notifyOthersOnDeactivation is what tells the music app to come
            // back up to full volume. Without it everything stays ducked.
            try AVAudioSession.sharedInstance().setActive(
                false,
                options: [.notifyOthersOnDeactivation]
            )
            isSessionActive = false
        } catch {
            print("[GlidePath] could not release the audio session: \(error.localizedDescription)")
        }
    }
}

// MARK: - AVSpeechSynthesizerDelegate

extension VoiceCoach: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didFinish utterance: AVSpeechUtterance
    ) {
        MainActor.assumeIsolated {
            pendingUtterances = max(pendingUtterances - 1, 0)
            deactivateSession()
        }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didCancel utterance: AVSpeechUtterance
    ) {
        MainActor.assumeIsolated {
            pendingUtterances = max(pendingUtterances - 1, 0)
            deactivateSession()
        }
    }
}
