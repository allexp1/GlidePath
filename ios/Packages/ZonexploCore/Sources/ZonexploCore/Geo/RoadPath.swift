import Foundation

/// The polyline a zone follows, with cumulative distances precomputed.
///
/// Two jobs, both central to the engine:
///
/// 1. **Progress.** Projecting a GPS fix onto the polyline gives distance
///    travelled along the road. This is what makes the allowance math robust
///    to GPS jitter - lateral noise moves the cross-track distance, not the
///    along-track distance, so a wobbling fix does not inflate the odometer
///    the way summing point-to-point hops does.
/// 2. **Deviation.** The cross-track distance says how far off the zone's road
///    the driver is, which is how we notice they turned off.
public struct RoadPath: Sendable, Equatable, Codable {
    public let coordinates: [Coordinate]

    /// `cumulativeDistances[i]` is the distance along the path to
    /// `coordinates[i]`. Always starts at 0 and has the same count as
    /// `coordinates`.
    public let cumulativeDistances: [Double]

    public var totalDistance: Double { cumulativeDistances.last ?? 0 }
    public var start: Coordinate { coordinates[0] }
    public var end: Coordinate { coordinates[coordinates.count - 1] }

    /// Fails for fewer than two points, or for a path with no length.
    public init?(coordinates: [Coordinate]) {
        guard coordinates.count >= 2 else { return nil }

        var cumulative = [0.0]
        cumulative.reserveCapacity(coordinates.count)
        for index in 1..<coordinates.count {
            let step = coordinates[index - 1].distance(to: coordinates[index])
            cumulative.append(cumulative[index - 1] + step)
        }
        guard let total = cumulative.last, total > 0 else { return nil }

        self.coordinates = coordinates
        self.cumulativeDistances = cumulative
    }

    public struct Projection: Sendable, Equatable {
        /// Distance along the path to the nearest point, clamped to
        /// `0...totalDistance`.
        public let distanceAlong: Double

        /// Like `distanceAlong`, but allowed to run negative before the start
        /// of the path and past `totalDistance` after the end. This is what
        /// entry and exit crossing detection needs: a signed value whose sign
        /// change *is* the crossing.
        public let extendedDistanceAlong: Double

        /// Perpendicular distance from the path, in metres. Always >= 0.
        public let crossTrackDistance: Double

        public let segmentIndex: Int
    }

    /// Nearest-point projection of `coordinate` onto the polyline.
    public func project(_ coordinate: Coordinate) -> Projection {
        var best: Projection?
        var bestDistance = Double.infinity

        for index in 0..<(coordinates.count - 1) {
            let segmentStart = coordinates[index]
            let segmentEnd = coordinates[index + 1]
            let segmentLength = cumulativeDistances[index + 1] - cumulativeDistances[index]
            guard segmentLength > 0 else { continue }

            // Work in a local flat frame anchored at the segment start.
            let end = segmentEnd.localOffset(from: segmentStart)
            let point = coordinate.localOffset(from: segmentStart)

            let lengthSquared = end.east * end.east + end.north * end.north
            guard lengthSquared > 0 else { continue }

            let rawT = (point.east * end.east + point.north * end.north) / lengthSquared
            let clampedT = min(max(rawT, 0), 1)

            let nearestEast = end.east * clampedT
            let nearestNorth = end.north * clampedT
            let dEast = point.east - nearestEast
            let dNorth = point.north - nearestNorth
            let crossTrack = (dEast * dEast + dNorth * dNorth).squareRoot()

            guard crossTrack < bestDistance else { continue }
            bestDistance = crossTrack

            let along = cumulativeDistances[index] + clampedT * segmentLength

            // Only the first and last segments are allowed to extend past the
            // ends of the path. An out-of-range t in the middle just means the
            // point sits beside a bend, and extending there would be nonsense.
            var extended = along
            if index == 0, rawT < 0 {
                extended = rawT * segmentLength
            } else if index == coordinates.count - 2, rawT > 1 {
                extended = cumulativeDistances[index] + rawT * segmentLength
            }

            best = Projection(
                distanceAlong: along,
                extendedDistanceAlong: extended,
                crossTrackDistance: crossTrack,
                segmentIndex: index
            )
        }

        // `init?` guarantees at least one positive-length segment, so `best` is
        // always populated by here. The fallback keeps the API non-optional
        // without a force unwrap.
        return best ?? Projection(
            distanceAlong: 0,
            extendedDistanceAlong: 0,
            crossTrackDistance: coordinate.distance(to: start),
            segmentIndex: 0
        )
    }

    /// The path cut in two at `distance` along it.
    ///
    /// For drawing the section on a map as two strokes - what is behind the
    /// driver and what is still ahead. The cut point appears in both halves, so
    /// the strokes meet exactly rather than leaving a gap at the join that
    /// would read as a break in the road.
    ///
    /// Either half can be empty (at the very start or the very end), and a half
    /// of fewer than two points draws nothing, which is correct.
    public func split(atDistance distance: Double) -> (covered: [Coordinate], remaining: [Coordinate]) {
        guard distance > 0 else { return ([], coordinates) }
        guard distance < totalDistance else { return (coordinates, []) }

        let cut = coordinate(atDistance: distance)

        // The segment `distance` falls inside. Same walk as
        // `coordinate(atDistance:)`, so the two agree by construction.
        var index = 0
        while index < cumulativeDistances.count - 1, cumulativeDistances[index + 1] < distance {
            index += 1
        }

        return (
            Array(coordinates[0...index]) + [cut],
            [cut] + Array(coordinates[(index + 1)...])
        )
    }

    /// The compass bearing of one segment, in degrees clockwise from true north.
    ///
    /// This is the direction the road runs at that point, which is what tells a
    /// driver's course apart from a road that merely passes nearby: a junction
    /// puts two roads within a few metres of each other, and only their headings
    /// say which one the car is actually on.
    ///
    /// Returns nil for an index outside the path.
    public func bearing(atSegment index: Int) -> Double? {
        guard index >= 0, index < coordinates.count - 1 else { return nil }
        return coordinates[index].bearing(to: coordinates[index + 1])
    }

    /// The coordinate at `distance` metres along the path, interpolating within
    /// the segment it falls in. Used to place rest stops and to render progress.
    public func coordinate(atDistance distance: Double) -> Coordinate {
        if distance <= 0 { return start }
        if distance >= totalDistance { return end }

        var index = 0
        while index < cumulativeDistances.count - 1, cumulativeDistances[index + 1] < distance {
            index += 1
        }

        let segmentLength = cumulativeDistances[index + 1] - cumulativeDistances[index]
        guard segmentLength > 0 else { return coordinates[index] }

        let t = (distance - cumulativeDistances[index]) / segmentLength
        let from = coordinates[index]
        let to = coordinates[index + 1]
        return Coordinate(
            latitude: from.latitude + (to.latitude - from.latitude) * t,
            longitude: from.longitude + (to.longitude - from.longitude) * t
        )
    }
}
