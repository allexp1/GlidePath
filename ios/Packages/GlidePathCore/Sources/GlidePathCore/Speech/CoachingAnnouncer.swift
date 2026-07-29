import Foundation

/// Decides when to open its mouth.
///
/// The engine produces advice at 1 Hz. Speaking all of it would be unusable,
/// and speaking too little defeats the point, so this is where the product's
/// tone actually lives. It sits in the core package rather than in the audio
/// layer because "how naggy is this app" deserves tests.
///
/// The rules, in order of priority:
///
/// 1. Silence in a jam. A driver who cannot move cannot act on a number.
/// 2. Never talk over yourself.
/// 3. Always speak a change of tier. Going from "you are fine" to "you need to
///    slow down" is the single most important thing the app ever says.
/// 4. Speak a materially different number. Five km/h is the smallest change
///    worth interrupting someone for.
/// 5. Otherwise repeat on a timer, faster when the situation is tighter.
public struct CoachingAnnouncer: Sendable {
    public struct Policy: Sendable, Equatable {
        public var normalRepeatInterval: TimeInterval
        public var tightRepeatInterval: TimeInterval
        public var impossibleRepeatInterval: TimeInterval

        /// How much the target has to move before it is worth saying again.
        public var minimumTargetChangeKph: Double

        /// Hard floor between two utterances, so a burst of state changes does
        /// not produce a burst of speech.
        public var minimumGapSeconds: TimeInterval

        public init(
            normalRepeatInterval: TimeInterval = 120,
            tightRepeatInterval: TimeInterval = 45,
            impossibleRepeatInterval: TimeInterval = 60,
            minimumTargetChangeKph: Double = 5,
            minimumGapSeconds: TimeInterval = 6
        ) {
            self.normalRepeatInterval = normalRepeatInterval
            self.tightRepeatInterval = tightRepeatInterval
            self.impossibleRepeatInterval = impossibleRepeatInterval
            self.minimumTargetChangeKph = minimumTargetChangeKph
            self.minimumGapSeconds = minimumGapSeconds
        }

        public static let standard = Policy()

        func repeatInterval(for tier: CoachingTier) -> TimeInterval {
            switch tier {
            case .normal: return normalRepeatInterval
            case .tight: return tightRepeatInterval
            case .impossible: return impossibleRepeatInterval
            }
        }
    }

    public let policy: Policy

    public private(set) var lastSpokenTier: CoachingTier?
    public private(set) var lastSpokenTargetKph: Double?
    public private(set) var lastSpokenAt: Date?

    public init(policy: Policy = .standard) {
        self.policy = policy
    }

    /// Returns true when this advice should be spoken, and records that it was.
    @discardableResult
    public mutating func shouldAnnounce(_ advice: CoachingAdvice, at now: Date) -> Bool {
        guard !advice.isSuppressed else {
            // Forget what was last said. When the traffic clears, the driver
            // gets a fresh instruction rather than silence because the tier
            // happens to match what was announced ten minutes ago.
            lastSpokenTier = nil
            lastSpokenTargetKph = nil
            return false
        }

        if let lastSpokenAt, now.timeIntervalSince(lastSpokenAt) < policy.minimumGapSeconds {
            return false
        }

        if advice.tier != lastSpokenTier {
            record(advice, at: now)
            return true
        }

        if let target = advice.targetSpeedKph, let previous = lastSpokenTargetKph,
           abs(target - previous) >= policy.minimumTargetChangeKph {
            record(advice, at: now)
            return true
        }

        if let lastSpokenAt,
           now.timeIntervalSince(lastSpokenAt) >= policy.repeatInterval(for: advice.tier) {
            record(advice, at: now)
            return true
        }

        if lastSpokenAt == nil {
            record(advice, at: now)
            return true
        }

        return false
    }

    public mutating func reset() {
        lastSpokenTier = nil
        lastSpokenTargetKph = nil
        lastSpokenAt = nil
    }

    private mutating func record(_ advice: CoachingAdvice, at now: Date) {
        lastSpokenTier = advice.tier
        lastSpokenTargetKph = advice.targetSpeedKph
        lastSpokenAt = now
    }
}
