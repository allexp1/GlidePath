import Foundation

/// A camera the driver is closing on, and how urgent it has become.
public struct CameraApproach: Sendable, Equatable {
    public enum Urgency: String, Sendable, Equatable {
        /// First mention, far enough out to lift off gently.
        case advance
        /// Close enough that it is now or never.
        case imminent
    }

    public let camera: Camera
    public let distanceMeters: Double
    public let urgency: Urgency

    /// Set when the camera enforces a speed and the driver is over it.
    public let overLimitByKph: Double?
}

/// Decides when to speak about ordinary point cameras.
///
/// Distance alone is a poor trigger: 300 metres is ten seconds at 110 km/h and
/// half a minute at 40. So the thresholds are times, converted to distances at
/// the driver's current speed, with a floor so a crawling driver still gets some
/// warning and a ceiling so a fast one is not told about something a kilometre
/// away.
///
/// Each camera is announced at most once per urgency level per pass, and the
/// whole thing resets once the driver is clearly past it - otherwise sitting in
/// traffic beside a camera would produce an alert every second.
public struct CameraApproachMonitor: Sendable {
    public struct Thresholds: Sendable, Equatable {
        public var advanceLeadSeconds: TimeInterval
        public var imminentLeadSeconds: TimeInterval
        public var minimumDistanceMeters: Double
        public var maximumDistanceMeters: Double

        /// Mobile hotspots are a guess about where a van sometimes parks, so
        /// they get a longer run-up and softer wording.
        public var advisoryLeadMultiplier: Double

        /// How far past a camera counts as "passed", which re-arms it.
        public var rearmDistanceMeters: Double

        public init(
            advanceLeadSeconds: TimeInterval = 24,
            imminentLeadSeconds: TimeInterval = 9,
            minimumDistanceMeters: Double = 120,
            maximumDistanceMeters: Double = 900,
            advisoryLeadMultiplier: Double = 1.5,
            rearmDistanceMeters: Double = 250
        ) {
            self.advanceLeadSeconds = advanceLeadSeconds
            self.imminentLeadSeconds = imminentLeadSeconds
            self.minimumDistanceMeters = minimumDistanceMeters
            self.maximumDistanceMeters = maximumDistanceMeters
            self.advisoryLeadMultiplier = advisoryLeadMultiplier
            self.rearmDistanceMeters = rearmDistanceMeters
        }

        public static let standard = Thresholds()
    }

    public let thresholds: Thresholds

    /// Highest urgency already announced per camera id.
    private var announced: [String: CameraApproach.Urgency] = [:]

    public init(thresholds: Thresholds = .standard) {
        self.thresholds = thresholds
    }

    /// - Parameters:
    ///   - cameras: candidates near the driver. Zone entry and exit markers are
    ///     ignored here - the zone session owns those.
    /// - Returns: approaches worth speaking about on this fix, nearest first.
    public mutating func update(fix: LocationFix, cameras: [Camera]) -> [CameraApproach] {
        let speedMps = max(fix.speedMps ?? 0, 0)
        var results: [CameraApproach] = []

        for camera in cameras where !camera.type.isZoneMarker {
            let distance = fix.coordinate.distance(to: camera.coordinate)

            if distance > thresholds.rearmDistanceMeters,
               let previous = announced[camera.id],
               previous == .imminent,
               isMovingAway(fix: fix, camera: camera) {
                announced[camera.id] = nil
                continue
            }

            guard camera.facesTraffic(travellingOn: fix.courseDegrees) else { continue }

            let multiplier = camera.type.isAdvisory ? thresholds.advisoryLeadMultiplier : 1
            let advanceDistance = clampLead(speedMps * thresholds.advanceLeadSeconds * multiplier)
            let imminentDistance = clampLead(speedMps * thresholds.imminentLeadSeconds * multiplier)

            let urgency: CameraApproach.Urgency
            if distance <= imminentDistance {
                urgency = .imminent
            } else if distance <= advanceDistance {
                urgency = .advance
            } else {
                continue
            }

            // Never repeat, and never step back down from imminent to advance.
            if let previous = announced[camera.id] {
                if previous == .imminent || previous == urgency { continue }
            }
            announced[camera.id] = urgency

            results.append(
                CameraApproach(
                    camera: camera,
                    distanceMeters: distance,
                    urgency: urgency,
                    overLimitByKph: overLimit(camera: camera, fix: fix)
                )
            )
        }

        return results.sorted { $0.distanceMeters < $1.distanceMeters }
    }

    /// Announces a camera because the driver has crossed its geofence, rather
    /// than because a fix landed inside the computed window.
    ///
    /// The two paths have to share `announced` or the driver hears the same
    /// camera twice, which is why this lives here rather than in the app layer
    /// alongside the region callback. Returns nil when the camera has already
    /// been spoken about on this pass, which is the common case: at a decent
    /// fix rate the ordinary window almost always opens first, and this is the
    /// backstop for when it did not.
    ///
    /// Reported as `.advance`, never `.imminent`. A geofence radius is fixed
    /// while the window is a function of speed, so the crossing carries no
    /// information about how much time is left - and claiming urgency the data
    /// does not support is how an app teaches drivers to ignore it.
    public mutating func announceGeofenceCrossing(
        of camera: Camera,
        at fix: LocationFix
    ) -> CameraApproach? {
        guard !camera.type.isZoneMarker else { return nil }
        guard announced[camera.id] == nil else { return nil }
        guard camera.facesTraffic(travellingOn: fix.courseDegrees) else { return nil }

        announced[camera.id] = .advance

        return CameraApproach(
            camera: camera,
            distanceMeters: fix.coordinate.distance(to: camera.coordinate),
            urgency: .advance,
            overLimitByKph: overLimit(camera: camera, fix: fix)
        )
    }

    public mutating func reset() {
        announced.removeAll()
    }

    /// How far over this camera's limit the driver is, when the camera enforces
    /// one at the moment of passing. Nil for a camera that does not, and for a
    /// driver who is not over it.
    private func overLimit(camera: Camera, fix: LocationFix) -> Double? {
        guard let limit = camera.speedLimitKph,
              camera.type.enforcesInstantaneousSpeed,
              let speedKph = fix.speedKph,
              speedKph > limit else { return nil }
        return speedKph - limit
    }

    private func clampLead(_ distance: Double) -> Double {
        min(max(distance, thresholds.minimumDistanceMeters), thresholds.maximumDistanceMeters)
    }

    /// True when the driver's heading points away from the camera, which is the
    /// signal that they have passed it rather than stopped short of it.
    private func isMovingAway(fix: LocationFix, camera: Camera) -> Bool {
        guard let course = fix.courseDegrees else { return true }
        let bearingToCamera = fix.coordinate.bearing(to: camera.coordinate)
        var delta = abs(bearingToCamera - course).truncatingRemainder(dividingBy: 360)
        if delta > 180 { delta = 360 - delta }
        return delta > 90
    }
}
