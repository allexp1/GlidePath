import Foundation

/// A WGS84 position. Deliberately not CLLocationCoordinate2D so the engine
/// stays free of CoreLocation and testable on any platform.
public struct Coordinate: Sendable, Equatable, Hashable, Codable {
    public let latitude: Double
    public let longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }

    public static let earthRadiusMeters = 6_371_008.8

    /// Great-circle distance in metres.
    public func distance(to other: Coordinate) -> Double {
        let lat1 = latitude * .pi / 180
        let lat2 = other.latitude * .pi / 180
        let dLat = (other.latitude - latitude) * .pi / 180
        let dLon = (other.longitude - longitude) * .pi / 180

        let a = sin(dLat / 2) * sin(dLat / 2)
            + cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2)
        let c = 2 * atan2(sqrt(a), sqrt(max(0, 1 - a)))
        return Coordinate.earthRadiusMeters * c
    }

    /// Initial bearing to `other`, in degrees clockwise from true north.
    public func bearing(to other: Coordinate) -> Double {
        let lat1 = latitude * .pi / 180
        let lat2 = other.latitude * .pi / 180
        let dLon = (other.longitude - longitude) * .pi / 180

        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        let degrees = atan2(y, x) * 180 / .pi
        return degrees < 0 ? degrees + 360 : degrees
    }

    /// A new coordinate `meters` away along `bearingDegrees`.
    /// Used by the test fixtures to lay out synthetic roads.
    public func offset(meters: Double, bearingDegrees: Double) -> Coordinate {
        let angular = meters / Coordinate.earthRadiusMeters
        let bearing = bearingDegrees * .pi / 180
        let lat1 = latitude * .pi / 180
        let lon1 = longitude * .pi / 180

        let lat2 = asin(sin(lat1) * cos(angular) + cos(lat1) * sin(angular) * cos(bearing))
        let lon2 = lon1 + atan2(
            sin(bearing) * sin(angular) * cos(lat1),
            cos(angular) - sin(lat1) * sin(lat2)
        )
        return Coordinate(latitude: lat2 * 180 / .pi, longitude: lon2 * 180 / .pi)
    }

    /// Local east/north offset in metres from `origin`, using an equirectangular
    /// approximation. Accurate to well under a metre over the few-kilometre
    /// spans a single road segment covers, and far cheaper than a full geodesic.
    func localOffset(from origin: Coordinate) -> (east: Double, north: Double) {
        let latRad = origin.latitude * .pi / 180
        let east = (longitude - origin.longitude) * .pi / 180 * cos(latRad) * Coordinate.earthRadiusMeters
        let north = (latitude - origin.latitude) * .pi / 180 * Coordinate.earthRadiusMeters
        return (east, north)
    }
}
