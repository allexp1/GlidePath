import Foundation

/// Decides when being over the posted limit is worth saying out loud.
///
/// The hard part is not detecting the exceedance, it is not becoming noise. A
/// speed alert that fires on every overshoot gets muted within a week, and a
/// muted alert warns nobody about anything, so every threshold here exists to
/// buy silence:
///
/// - **A tolerance, absolute and proportional.** Speedometers are required by
///   regulation to never under-read and typically show around 5% high, so a
///   driver whose dial says 95 is often doing 90. Alerting at the limit exactly
///   would fire at a speed the driver believes is legal - and be right, which is
///   worse, because they cannot see what the app can. The proportional half is
///   what stops a fixed margin being lenient on a 30 street and pedantic on a
///   130 motorway.
/// - **A sustained period.** Overtaking, a downhill, the moment a limit drops.
///   All of them cross the tolerance and come back on their own within a couple
///   of seconds, and none of them need saying.
/// - **A repeat interval.** Somebody knowingly holding 100 in a 90 does not need
///   telling every four seconds. They were told.
/// - **A floor.** Below about 25 km/h, GPS speed is unreliable enough that the
///   exceedance may not be real, and a 10 km/h living-street limit would
///   otherwise alert on a car park manoeuvre.
///
/// Moving to a road with a different limit clears the state, so the first
/// exceedance on a new limit is announced promptly rather than waiting out the
/// previous road's cooldown.
public struct SpeedLimitMonitor: Sendable {
    public struct Thresholds: Sendable, Equatable {
        /// The floor of the allowance, in km/h.
        public var absoluteToleranceKph: Double

        /// The allowance as a fraction of the limit. The larger of the two wins.
        public var relativeTolerance: Double

        /// How long the driver must stay over before it is worth saying.
        public var sustainedSeconds: TimeInterval

        /// The soonest the same limit will be mentioned again.
        public var repeatInterval: TimeInterval

        /// Below this, say nothing at all.
        public var minimumSpeedKph: Double

        public init(
            absoluteToleranceKph: Double = 7,
            relativeTolerance: Double = 0.08,
            sustainedSeconds: TimeInterval = 4,
            repeatInterval: TimeInterval = 60,
            minimumSpeedKph: Double = 25
        ) {
            self.absoluteToleranceKph = absoluteToleranceKph
            self.relativeTolerance = relativeTolerance
            self.sustainedSeconds = sustainedSeconds
            self.repeatInterval = repeatInterval
            self.minimumSpeedKph = minimumSpeedKph
        }

        /// The allowance for a given limit: 7 km/h up to about 88, proportional
        /// above it.
        public func allowance(for limitKph: Double) -> Double {
            max(absoluteToleranceKph, limitKph * relativeTolerance)
        }

        public static let standard = Thresholds()
    }

    public struct Exceedance: Sendable, Equatable {
        public let limitKph: Double
        public let speedKph: Double

        public var overByKph: Double { speedKph - limitKph }

        public init(limitKph: Double, speedKph: Double) {
            self.limitKph = limitKph
            self.speedKph = speedKph
        }
    }

    public let thresholds: Thresholds

    private var activeLimitKph: Double?
    private var overSince: Date?
    private var lastSpokenAt: Date?

    public init(thresholds: Thresholds = .standard) {
        self.thresholds = thresholds
    }

    /// - Parameter limitKph: the limit for the road the driver is on, or nil
    ///   when there is no limit data for it. Nil is a normal, common state and
    ///   simply produces silence.
    /// - Returns: an exceedance worth announcing, or nil.
    public mutating func update(fix: LocationFix, limitKph: Double?) -> Exceedance? {
        guard let limitKph else {
            // Left the road, or ran out of data. Forget everything: coming back
            // onto the same limit later is a fresh event, not a continuation.
            activeLimitKph = nil
            overSince = nil
            lastSpokenAt = nil
            return nil
        }

        if activeLimitKph != limitKph {
            activeLimitKph = limitKph
            overSince = nil
            lastSpokenAt = nil
        }

        guard let speedKph = fix.speedKph, speedKph >= thresholds.minimumSpeedKph else {
            overSince = nil
            return nil
        }

        guard speedKph - limitKph >= thresholds.allowance(for: limitKph) else {
            overSince = nil
            return nil
        }

        guard let since = overSince else {
            overSince = fix.timestamp
            return nil
        }

        guard fix.timestamp.timeIntervalSince(since) >= thresholds.sustainedSeconds else {
            return nil
        }

        if let last = lastSpokenAt,
           fix.timestamp.timeIntervalSince(last) < thresholds.repeatInterval {
            return nil
        }

        lastSpokenAt = fix.timestamp
        return Exceedance(limitKph: limitKph, speedKph: speedKph)
    }

    public mutating func reset() {
        activeLimitKph = nil
        overSince = nil
        lastSpokenAt = nil
    }
}
