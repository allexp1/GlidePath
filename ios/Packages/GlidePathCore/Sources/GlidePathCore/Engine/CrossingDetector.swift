import Foundation

/// Finds the moment a driver crossed a line, and timestamps it properly.
///
/// This exists because of how iOS geofencing works. The entry radius has to be
/// generous - several hundred metres - so that the high-accuracy receiver has
/// woken and locked before the driver reaches the real entry camera. That means
/// the wake-up happens well before the crossing, at a position that is not the
/// crossing, at a time that is not the crossing time.
///
/// Timestamping the wake-up instead of the crossing would start the clock early.
/// An early clock inflates elapsed time, which inflates the allowance, which
/// tells the driver they can go faster than they can. The error is in exactly
/// the wrong direction, so the crossing time is interpolated between the last
/// fix before the line and the first fix after it.
public struct CrossingDetector: Sendable, Equatable {
    /// Signed distance to the line, negative on the approach side.
    public typealias SignedDistance = Double

    private var previous: (distance: SignedDistance, timestamp: Date)?
    public private(set) var crossedAt: Date?

    public init() {}

    public var hasCrossed: Bool { crossedAt != nil }

    /// Feeds one observation. Returns the interpolated crossing time on the
    /// update where the sign flips, and nil otherwise.
    @discardableResult
    public mutating func update(signedDistance: SignedDistance, at timestamp: Date) -> Date? {
        defer { previous = (signedDistance, timestamp) }

        guard crossedAt == nil else { return nil }

        // First fix already past the line: we joined late and have nothing to
        // interpolate against. Take the fix time - it is the best we have, and
        // it is late rather than early, which is the safe direction to be wrong.
        guard let last = previous else {
            if signedDistance >= 0 {
                crossedAt = timestamp
                return timestamp
            }
            return nil
        }

        guard last.distance < 0, signedDistance >= 0 else { return nil }

        let span = signedDistance - last.distance
        guard span > 0 else {
            crossedAt = timestamp
            return timestamp
        }

        let fraction = -last.distance / span
        let interval = timestamp.timeIntervalSince(last.timestamp)
        let crossing = last.timestamp.addingTimeInterval(fraction * interval)

        crossedAt = crossing
        return crossing
    }

    public mutating func reset() {
        previous = nil
        crossedAt = nil
    }
}
