import Foundation

/// Why a session ended without reaching the exit camera.
public enum AbandonReason: String, Sendable, Equatable {
    /// Confirmed divergence from the zone's road.
    case leftTheRoad
    /// The user stopped the session, or location permission went away.
    case cancelled
    /// Too long without a usable fix to keep coaching honestly.
    case lostSignal
}

/// What happened at the exit camera.
public struct ZoneOutcome: Sendable, Equatable {
    public let zoneID: String
    public let zoneDistanceMeters: Double
    public let averageKph: Double
    public let limitKph: Double
    public let elapsedSeconds: TimeInterval
    public let enteredAt: Date
    public let exitedAt: Date

    public var passed: Bool { averageKph <= limitKph }

    /// Seconds of slack against the minimum legal traversal time. Positive is
    /// margin in hand; negative is how much too fast the section was driven.
    public var marginSeconds: TimeInterval {
        let minimumLegal = zoneDistanceMeters / Units.mps(fromKph: limitKph)
        return elapsedSeconds - minimumLegal
    }
}

public enum ZoneSessionState: Sendable, Equatable {
    /// Geofence fired, watching for the true entry crossing.
    case armed
    /// Inside the zone, coaching.
    case active
    case completed(ZoneOutcome)
    case abandoned(AbandonReason)

    public var isFinished: Bool {
        switch self {
        case .completed, .abandoned: return true
        case .armed, .active: return false
        }
    }
}

public enum ZoneSessionEvent: Sendable, Equatable {
    /// The driver crossed the entry line at this (interpolated) time.
    case entered(at: Date)
    /// Fresh coaching for this fix.
    case advice(CoachingAdvice)
    case completed(ZoneOutcome)
    case abandoned(AbandonReason)
}

/// The zone state machine: armed -> active -> completed / abandoned.
///
/// A value type on purpose. No shared mutable state, no actor hops, and a test
/// can replay an entire drive by folding fixes over it.
public struct ZoneSession: Sendable {
    public let zone: Zone
    public let policy: SafetyPolicy

    public private(set) var state: ZoneSessionState = .armed
    public private(set) var enteredAt: Date?
    public private(set) var distanceCoveredMeters: Double = 0
    public private(set) var lastAdvice: CoachingAdvice?

    private let engine: CoachingEngine

    /// The geometry progress is measured against.
    ///
    /// Prefers the zone's real polyline. Falls back to the straight line
    /// between the entry and exit cameras, scaled to the zone's road distance -
    /// approximate on a bendy road, but it keeps the state machine working on
    /// zones seeded by hand before anyone has traced the geometry. Deviation
    /// detection deliberately does *not* use the fallback, because every bend
    /// in the real road would read as leaving it.
    private let progressPath: RoadPath

    private var entryDetector = CrossingDetector()
    private var exitDetector = CrossingDetector()
    private var deviationDetector: DeviationDetector
    private var smoother: SpeedSmoother
    private var lastUsableFix: LocationFix?

    /// Fails for a zone with no usable geometry - zero length, or an entry and
    /// exit at the same point. Such a zone cannot be driven and the caller
    /// should skip it rather than arm a session that can never complete.
    public init?(zone: Zone, policy: SafetyPolicy = .standard) {
        guard zone.distanceMeters > 0, zone.speedLimitKph > 0 else { return nil }
        guard let path = zone.path ?? RoadPath(coordinates: [zone.entry, zone.exit]) else { return nil }

        self.zone = zone
        self.policy = policy
        self.progressPath = path
        self.engine = CoachingEngine(policy: policy)
        self.deviationDetector = DeviationDetector(
            thresholdMeters: policy.deviationDistanceMeters,
            confirmationSeconds: policy.deviationConfirmationSeconds
        )
        self.smoother = SpeedSmoother(window: policy.speedSmoothingWindow)
    }

    /// Feeds one GPS fix and returns whatever it caused.
    @discardableResult
    public mutating func ingest(_ fix: LocationFix) -> [ZoneSessionEvent] {
        guard !state.isFinished else { return [] }
        guard fix.isUsable(maximumAccuracyMeters: policy.maximumUsableAccuracyMeters) else { return [] }

        defer { lastUsableFix = fix }

        if let speedKph = fix.speedKph {
            smoother.add(speedKph: speedKph, at: fix.timestamp)
        }

        var events: [ZoneSessionEvent] = []
        let signedAlong = distanceAlongRoad(for: fix)

        if case .armed = state {
            guard let crossing = entryDetector.update(signedDistance: signedAlong, at: fix.timestamp) else {
                return events
            }
            enteredAt = crossing
            state = .active
            events.append(.entered(at: crossing))
        }

        guard case .active = state, let entryTime = enteredAt else {
            return events
        }

        // Confirmed divergence ends the session. Checked before coaching so we
        // never speak a target for a road the driver has already left. Only
        // real polylines are trusted here - see `progressPath`.
        if let realPath = zone.path {
            let crossTrack = realPath.project(fix.coordinate).crossTrackDistance
            if deviationDetector.update(crossTrackDistance: crossTrack, at: fix.timestamp) {
                state = .abandoned(.leftTheRoad)
                events.append(.abandoned(.leftTheRoad))
                return events
            }
        }

        distanceCoveredMeters = min(max(signedAlong, 0), zone.distanceMeters)

        // Exit crossing, interpolated the same careful way as the entry.
        let signedToExit = signedAlong - zone.distanceMeters
        if let exitTime = exitDetector.update(signedDistance: signedToExit, at: fix.timestamp) {
            let outcome = makeOutcome(entryTime: entryTime, exitTime: exitTime)
            state = .completed(outcome)
            events.append(.completed(outcome))
            return events
        }

        let allowance = AllowanceCalculator.compute(
            zone: zone,
            distanceCovered: distanceCoveredMeters,
            elapsed: fix.timestamp.timeIntervalSince(entryTime)
        )
        let advice = engine.advise(
            zone: zone,
            allowance: allowance,
            smoothedSpeedKph: smoother.hasSamples ? smoother.smoothedKph : nil
        )
        lastAdvice = advice
        events.append(.advice(advice))

        return events
    }

    /// Ends the session from the outside - user tapped stop, permission was
    /// revoked, or the fix stream dried up.
    @discardableResult
    public mutating func abandon(_ reason: AbandonReason) -> ZoneSessionEvent? {
        guard !state.isFinished else { return nil }
        state = .abandoned(reason)
        return .abandoned(reason)
    }

    // MARK: - Geometry

    /// Distance from the entry line along the road, in metres. Negative on the
    /// approach, greater than the zone distance once past the exit.
    ///
    /// Scaled to `zone.distanceMeters` so the polyline's own length - which may
    /// be a little short or long depending on how finely the road was traced -
    /// never contradicts the authoritative road-geometry distance.
    private func distanceAlongRoad(for fix: LocationFix) -> Double {
        let projection = progressPath.project(fix.coordinate)
        let scale = zone.distanceMeters / progressPath.totalDistance
        return projection.extendedDistanceAlong * scale
    }

    private func makeOutcome(entryTime: Date, exitTime: Date) -> ZoneOutcome {
        let elapsed = exitTime.timeIntervalSince(entryTime)
        let average = elapsed > 0 ? Units.kph(fromMps: zone.distanceMeters / elapsed) : 0
        return ZoneOutcome(
            zoneID: zone.id,
            zoneDistanceMeters: zone.distanceMeters,
            averageKph: average,
            limitKph: zone.speedLimitKph,
            elapsedSeconds: elapsed,
            enteredAt: entryTime,
            exitedAt: exitTime
        )
    }
}
