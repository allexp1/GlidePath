import Foundation

/// A stretch of road with a posted speed limit on it.
///
/// One of these is one OpenStreetMap way, simplified to 8 m before it ever
/// reaches the phone. They are numerous in a way nothing else in this model is -
/// a country runs to hundreds of thousands of them against a few hundred cameras
/// - which is why the geometry is the only heavy thing they carry and why they
/// are downloaded separately from everything else.
///
/// **This is a different kind of claim from the rest of the app.** A camera
/// warning says "there is a thing here"; being wrong costs a moment of
/// irritation. A limit says "the sign says 90", which the driver may act on
/// without seeing the sign. So a limit is only ever stored when it was read off
/// an explicit `maxspeed` tag: nothing here is inferred from a national default,
/// and a road nobody has tagged simply has no limit and produces silence.
public struct RoadLimit: Sendable, Equatable, Identifiable, Codable {
    public let id: String
    public let countryCode: String

    public let name: String?
    public let roadRef: String?

    public let path: RoadPath

    /// The limit to use when the direction of travel cannot be established.
    public let limitKph: Double

    /// Set only where the two directions genuinely differ. Forward means along
    /// `path`, which is OpenStreetMap's digitisation order and carries no
    /// meaning beyond that.
    public let forwardLimitKph: Double?
    public let backwardLimitKph: Double?

    public let updatedAt: Date

    public init(
        id: String,
        countryCode: String,
        name: String? = nil,
        roadRef: String? = nil,
        path: RoadPath,
        limitKph: Double,
        forwardLimitKph: Double? = nil,
        backwardLimitKph: Double? = nil,
        updatedAt: Date = Date(timeIntervalSince1970: 0)
    ) {
        self.id = id
        self.countryCode = countryCode
        self.name = name
        self.roadRef = roadRef
        self.path = path
        self.limitKph = limitKph
        self.forwardLimitKph = forwardLimitKph
        self.backwardLimitKph = backwardLimitKph
        self.updatedAt = updatedAt
    }

    /// True when this road's two directions have different limits, so which way
    /// the driver is going changes the answer.
    public var isDirectional: Bool {
        forwardLimitKph != nil || backwardLimitKph != nil
    }

    /// The limit that applies to a driver travelling on `courseDegrees` at
    /// `projection`.
    ///
    /// Falls back to `limitKph` whenever the direction cannot be resolved, which
    /// the harvest deliberately set to the *higher* of the two. An unnecessary
    /// silence is a smaller failure than telling a driver they are over a limit
    /// that does not apply to their carriageway.
    public func limit(travellingOn courseDegrees: Double?, at projection: RoadPath.Projection) -> Double {
        guard isDirectional else { return limitKph }
        guard let course = courseDegrees,
              let bearing = path.bearing(atSegment: projection.segmentIndex) else {
            return limitKph
        }

        var delta = abs(bearing - course).truncatingRemainder(dividingBy: 360)
        if delta > 180 { delta = 360 - delta }

        return delta <= 90
            ? (forwardLimitKph ?? limitKph)
            : (backwardLimitKph ?? limitKph)
    }
}
