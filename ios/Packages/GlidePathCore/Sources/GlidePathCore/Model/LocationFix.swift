import Foundation

/// One GPS reading, stripped of CoreLocation.
public struct LocationFix: Sendable, Equatable {
    public let coordinate: Coordinate
    public let timestamp: Date

    /// Instantaneous speed in metres per second, or nil when the receiver could
    /// not determine one. Never trusted for the allowance math - only smoothed
    /// for display and for jam detection.
    public let speedMps: Double?

    /// Radius of 68% confidence in metres. Negative means invalid.
    public let horizontalAccuracy: Double

    /// Direction of travel in degrees from true north, or nil when unknown
    /// (which is normal below walking pace).
    public let courseDegrees: Double?

    public init(
        coordinate: Coordinate,
        timestamp: Date,
        speedMps: Double? = nil,
        horizontalAccuracy: Double = 5,
        courseDegrees: Double? = nil
    ) {
        self.coordinate = coordinate
        self.timestamp = timestamp
        self.speedMps = speedMps
        self.horizontalAccuracy = horizontalAccuracy
        self.courseDegrees = courseDegrees
    }

    public var speedKph: Double? {
        guard let speedMps, speedMps >= 0 else { return nil }
        return Units.kph(fromMps: speedMps)
    }

    public func isUsable(maximumAccuracyMeters: Double) -> Bool {
        horizontalAccuracy >= 0 && horizontalAccuracy <= maximumAccuracyMeters
    }
}
