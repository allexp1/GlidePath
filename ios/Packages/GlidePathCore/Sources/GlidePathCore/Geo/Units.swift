import Foundation

/// Every number inside the engine is SI: metres, seconds, metres per second.
/// Kilometres per hour exist only at the edges - what the database stores and
/// what the driver hears. These two functions are the only crossing points.
public enum Units {
    public static let metersPerSecondPerKph = 1.0 / 3.6

    @inlinable
    public static func kph(fromMps mps: Double) -> Double {
        mps * 3.6
    }

    @inlinable
    public static func mps(fromKph kph: Double) -> Double {
        kph / 3.6
    }
}

public extension Double {
    /// Rounds a coached speed down to a value a driver can actually aim at.
    ///
    /// Always rounds *down*, never up: rounding a 82.4 km/h allowance up to 85
    /// would coach the driver into a fine. Rounding it down to 80 costs a few
    /// seconds and keeps them legal.
    func roundedDownToCoachableSpeed(step: Double = 5) -> Double {
        guard step > 0 else { return self }
        return (self / step).rounded(.down) * step
    }
}
