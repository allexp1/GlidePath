import Foundation

/// Decides whether the driver has actually left the zone's road.
///
/// A single fix 200 metres off the path means nothing - it happens under
/// bridges, in tunnels, beside tall buildings, and every time the receiver
/// re-acquires. Cancelling a session on one bad fix would make the app
/// infuriating on exactly the roads it is meant for.
///
/// So divergence has to persist. The clock starts on the first off-path fix and
/// only fires once the driver has been continuously off-path for the
/// confirmation window. One fix back on the path resets it completely.
public struct DeviationDetector: Sendable, Equatable {
    public let thresholdMeters: Double
    public let confirmationSeconds: TimeInterval

    /// When the current run of off-path fixes began, or nil when the driver is
    /// on the path.
    public private(set) var divergingSince: Date?

    public init(thresholdMeters: Double = 60, confirmationSeconds: TimeInterval = 5) {
        self.thresholdMeters = thresholdMeters
        self.confirmationSeconds = confirmationSeconds
    }

    /// How long the driver has been continuously off-path as of `timestamp`, or
    /// nil if they are on it. Lets the UI show a "still with you" state before
    /// the session is actually cancelled.
    public func divergenceDuration(at timestamp: Date) -> TimeInterval? {
        divergingSince.map { timestamp.timeIntervalSince($0) }
    }

    /// - Returns: true once divergence has been confirmed for long enough.
    @discardableResult
    public mutating func update(crossTrackDistance: Double, at timestamp: Date) -> Bool {
        guard crossTrackDistance > thresholdMeters else {
            divergingSince = nil
            return false
        }

        guard let since = divergingSince else {
            divergingSince = timestamp
            return false
        }

        return timestamp.timeIntervalSince(since) >= confirmationSeconds
    }

    public mutating func reset() {
        divergingSince = nil
    }
}
