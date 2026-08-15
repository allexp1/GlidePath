import AVFoundation
import Foundation
import ZonexploCore
import Observation

/// The voice.
///
/// Zonexplo is designed to run behind a navigation app with the phone in a
/// cradle or a pocket, so the audio session is the whole interface most of the
/// time. Three things matter and everything here serves them:
///
/// - **Duck, do not stop.** Music, podcasts and the navigator you are actually
///   following keep playing, quieter, for the second and a half Zonexplo needs.
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

        /// An `AVSpeechSynthesisVoice` identifier, or nil to let Zonexplo pick
        /// the best installed voice for the system language.
        ///
        /// Nil is the useful default and not the same as leaving the utterance
        /// alone: an utterance with no voice gets the *compact* one, which is
        /// the worst voice on the phone. See `VoiceCatalogue`.
        var voiceIdentifier: String?

        /// Speak out of the iPhone's own speaker instead of wherever the phone
        /// is currently sending audio.
        ///
        /// For cars that are not CarPlay. In a Tesla the phone pairs over
        /// Bluetooth, but the car plays its *own* Spotify, and while that is
        /// the selected source nothing the phone sends over Bluetooth is
        /// audible - so the driver hears music and never hears the camera
        /// warning. The phone's own speaker is the one output the car cannot
        /// take away.
        ///
        /// It is a worse experience than Bluetooth wherever Bluetooth works,
        /// which is why it is off by default: the alert competes with the car
        /// stereo rather than ducking it, because `.duckOthers` has no reach
        /// into an app running on the car's computer.
        var forceBuiltInSpeaker = false

        /// When true the silent switch silences Zonexplo.
        ///
        /// Off by default, matching every navigation app: a driver who has
        /// muted their phone for a meeting still wants to be told about the
        /// camera. Anyone who disagrees can turn it on in Settings.
        var respectSilentSwitch = false

        static let `default` = Settings()
    }

    var settings: Settings {
        didSet {
            if settings.voiceIdentifier != oldValue.voiceIdentifier { chosenVoice = nil }
        }
    }

    /// The usable voices this phone has, best first, for the settings picker.
    private(set) var availableVoices: [VoiceOption] = []

    private let synthesizer = AVSpeechSynthesizer()
    private var isSessionActive = false

    /// Resolved once and reused. Looking a voice up walks every installed
    /// voice, which is not work to repeat on a warning that has to be spoken
    /// now.
    private var chosenVoice: AVSpeechSynthesisVoice?

    /// Set while an utterance is in flight, so the session is only released
    /// once nothing is speaking.
    private var pendingUtterances = 0

    init(settings: Settings = .default) {
        self.settings = settings
        super.init()
        synthesizer.delegate = self
        refreshVoices()
    }

    /// Re-reads the installed voices.
    ///
    /// Called when the settings screen appears, because the driver can install
    /// a voice in iOS Settings while Zonexplo is in the background and a list
    /// that only changes on relaunch is how a download appears to have failed.
    func refreshVoices() {
        availableVoices = VoiceCatalogue.installed
        chosenVoice = nil
        Diagnostics.shared.record(
            .voice,
            "\(availableVoices.count) usable voices installed for \(VoiceCatalogue.spokenLanguage)"
        )
    }

    /// The voice to speak with.
    ///
    /// Falls through to the best installed voice when the chosen one cannot be
    /// resolved, which happens more than it sounds: the driver deleted it in
    /// iOS Settings, or restored this install onto a phone that never had it.
    /// Dropping silently to the compact default there would be the robotic
    /// voice coming back with no explanation.
    private func currentVoice() -> AVSpeechSynthesisVoice? {
        if let chosenVoice { return chosenVoice }

        if let identifier = settings.voiceIdentifier,
           let voice = AVSpeechSynthesisVoice(identifier: identifier) {
            chosenVoice = voice
            return voice
        }

        chosenVoice = VoiceCatalogue
            .best(from: availableVoices, preferring: VoiceCatalogue.spokenLanguage)
            .flatMap { AVSpeechSynthesisVoice(identifier: $0.id) }
        return chosenVoice
    }

    // MARK: - CoachVoice

    func speak(_ line: String, urgent: Bool) {
        guard settings.enabled else {
            Diagnostics.shared.record(.voice, "not spoken, spoken alerts are off: \"\(line)\"")
            return
        }
        guard !line.isEmpty else { return }

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
        utterance.voice = currentVoice()

        pendingUtterances += 1
        Diagnostics.shared.record(
            .voice,
            "speaking\(urgent ? " (urgent)" : "") as \(utterance.voice?.name ?? "system default"): \"\(line)\""
        )
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

            applyOutputRoute(session)
        } catch {
            // Losing the session means losing the voice, not the app. The UI
            // still shows live numbers, so failing quietly is right here.
            // The commonest cause of "I heard nothing" that is not a setting:
            // another app holding the session, or a route that went away.
            Diagnostics.shared.record(
                .voice,
                "AUDIO SESSION REFUSED - nothing can be spoken: \(error.localizedDescription)"
            )
            print("[Zonexplo] could not activate the audio session: \(error.localizedDescription)")
        }
    }

    /// Send this utterance where the setting says, and nowhere else.
    ///
    /// Stated both ways round on every activation, rather than only applied
    /// when the switch is on. An override is a property of the session and
    /// outlives the decision that set it, so a version of this that merely
    /// stopped re-applying would leave the phone talking to itself until
    /// something else happened to clear the route - which is a setting that
    /// cannot be turned off, whatever the switch says. Turning it off has to be
    /// an instruction, not the absence of one.
    ///
    /// Applied per activation rather than once at launch, because the session
    /// is deactivated after every line spoken so that other audio comes back up.
    ///
    /// **Whether this works at all is a question about the device, not the
    /// code.** Apple documents the override as belonging to `.playAndRecord`,
    /// and adopting that category to get it would make Zonexplo an app that
    /// asks for the microphone - a bad trade for something that records
    /// nothing, and not one to make on a guess. The simulator allows it from
    /// `.playback`, but the simulator has no Bluetooth route to override and is
    /// lenient about these rules generally.
    ///
    /// So it is attempted, and the answer is written down. If real phones
    /// refuse, the diagnostic report says so in as many words and the decision
    /// about the microphone can be made on evidence.
    private func applyOutputRoute(_ session: AVAudioSession) {
        guard settings.forceBuiltInSpeaker else {
            // The instruction, not the absence of one. Cheap when there was
            // never an override to undo, and the only thing that makes the
            // switch reversible when there was.
            try? session.overrideOutputAudioPort(.none)
            return
        }

        do {
            try session.overrideOutputAudioPort(.speaker)

            // The override succeeding is not the same as it taking effect. Ask
            // the route what actually happened rather than assuming.
            let outputs = session.currentRoute.outputs.map(\.portType.rawValue)
            let onSpeaker = session.currentRoute.outputs.contains { $0.portType == .builtInSpeaker }

            Diagnostics.shared.record(
                .voice,
                onSpeaker
                    ? "forced to the iPhone speaker, playing out of \(outputs.joined(separator: ", "))"
                    : "SPEAKER OVERRIDE ACCEPTED BUT IGNORED - still playing out of "
                        + "\(outputs.joined(separator: ", ")). This iPhone will not route to its "
                        + "own speaker from a playback session."
            )
        } catch {
            Diagnostics.shared.record(
                .voice,
                "SPEAKER OVERRIDE REFUSED by this iPhone (\(error.localizedDescription)). "
                    + "Alerts are going wherever the phone is already sending audio."
            )
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
            print("[Zonexplo] could not release the audio session: \(error.localizedDescription)")
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
