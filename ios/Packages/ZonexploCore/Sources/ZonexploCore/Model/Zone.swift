import Foundation

/// An average-speed enforcement section: two cameras and the road between them.
///
/// The driver's average speed over `distanceMeters` is what gets measured, so
/// the only number that matters at the exit is total distance over total time.
public struct Zone: Sendable, Equatable, Identifiable, Codable {
    public let id: String
    public let countryCode: String
    public let name: String?

    /// Road reference as signposted, e.g. "Route 6" or "M2".
    public let roadRef: String?

    public let entry: Coordinate
    public let exit: Coordinate

    /// Distance along the road between the entry and exit cameras, in metres.
    ///
    /// This is the authoritative figure - it comes from road geometry, not from
    /// the straight line between the two cameras, and not from whatever length
    /// the stored polyline happens to add up to. When a `path` is present the
    /// engine scales progress along it to this number.
    public let distanceMeters: Double

    public let speedLimitKph: Double

    /// A posted legal minimum speed, where one exists. The engine will never
    /// coach below this - see `SafetyPolicy.coachingFloorKph(for:)`.
    public let minimumSpeedKph: Double?

    /// Direction of travel this zone applies to, in degrees. A dual
    /// carriageway is two zones, one per direction.
    public let directionDegrees: Double?

    public let path: RoadPath?
    public let restStops: [RestStop]
    public let updatedAt: Date

    public init(
        id: String,
        countryCode: String,
        name: String? = nil,
        roadRef: String? = nil,
        entry: Coordinate,
        exit: Coordinate,
        distanceMeters: Double,
        speedLimitKph: Double,
        minimumSpeedKph: Double? = nil,
        directionDegrees: Double? = nil,
        path: RoadPath? = nil,
        restStops: [RestStop] = [],
        updatedAt: Date = Date(timeIntervalSince1970: 0)
    ) {
        self.id = id
        self.countryCode = countryCode
        self.name = name
        self.roadRef = roadRef
        self.entry = entry
        self.exit = exit
        self.distanceMeters = distanceMeters
        self.speedLimitKph = speedLimitKph
        self.minimumSpeedKph = minimumSpeedKph
        self.directionDegrees = directionDegrees
        self.path = path
        self.restStops = restStops
        self.updatedAt = updatedAt
    }

    /// The fastest you may legally cover this zone, in seconds. Drive it in
    /// less and the exit camera has you.
    public var minimumLegalSeconds: TimeInterval {
        distanceMeters / Units.mps(fromKph: speedLimitKph)
    }

    /// Rest stops known to sit inside the zone, ordered by how far along they
    /// are. Stops with no recorded position are dropped - the engine cannot
    /// route a driver to something it cannot place.
    public var orderedRestStops: [RestStop] {
        restStops
            .filter { $0.distanceAlongMeters != nil }
            .sorted { ($0.distanceAlongMeters ?? 0) < ($1.distanceAlongMeters ?? 0) }
    }
}
