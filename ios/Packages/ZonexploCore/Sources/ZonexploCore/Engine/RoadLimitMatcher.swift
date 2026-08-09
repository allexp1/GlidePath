import Foundation

/// Works out which road the driver is on, and therefore which limit applies.
///
/// The naive version of this - nearest polyline wins - is wrong in exactly the
/// places a driver notices. A motorway and its parallel service road are twenty
/// metres apart. A slip road hugs the carriageway it leaves for several hundred
/// metres. At a crossroads two roads pass through the same point. In all three
/// cases the nearest line flips back and forth between two answers with
/// different limits, and the app spends the junction announcing and retracting.
///
/// Three things stop that:
///
/// - **A corridor, not a nearest-match.** A road further away than GPS error
///   plus a carriageway width is not a candidate at all, however much nearer it
///   is than everything else.
/// - **Heading agreement.** The cross street at a junction runs across the
///   driver's course, not along it. Comparing bearings removes it outright,
///   which distance alone never can.
/// - **Hysteresis.** Changing roads takes agreement across consecutive fixes,
///   and losing the current road takes more. The cost is a second or so of
///   staleness after a genuine turn; the benefit is that the common case of
///   driving in a straight line past a junction produces no change at all.
public struct RoadLimitMatcher: Sendable {
    public struct Thresholds: Sendable, Equatable {
        /// How far off a road's centreline the driver may be and still be on it.
        /// Covers GPS error plus half a dual carriageway.
        public var corridorMeters: Double

        /// How far the driver's course may differ from the road's heading.
        /// Generous, because a road bends between its simplified points and a
        /// phone's course is noisy.
        public var bearingToleranceDegrees: Double

        /// Consecutive fixes a new road must win before it takes over.
        public var switchConfirmations: Int

        /// Consecutive fixes with no candidate at all before the current road is
        /// given up. Higher than `switchConfirmations`: a single bad fix in a
        /// cutting should not blank the limit on screen.
        public var dropConfirmations: Int

        public init(
            corridorMeters: Double = 30,
            bearingToleranceDegrees: Double = 55,
            switchConfirmations: Int = 2,
            dropConfirmations: Int = 4
        ) {
            self.corridorMeters = corridorMeters
            self.bearingToleranceDegrees = bearingToleranceDegrees
            self.switchConfirmations = switchConfirmations
            self.dropConfirmations = dropConfirmations
        }

        public static let standard = Thresholds()
    }

    public struct Match: Sendable, Equatable {
        public let road: RoadLimit

        /// The limit for the direction the driver is actually travelling.
        public let limitKph: Double

        /// Perpendicular distance from the road's centreline, in metres.
        public let offsetMeters: Double

        public init(road: RoadLimit, limitKph: Double, offsetMeters: Double) {
            self.road = road
            self.limitKph = limitKph
            self.offsetMeters = offsetMeters
        }
    }

    public let thresholds: Thresholds

    /// The road the driver is currently held to be on.
    public private(set) var current: Match?

    private var challengerID: String?
    private var challengerCount = 0
    private var missCount = 0

    public init(thresholds: Thresholds = .standard) {
        self.thresholds = thresholds
    }

    /// - Parameter candidates: roads near the driver. Cheap to pass a few dozen;
    ///   every one is projected, so this should already be a local window rather
    ///   than a country.
    /// - Returns: the road the driver is on, or nil when there is no good answer.
    public mutating func update(fix: LocationFix, candidates: [RoadLimit]) -> Match? {
        guard let best = bestCandidate(fix: fix, candidates: candidates) else {
            missCount += 1
            if missCount >= thresholds.dropConfirmations {
                current = nil
                challengerID = nil
                challengerCount = 0
            }
            return current
        }

        missCount = 0

        // Still on the same road: refresh it, because the offset and - on a road
        // whose limit is directional - the limit itself both move as the driver
        // does.
        if best.road.id == current?.road.id {
            current = best
            challengerID = nil
            challengerCount = 0
            return current
        }

        // Nothing to flap away from, so take it. Waiting for confirmation here
        // would only delay the first limit of a journey, and a wrong answer is
        // no worse than the nothing it replaces.
        if current == nil {
            current = best
            challengerID = nil
            challengerCount = 0
            return current
        }

        if challengerID == best.road.id {
            challengerCount += 1
        } else {
            challengerID = best.road.id
            challengerCount = 1
        }

        if challengerCount >= thresholds.switchConfirmations {
            current = best
            challengerID = nil
            challengerCount = 0
        }

        return current
    }

    public mutating func reset() {
        current = nil
        challengerID = nil
        challengerCount = 0
        missCount = 0
    }

    /// The nearest road inside the corridor whose heading agrees with the
    /// driver's course.
    private func bestCandidate(fix: LocationFix, candidates: [RoadLimit]) -> Match? {
        var best: Match?
        var bestOffset = Double.infinity

        for road in candidates {
            let projection = road.path.project(fix.coordinate)
            guard projection.crossTrackDistance <= thresholds.corridorMeters else { continue }
            guard projection.crossTrackDistance < bestOffset else { continue }
            guard headingAgrees(fix: fix, road: road, projection: projection) else { continue }

            bestOffset = projection.crossTrackDistance
            best = Match(
                road: road,
                limitKph: road.limit(travellingOn: fix.courseDegrees, at: projection),
                offsetMeters: projection.crossTrackDistance
            )
        }

        return best
    }

    /// Whether the driver's course runs along this road, in either direction.
    ///
    /// Either direction, because a two-way road is the same road whichever way
    /// you drive it - the direction question is about which *limit* applies, not
    /// about which road it is, and `RoadLimit.limit(travellingOn:at:)` answers
    /// that separately.
    ///
    /// A fix with no course - stationary, or a receiver that could not work one
    /// out - agrees with everything. There is no information to filter on, and
    /// discarding every candidate would blank the limit every time the driver
    /// stopped at a light.
    private func headingAgrees(
        fix: LocationFix,
        road: RoadLimit,
        projection: RoadPath.Projection
    ) -> Bool {
        guard let course = fix.courseDegrees else { return true }
        guard let bearing = road.path.bearing(atSegment: projection.segmentIndex) else { return true }

        var delta = abs(bearing - course).truncatingRemainder(dividingBy: 360)
        if delta > 180 { delta = 360 - delta }
        // Fold onto 0...90, so a road driven the "wrong" way along its geometry
        // still counts as aligned.
        if delta > 90 { delta = 180 - delta }

        return delta <= thresholds.bearingToleranceDegrees
    }
}
