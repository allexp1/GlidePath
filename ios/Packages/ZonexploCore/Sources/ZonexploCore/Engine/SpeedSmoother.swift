import Foundation

/// Rolling mean of instantaneous speed over a short window.
///
/// Display and jam detection only. The allowance math never touches this - it
/// works from total distance over total time, which is what the exit camera
/// measures and what GPS noise cannot inflate.
public struct SpeedSmoother: Sendable, Equatable {
    private struct Sample: Sendable, Equatable {
        let timestamp: Date
        let speedKph: Double
    }

    private var samples: [Sample] = []
    public let window: TimeInterval

    public init(window: TimeInterval = 4) {
        self.window = window
    }

    public mutating func add(speedKph: Double, at timestamp: Date) {
        samples.append(Sample(timestamp: timestamp, speedKph: max(speedKph, 0)))
        let cutoff = timestamp.addingTimeInterval(-window)
        samples.removeAll { $0.timestamp < cutoff }
    }

    /// Mean over the window, or 0 when nothing has been recorded yet.
    public var smoothedKph: Double {
        guard !samples.isEmpty else { return 0 }
        let total = samples.reduce(0) { $0 + $1.speedKph }
        return total / Double(samples.count)
    }

    public var hasSamples: Bool { !samples.isEmpty }

    public mutating func reset() {
        samples.removeAll()
    }
}
