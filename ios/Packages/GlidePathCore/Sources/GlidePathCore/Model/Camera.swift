import Foundation

/// What a camera actually enforces. Mirrors the `camera_type` enum in the
/// Supabase schema one-for-one - if you add a case here, add it there too.
public enum CameraType: String, Sendable, Codable, CaseIterable {
    /// A conventional fixed speed camera.
    case fixed

    /// Red light camera at a junction.
    case redLight = "red_light"

    /// Enforces both speed and red light from one housing.
    case combined

    /// AI enforcement camera for seat belt and handheld phone use. No speed
    /// component, so it never affects the allowance math - it is a "tidy up"
    /// prompt, not a speed alert.
    case seatbeltPhone = "seatbelt_phone"

    /// Bus lane / restricted lane enforcement.
    case busLane = "bus_lane"

    /// A location police repeatedly park a mobile unit at. Not a fixed
    /// installation, so it is advisory: warn earlier, promise less.
    case mobileHotspot = "mobile_hotspot"

    /// The camera that opens an average-speed section.
    case zoneEntry = "zone_entry"

    /// The camera that closes an average-speed section. This is the one the
    /// whole allowance calculation is aiming at.
    case zoneExit = "zone_exit"

    /// True when passing this camera at an illegal speed is what gets you
    /// fined, so an instantaneous speed alert is warranted.
    public var enforcesInstantaneousSpeed: Bool {
        switch self {
        case .fixed, .combined, .mobileHotspot, .zoneEntry, .zoneExit:
            return true
        case .redLight, .seatbeltPhone, .busLane:
            return false
        }
    }

    /// True when this camera belongs to an average-speed section rather than
    /// standing on its own.
    public var isZoneMarker: Bool {
        self == .zoneEntry || self == .zoneExit
    }

    /// Mobile hotspots are guesses about where a van might be, so they earn a
    /// longer warning and softer language.
    public var isAdvisory: Bool {
        self == .mobileHotspot
    }
}

/// A single point camera. Zone entry and exit cameras are also rows here, tied
/// back to their zone by `zoneID`.
public struct Camera: Sendable, Equatable, Identifiable, Codable {
    public let id: String
    public let countryCode: String
    public let coordinate: Coordinate
    public let type: CameraType

    /// The direction of travel this camera catches, in degrees clockwise from
    /// true north - not the direction the housing points. A camera on an
    /// eastbound carriageway is 90, whichever way the lens faces. `nil` means it
    /// catches both directions, which is how unknown data is treated too:
    /// warning about a camera that turns out to be irrelevant is a far smaller
    /// failure than staying silent about a real one.
    public let directionDegrees: Double?

    /// The limit this camera enforces, when it enforces one.
    public let speedLimitKph: Double?

    /// Set when this camera is the entry or exit marker of an average-speed
    /// section.
    public let zoneID: String?

    /// True once a human has confirmed the camera exists. Rows that vanish from
    /// OpenStreetMap are flipped to false rather than deleted, so a mapping
    /// mistake upstream cannot silently blind the app.
    public let verified: Bool

    public let osmID: String?
    public let updatedAt: Date

    public init(
        id: String,
        countryCode: String,
        coordinate: Coordinate,
        type: CameraType,
        directionDegrees: Double? = nil,
        speedLimitKph: Double? = nil,
        zoneID: String? = nil,
        verified: Bool = true,
        osmID: String? = nil,
        updatedAt: Date = Date(timeIntervalSince1970: 0)
    ) {
        self.id = id
        self.countryCode = countryCode
        self.coordinate = coordinate
        self.type = type
        self.directionDegrees = directionDegrees
        self.speedLimitKph = speedLimitKph
        self.zoneID = zoneID
        self.verified = verified
        self.osmID = osmID
        self.updatedAt = updatedAt
    }

    /// Whether a driver travelling on `courseDegrees` is approaching the face of
    /// this camera. Bidirectional cameras always return true.
    ///
    /// `tolerance` is generous because a road bends, and because a course
    /// reading from a phone is noisy at low speed.
    public func facesTraffic(travellingOn courseDegrees: Double?, tolerance: Double = 60) -> Bool {
        guard let cameraDirection = directionDegrees else { return true }
        guard let course = courseDegrees else { return true }

        var delta = abs(cameraDirection - course).truncatingRemainder(dividingBy: 360)
        if delta > 180 { delta = 360 - delta }
        return delta <= tolerance
    }
}
