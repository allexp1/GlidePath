import Foundation

/// The three tiers the product is built around.
public enum CoachingTier: String, Sendable, Equatable, CaseIterable {
    /// The driver can hold the posted limit and still exit legal. This covers
    /// both "you have not overspent" and "you have already banked enough time
    /// that the camera cannot touch you".
    case normal

    /// The driver overspent early. There is still a speed that saves them, and
    /// it is above the safety floor, so we coach it.
    case tight

    /// No legal, safe speed saves them any more. Only stopping the clock does.
    case impossible
}

/// How to claw back a blown time budget, when driving alone cannot.
public enum Recovery: Sendable, Equatable {
    /// Stop for `seconds` at `stop`, then carry on at the limit.
    ///
    /// `seconds` assumes the driver resumes at the posted limit afterwards,
    /// which is the realistic behaviour and errs on the generous side. Crawling
    /// after the stop would need slightly less.
    case pause(seconds: TimeInterval, stop: RestStop, distanceToStopMeters: Double)

    /// Nowhere to stop inside the zone. Say so plainly rather than inventing
    /// advice - the driver deserves to know the fine is coming.
    case unrecoverable(shortfallSeconds: TimeInterval)
}

public struct CoachingAdvice: Sendable, Equatable {
    public let tier: CoachingTier

    /// The speed to hold, in km/h, already rounded to something a driver can
    /// aim at. `nil` only when advice is suppressed.
    public let targetSpeedKph: Double?

    /// Present on the `.impossible` tier.
    public let recovery: Recovery?

    /// True in stop-start traffic, where a target speed is noise. The UI keeps
    /// showing live numbers; the voice stays quiet.
    public let isSuppressed: Bool

    public let allowance: Allowance
    public let zoneID: String
    public let speedLimitKph: Double

    /// The floor that was applied when producing `targetSpeedKph`. Exposed so
    /// the UI can explain why it is not coaching something slower.
    public let safetyFloorKph: Double

    public var distanceRemainingMeters: Double { allowance.distanceRemainingMeters }
    public var currentAverageKph: Double { allowance.currentAverageKph }
}

public struct CoachingEngine: Sendable {
    public let policy: SafetyPolicy

    public init(policy: SafetyPolicy = .standard) {
        self.policy = policy
    }

    /// Turns an allowance into something to say.
    ///
    /// - Parameters:
    ///   - smoothedSpeedKph: current speed, smoothed. Used only to decide
    ///     whether the driver is in a jam, never to compute the target. Pass
    ///     `nil` when the receiver is not reporting speed - unknown must not be
    ///     read as stationary, or coaching would go silent on every device that
    ///     withholds a speed reading.
    public func advise(
        zone: Zone,
        allowance: Allowance,
        smoothedSpeedKph: Double?
    ) -> CoachingAdvice {
        let floor = policy.coachingFloorKph(for: zone)
        let suppressed = (smoothedSpeedKph ?? .greatestFiniteMagnitude) < policy.jamSuppressionKph

        // No distance left, or enough time already banked: hold the limit.
        guard !allowance.isPastZoneEnd, let maxRemaining = allowance.maxRemainingAverageKph else {
            return CoachingAdvice(
                tier: .normal,
                targetSpeedKph: suppressed ? nil : zone.speedLimitKph,
                recovery: nil,
                isSuppressed: suppressed,
                allowance: allowance,
                zoneID: zone.id,
                speedLimitKph: zone.speedLimitKph,
                safetyFloorKph: floor
            )
        }

        // Tolerance, not exact comparison: a driver holding exactly the limit
        // produces an allowance of exactly the limit at every point in the
        // zone, and without slack here the tier flips on noise. See
        // SafetyPolicy.limitToleranceKph.
        if maxRemaining >= zone.speedLimitKph - policy.limitToleranceKph {
            return CoachingAdvice(
                tier: .normal,
                targetSpeedKph: suppressed ? nil : zone.speedLimitKph,
                recovery: nil,
                isSuppressed: suppressed,
                allowance: allowance,
                zoneID: zone.id,
                speedLimitKph: zone.speedLimitKph,
                safetyFloorKph: floor
            )
        }

        if maxRemaining >= floor {
            // Round down so the spoken number is never above the true allowance.
            let target = max(maxRemaining.roundedDownToCoachableSpeed(), floor)
            return CoachingAdvice(
                tier: .tight,
                targetSpeedKph: suppressed ? nil : target,
                recovery: nil,
                isSuppressed: suppressed,
                allowance: allowance,
                zoneID: zone.id,
                speedLimitKph: zone.speedLimitKph,
                safetyFloorKph: floor
            )
        }

        // Below the floor. Driving cannot save this; only time can.
        return CoachingAdvice(
            tier: .impossible,
            targetSpeedKph: suppressed ? nil : floor,
            recovery: recovery(for: zone, allowance: allowance),
            isSuppressed: suppressed,
            allowance: allowance,
            zoneID: zone.id,
            speedLimitKph: zone.speedLimitKph,
            safetyFloorKph: floor
        )
    }

    /// How long the driver must stop, and where.
    ///
    /// Guaranteed positive on the `.impossible` tier: that tier is reached only
    /// when the remaining allowance is below the floor, which is at or below the
    /// limit, which makes the pause strictly greater than zero.
    private func recovery(for zone: Zone, allowance: Allowance) -> Recovery {
        let limitMps = Units.mps(fromKph: zone.speedLimitKph)
        let pauseSeconds = allowance.remainingTimeBudgetSeconds
            - (allowance.distanceRemainingMeters / limitMps)

        let position = allowance.distanceCoveredMeters
        let ahead = zone.orderedRestStops.first { stop in
            guard let along = stop.distanceAlongMeters else { return false }
            // Needs to be far enough ahead that the driver can still react.
            return along > position + 150 && along < zone.distanceMeters
        }

        guard let stop = ahead, let along = stop.distanceAlongMeters else {
            return .unrecoverable(shortfallSeconds: max(pauseSeconds, 0))
        }

        return .pause(
            seconds: max(pauseSeconds, 0),
            stop: stop,
            distanceToStopMeters: along - position
        )
    }
}
