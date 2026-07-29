import Foundation
@testable import GlidePathCore

/// Synthetic geometry the tests share.
///
/// Every zone here is a straight line heading due east, which makes the
/// expected numbers computable by hand: a 10 km zone at 100 km/h has a minimum
/// legal time of exactly 360 seconds, and a leg driven at 150 km/h covers
/// exactly 41.666... metres per second.
enum TestFixtures {
    static let origin = Coordinate(latitude: 32.0, longitude: 34.8)
    static let referenceDate = Date(timeIntervalSince1970: 1_780_000_000)

    /// A straight eastbound path, sampled every `spacing` metres so projection
    /// stays accurate without the polyline itself becoming the thing under test.
    static func straightPath(
        lengthMeters: Double,
        spacing: Double = 250,
        from start: Coordinate = origin
    ) -> RoadPath {
        var coordinates: [Coordinate] = []
        var distance = 0.0
        while distance < lengthMeters {
            coordinates.append(start.offset(meters: distance, bearingDegrees: 90))
            distance += spacing
        }
        coordinates.append(start.offset(meters: lengthMeters, bearingDegrees: 90))

        guard let path = RoadPath(coordinates: coordinates) else {
            fatalError("straightPath fixture produced an unusable polyline")
        }
        return path
    }

    /// A zone whose `distanceMeters` matches its polyline exactly, so the
    /// scaling in `ZoneSession` is a no-op and expectations stay hand-checkable.
    static func zone(
        id: String = "zone-test",
        lengthMeters: Double = 10_000,
        limitKph: Double = 100,
        minimumSpeedKph: Double? = nil,
        restStops: [RestStop] = []
    ) -> Zone {
        let path = straightPath(lengthMeters: lengthMeters)
        return Zone(
            id: id,
            countryCode: "IL",
            name: "Test Section",
            roadRef: "Route 6",
            entry: path.start,
            exit: path.end,
            distanceMeters: path.totalDistance,
            speedLimitKph: limitKph,
            minimumSpeedKph: minimumSpeedKph,
            directionDegrees: 90,
            path: path,
            restStops: restStops
        )
    }

    static func restStop(
        id: String = "stop-1",
        at distanceAlong: Double,
        kind: RestStopKind = .services,
        in zone: Zone
    ) -> RestStop {
        let coordinate = zone.path?.coordinate(atDistance: distanceAlong) ?? zone.entry
        return RestStop(
            id: id,
            name: "Test Services",
            coordinate: coordinate,
            kind: kind,
            zoneID: zone.id,
            distanceAlongMeters: distanceAlong
        )
    }

    /// Runs a scripted drive through a session and collects everything it emitted.
    static func drive(
        _ zone: Zone,
        steps: [DriveSimulator.Step],
        policy: SafetyPolicy = .standard,
        options: DriveSimulator.Options = .standard
    ) -> DriveResult {
        guard let path = zone.path else {
            fatalError("drive() needs a zone with a polyline")
        }
        guard var session = ZoneSession(zone: zone, policy: policy) else {
            fatalError("drive() was given an undriveable zone")
        }

        let fixes = DriveSimulator.fixes(
            along: path,
            steps: steps,
            startingAt: referenceDate,
            options: options
        )

        var events: [ZoneSessionEvent] = []
        for fix in fixes {
            events.append(contentsOf: session.ingest(fix))
        }
        return DriveResult(events: events, finalState: session.state, fixCount: fixes.count)
    }

    /// Builds the fix stream for a scripted drive without running it, so a test
    /// can corrupt it first.
    static func fixes(
        for zone: Zone,
        steps: [DriveSimulator.Step],
        options: DriveSimulator.Options = .standard
    ) -> [LocationFix] {
        guard let path = zone.path else {
            fatalError("fixes(for:) needs a zone with a polyline")
        }
        return DriveSimulator.fixes(
            along: path,
            steps: steps,
            startingAt: referenceDate,
            options: options
        )
    }

    /// Replays an arbitrary fix stream through a session.
    static func run(
        _ zone: Zone,
        fixes: [LocationFix],
        policy: SafetyPolicy = .standard
    ) -> DriveResult {
        guard var session = ZoneSession(zone: zone, policy: policy) else {
            fatalError("run() was given an undriveable zone")
        }
        var events: [ZoneSessionEvent] = []
        for fix in fixes {
            events.append(contentsOf: session.ingest(fix))
        }
        return DriveResult(events: events, finalState: session.state, fixCount: fixes.count)
    }

    struct DriveResult {
        let events: [ZoneSessionEvent]
        let finalState: ZoneSessionState
        let fixCount: Int

        var advice: [CoachingAdvice] {
            events.compactMap {
                if case let .advice(advice) = $0 { return advice }
                return nil
            }
        }

        var outcome: ZoneOutcome? {
            events.compactMap {
                if case let .completed(outcome) = $0 { return outcome }
                return nil
            }.first
        }

        var enteredAt: Date? {
            events.compactMap {
                if case let .entered(at) = $0 { return at }
                return nil
            }.first
        }

        var abandonReason: AbandonReason? {
            events.compactMap {
                if case let .abandoned(reason) = $0 { return reason }
                return nil
            }.first
        }

        var tiers: [CoachingTier] { advice.map(\.tier) }
    }
}
