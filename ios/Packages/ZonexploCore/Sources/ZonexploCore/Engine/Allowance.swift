import Foundation

/// The state of a driver's time budget inside a zone.
///
/// Everything here derives from two measured quantities - distance covered and
/// time elapsed - and one constant, the zone's minimum legal traversal time.
/// Instantaneous speed appears nowhere. That is deliberate: the exit camera
/// does not care how fast you were going, only how long you took.
public struct Allowance: Sendable, Equatable {
    public let zoneDistanceMeters: Double
    public let distanceCoveredMeters: Double
    public let distanceRemainingMeters: Double
    public let elapsedSeconds: TimeInterval

    /// `zoneDistance / limit` - the fastest legal traversal.
    public let minimumLegalSeconds: TimeInterval

    /// How much more time the driver must still spend in the zone to come out
    /// legal. Negative means they have already spent longer than the minimum,
    /// so the exit camera cannot catch them whatever they do next.
    public let remainingTimeBudgetSeconds: TimeInterval

    /// Average so far. This is the number the exit camera is accumulating.
    public let currentAverageKph: Double

    /// The highest average the driver may hold over the remaining distance and
    /// still exit legal.
    ///
    /// `nil` means unconstrained: either they are already home (the budget is
    /// spent) or there is no distance left to constrain.
    ///
    /// Note the counterintuitive shape of this number. A *large* remaining
    /// budget with *little* distance left produces a *low* allowance - that is
    /// the driver who sped early and must now dawdle to let the clock catch up.
    public let maxRemainingAverageKph: Double?

    /// What the final average would be if the driver held exactly the limit
    /// from here to the exit. Above the limit means they are already committed
    /// to a fine unless they slow down or stop.
    public let projectedFinalAverageKph: Double

    public var isPastZoneEnd: Bool { distanceRemainingMeters <= 0 }

    /// True when the driver can no longer be caught by the exit camera.
    public var isBanked: Bool { remainingTimeBudgetSeconds <= 0 }
}

public enum AllowanceCalculator {
    /// Computes the allowance from total distance over total time.
    ///
    /// - Parameters:
    ///   - zone: the section being driven.
    ///   - distanceCovered: metres travelled from the entry line, measured
    ///     along the road, not as the crow flies.
    ///   - elapsed: seconds since the *true* entry crossing, not since the
    ///     geofence woke us up.
    public static func compute(
        zone: Zone,
        distanceCovered: Double,
        elapsed: TimeInterval
    ) -> Allowance {
        let covered = min(max(distanceCovered, 0), zone.distanceMeters)
        let remaining = max(zone.distanceMeters - covered, 0)
        let elapsedSeconds = max(elapsed, 0)

        let minimumLegal = zone.minimumLegalSeconds
        let budget = minimumLegal - elapsedSeconds

        let currentAverage = elapsedSeconds > 0
            ? Units.kph(fromMps: covered / elapsedSeconds)
            : 0

        let maxRemainingAverage: Double?
        if budget <= 0 || remaining <= 0 {
            // Either the clock is already long enough, or there is nothing left
            // to drive. Both mean "no constraint".
            maxRemainingAverage = nil
        } else {
            maxRemainingAverage = Units.kph(fromMps: remaining / budget)
        }

        let limitMps = Units.mps(fromKph: zone.speedLimitKph)
        let timeIfHoldingLimit = elapsedSeconds + (remaining / limitMps)
        let projectedFinal = timeIfHoldingLimit > 0
            ? Units.kph(fromMps: zone.distanceMeters / timeIfHoldingLimit)
            : 0

        return Allowance(
            zoneDistanceMeters: zone.distanceMeters,
            distanceCoveredMeters: covered,
            distanceRemainingMeters: remaining,
            elapsedSeconds: elapsedSeconds,
            minimumLegalSeconds: minimumLegal,
            remainingTimeBudgetSeconds: budget,
            currentAverageKph: currentAverage,
            maxRemainingAverageKph: maxRemainingAverage,
            projectedFinalAverageKph: projectedFinal
        )
    }
}
