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

            var over: Double?
            if let limit = camera.speedLimitKph,
               camera.type.enforcesInstantaneousSpeed,
               let speedKph = fix.speedKph,
               speedKph > limit {
                over = speedKph - limit
            }

            results.append(
                CameraApproach(
                    camera: camera,
                    distanceMeters: distance,
                    urgency: urgency,
                    overLimitByKph: over
                )
            )
        }

        return results.sorted { $0.distanceMeters < $1.distanceMeters }
    }

    public mutating func reset() {
        announced.removeAll()
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
