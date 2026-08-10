import Foundation

/// The posted limit at a fixed point, for looking up one camera rather than
/// following a moving car.
///
/// Most cameras carry no limit of their own. Only about half of them do in the
/// best-mapped countries and under five per cent in California, because
/// `maxspeed` on the camera node is a thing a mapper may add and usually does
/// not. The road it stands on is very often tagged even when the camera is not,
/// so the answer the driver wants is usually sitting right there in data the
/// phone already holds.
///
/// This is not `RoadLimitMatcher`. That one is built for a car with a heading
/// and a history, and it deliberately hesitates before switching roads because
/// flapping between two limits at speed is worse than being briefly wrong. Here
/// there is one point, no history, and all the time in the world - so the rule
/// can be much stricter instead.
///
/// **The rule is: agree or refuse.** Every road passing within the corridor is
/// consulted, and if they do not all say the same number, nothing is returned.
/// That is what stops a camera on a 110 motorway reporting the 60 of the slip
/// road beside it, which is the exact shape of wrong answer this codebase
/// treats as worse than silence: a limit the driver may act on without seeing
/// the sign.
public enum RoadLimitLookup {
    public struct Result: Sendable, Equatable {
        public let limitKph: Double
        public let roadName: String?
        public let roadRef: String?

        /// How far the point sits from the road it was matched to.
        public let offsetMeters: Double

        public init(limitKph: Double, roadName: String?, roadRef: String?, offsetMeters: Double) {
            self.limitKph = limitKph
            self.roadName = roadName
            self.roadRef = roadRef
            self.offsetMeters = offsetMeters
        }
    }

    /// How far off a road a camera may stand and still be held to be on it.
    ///
    /// Generous enough for a gantry over a wide carriageway and for the 8 m
    /// simplification the geometry has already been through; tight enough that
    /// a parallel service road is not swept in silently. When one is swept in
    /// anyway, the agreement rule catches it.
    public static let corridorMeters: Double = 25

    public static func limit(
        at point: Coordinate,
        facing bearingDegrees: Double? = nil,
        candidates: [RoadLimit],
        corridorMeters: Double = Self.corridorMeters
    ) -> Result? {
        var hits: [Hit] = []

        for road in candidates {
            let projection = road.path.project(point)
            guard projection.crossTrackDistance <= corridorMeters else { continue }
            hits.append(
                Hit(
                    road: road,
                    offsetMeters: projection.crossTrackDistance,
                    limitKph: road.limit(travellingOn: bearingDegrees, at: projection)
                )
            )
        }

        guard let nearest = hits.min(by: { $0.offsetMeters < $1.offsetMeters }) else { return nil }

        // Rounded to whole units before comparing, because two ways digitised
        // separately can carry the same sign as 49.999 and 50 once converted
        // from mph, and disagreeing about that is not a real disagreement.
        guard Set(hits.map { Int($0.limitKph.rounded()) }).count == 1 else { return nil }

        return Result(
            limitKph: nearest.limitKph,
            roadName: nearest.road.name,
            roadRef: nearest.road.roadRef,
            offsetMeters: nearest.offsetMeters
        )
    }

    private struct Hit {
        let road: RoadLimit
        let offsetMeters: Double
        let limitKph: Double
    }
}
