import Foundation

/// Builds a stream of GPS fixes for a scripted drive along a road path.
///
/// GPX files are good for replaying a real drive; this is for the opposite job,
/// where a test needs a drive with exact properties - "cover the first 9 km at
/// 150, then the rest at 30" - so the expected allowance can be computed by
/// hand and asserted against.
public struct DriveSimulator: Sendable {
    public enum Step: Sendable, Equatable {
        /// Cover `distanceMeters` at a steady `speedKph`.
        case drive(speedKph: Double, distanceMeters: Double)
        /// Sit still for `seconds`. The clock runs, the odometer does not.
        case stop(seconds: TimeInterval)
    }

    public struct Options: Sendable {
        public var sampleInterval: TimeInterval
        public var horizontalAccuracy: Double

        /// Metres of pseudo-random lateral noise applied to each fix.
        /// Deterministic for a given `jitterSeed`.
        public var jitterMeters: Double
        public var jitterSeed: UInt64

        /// How far before the start of the path to begin. Entry detection needs
        /// at least one fix on the approach side of the line to interpolate the
        /// crossing time from.
        public var leadInMeters: Double

        /// How far past the end of the path to continue, so the exit crossing
        /// gets detected too.
        public var runOutMeters: Double

        public init(
            sampleInterval: TimeInterval = 1,
            horizontalAccuracy: Double = 5,
            jitterMeters: Double = 0,
            jitterSeed: UInt64 = 0x5EED,
            leadInMeters: Double = 300,
            runOutMeters: Double = 200
        ) {
            self.sampleInterval = sampleInterval
            self.horizontalAccuracy = horizontalAccuracy
            self.jitterMeters = jitterMeters
            self.jitterSeed = jitterSeed
            self.leadInMeters = leadInMeters
            self.runOutMeters = runOutMeters
        }

        public static let standard = Options()
    }

    /// Deterministic linear congruential generator. Tests must fail for a code
    /// change, never for an unlucky roll.
    private struct Random {
        private var state: UInt64
        init(seed: UInt64) { state = seed &* 6_364_136_223_846_793_005 &+ 1 }

        /// Uniform in -1...1.
        mutating func nextSigned() -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let unit = Double(state >> 11) / Double(UInt64(1) << 53)
            return unit * 2 - 1
        }
    }

    /// Generates the fix stream.
    ///
    /// The lead-in is driven at the speed of the first step, and the run-out at
    /// the speed of the last, so the driver arrives at and leaves the zone
    /// moving rather than teleporting.
    public static func fixes(
        along path: RoadPath,
        steps: [Step],
        startingAt start: Date,
        options: Options = .standard
    ) -> [LocationFix] {
        guard !steps.isEmpty else { return [] }

        var samples: [(distance: Double, time: Date)] = []
        var distance = -options.leadInMeters
        var time = start

        let firstSpeed = steps.compactMap { step -> Double? in
            if case let .drive(speedKph, _) = step { return speedKph }
            return nil
        }.first ?? 50

        let lastSpeed = steps.compactMap { step -> Double? in
            if case let .drive(speedKph, _) = step { return speedKph }
            return nil
        }.last ?? firstSpeed

        // Lead-in.
        appendDrive(
            &samples, &distance, &time,
            speedKph: firstSpeed,
            distanceMeters: options.leadInMeters,
            interval: options.sampleInterval
        )

        for step in steps {
            switch step {
            case let .drive(speedKph, distanceMeters):
                appendDrive(
                    &samples, &distance, &time,
                    speedKph: speedKph,
                    distanceMeters: distanceMeters,
                    interval: options.sampleInterval
                )
            case let .stop(seconds):
                var remaining = seconds
                while remaining > 0 {
                    samples.append((distance, time))
                    let tick = min(options.sampleInterval, remaining)
                    time = time.addingTimeInterval(tick)
                    remaining -= tick
                }
            }
        }

        // Run-out past the exit line.
        appendDrive(
            &samples, &distance, &time,
            speedKph: lastSpeed,
            distanceMeters: options.runOutMeters,
            interval: options.sampleInterval
        )

        var random = Random(seed: options.jitterSeed)
        var fixes: [LocationFix] = []
        fixes.reserveCapacity(samples.count)

        for (index, sample) in samples.enumerated() {
            var coordinate = coordinateOnPath(path, at: sample.distance)

            if options.jitterMeters > 0 {
                let offset = random.nextSigned() * options.jitterMeters
                let heading = headingOnPath(path, at: sample.distance)
                coordinate = coordinate.offset(meters: abs(offset), bearingDegrees: heading + (offset < 0 ? -90 : 90))
            }

            let previous = index > 0 ? samples[index - 1] : nil
            let interval = previous.map { sample.time.timeIntervalSince($0.time) } ?? 0
            let speed = interval > 0 ? (sample.distance - (previous?.distance ?? 0)) / interval : 0

            fixes.append(
                LocationFix(
                    coordinate: coordinate,
                    timestamp: sample.time,
                    speedMps: max(speed, 0),
                    horizontalAccuracy: options.horizontalAccuracy,
                    courseDegrees: headingOnPath(path, at: sample.distance)
                )
            )
        }

        return fixes
    }

    private static func appendDrive(
        _ samples: inout [(distance: Double, time: Date)],
        _ distance: inout Double,
        _ time: inout Date,
        speedKph: Double,
        distanceMeters: Double,
        interval: TimeInterval
    ) {
        guard distanceMeters > 0, speedKph > 0 else { return }
        let speedMps = Units.mps(fromKph: speedKph)
        let stepDistance = speedMps * interval
        var covered = 0.0

        while covered < distanceMeters {
            samples.append((distance, time))
            let advance = min(stepDistance, distanceMeters - covered)
            distance += advance
            covered += advance
            time = time.addingTimeInterval(advance / speedMps)
        }
    }

    /// Position at `distance` along the path, extrapolating in a straight line
    /// beyond either end.
    private static func coordinateOnPath(_ path: RoadPath, at distance: Double) -> Coordinate {
        if distance < 0 {
            let heading = path.coordinates[1].bearing(to: path.coordinates[0])
            return path.start.offset(meters: -distance, bearingDegrees: heading)
        }
        if distance > path.totalDistance {
            let count = path.coordinates.count
            let heading = path.coordinates[count - 2].bearing(to: path.coordinates[count - 1])
            return path.end.offset(meters: distance - path.totalDistance, bearingDegrees: heading)
        }
        return path.coordinate(atDistance: distance)
    }

    private static func headingOnPath(_ path: RoadPath, at distance: Double) -> Double {
        let ahead = coordinateOnPath(path, at: distance + 5)
        let behind = coordinateOnPath(path, at: max(distance - 5, -1_000_000))
        return behind.bearing(to: ahead)
    }
}
