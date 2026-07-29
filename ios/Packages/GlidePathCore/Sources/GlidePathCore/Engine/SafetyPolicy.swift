import Foundation

/// Every tunable in the engine, in one place.
///
/// The important one is the coaching floor. GlidePath's whole trick is telling
/// a driver to slow down, and a naive implementation of that will happily tell
/// someone to do 18 km/h in the outside lane of a motorway because the maths
/// said so. That is more dangerous than the fine. The floor is the hard stop
/// that prevents it, and it is not optional or user-adjustable.
public struct SafetyPolicy: Sendable, Equatable {
    /// Never coach below this, on any road, ever.
    public var absoluteFloorKph: Double

    /// Never coach below this fraction of the posted limit. On a 110 km/h road
    /// this puts the floor at 55 km/h, which is slow but not a hazard.
    public var fractionOfLimitFloor: Double

    /// Below this speed the driver is in traffic, not speeding. Coaching goes
    /// quiet rather than shouting a target they cannot act on.
    public var jamSuppressionKph: Double

    /// How far off the zone's road path counts as having left it.
    public var deviationDistanceMeters: Double

    /// How long that has to hold before the session is cancelled. A single bad
    /// fix under a bridge must not end the session.
    public var deviationConfirmationSeconds: TimeInterval

    /// Window for smoothing instantaneous speed. Display only - never feeds the
    /// allowance.
    public var speedSmoothingWindow: TimeInterval

    /// Fixes worse than this are dropped rather than believed.
    public var maximumUsableAccuracyMeters: Double

    /// Distance either side of the entry line within which we start looking for
    /// the true crossing.
    public var entryCaptureRadiusMeters: Double

    public init(
        absoluteFloorKph: Double = 30,
        fractionOfLimitFloor: Double = 0.5,
        jamSuppressionKph: Double = 10,
        deviationDistanceMeters: Double = 60,
        deviationConfirmationSeconds: TimeInterval = 5,
        speedSmoothingWindow: TimeInterval = 4,
        maximumUsableAccuracyMeters: Double = 50,
        entryCaptureRadiusMeters: Double = 400
    ) {
        self.absoluteFloorKph = absoluteFloorKph
        self.fractionOfLimitFloor = fractionOfLimitFloor
        self.jamSuppressionKph = jamSuppressionKph
        self.deviationDistanceMeters = deviationDistanceMeters
        self.deviationConfirmationSeconds = deviationConfirmationSeconds
        self.speedSmoothingWindow = speedSmoothingWindow
        self.maximumUsableAccuracyMeters = maximumUsableAccuracyMeters
        self.entryCaptureRadiusMeters = entryCaptureRadiusMeters
    }

    public static let standard = SafetyPolicy()

    /// The slowest speed GlidePath is willing to ask for in this zone.
    ///
    /// Takes the strictest of: the absolute floor, a fraction of the limit, and
    /// any posted legal minimum. Then caps the result at the limit itself, so a
    /// 20 km/h zone does not end up with a 30 km/h "floor" above its own limit.
    public func coachingFloorKph(for zone: Zone) -> Double {
        let candidates = [
            absoluteFloorKph,
            zone.speedLimitKph * fractionOfLimitFloor,
            zone.minimumSpeedKph ?? 0
        ]
        let floor = candidates.reduce(0, Swift.max)
        return Swift.min(floor, zone.speedLimitKph)
    }
}
