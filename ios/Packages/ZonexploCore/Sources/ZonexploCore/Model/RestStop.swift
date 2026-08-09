import Foundation

public enum RestStopKind: String, Sendable, Codable, CaseIterable {
    case restArea = "rest_area"
    case fuelStation = "fuel_station"
    case services
    case parking
    case viewpoint

    /// Somewhere you can plausibly stop for several minutes without it being
    /// strange. A layby is fine for 30 seconds; a services is fine for ten
    /// minutes.
    public var suitsLongPause: Bool {
        switch self {
        case .services, .fuelStation, .restArea:
            return true
        case .parking, .viewpoint:
            return false
        }
    }
}

/// A place inside a zone where a driver who has already overspent their time
/// budget can legally stop and let the clock catch up.
public struct RestStop: Sendable, Equatable, Identifiable, Codable {
    public let id: String
    public let name: String?
    public let coordinate: Coordinate
    public let kind: RestStopKind
    public let zoneID: String?

    /// Distance from the zone entry along the road, in metres. Precomputed when
    /// the zone is built so the engine never has to project on the hot path.
    public let distanceAlongMeters: Double?

    public init(
        id: String,
        name: String? = nil,
        coordinate: Coordinate,
        kind: RestStopKind,
        zoneID: String? = nil,
        distanceAlongMeters: Double? = nil
    ) {
        self.id = id
        self.name = name
        self.coordinate = coordinate
        self.kind = kind
        self.zoneID = zoneID
        self.distanceAlongMeters = distanceAlongMeters
    }
}
