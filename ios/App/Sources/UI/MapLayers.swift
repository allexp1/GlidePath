import CoreLocation
import MapKit
import SwiftUI
import ZonexploCore

extension ZonexploCore.Coordinate {
    var clCoordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

/// Where the map is looking, and whether it is still following the driver.
///
/// Its own type because "following" is state with rules rather than a boolean:
/// a pan suspends it, time restores it, and the zoom the driver chose has to
/// survive both. Left inline it pushed HomeView past the size the linter allows,
/// which was a fair complaint about a view that had quietly become two things.
@MainActor
@Observable
final class MapFollowController {
    var camera: MapCameraPosition = .userLocation(fallback: .automatic)

    /// Which way the map faces, so a puck can point at the road rather than at
    /// the top of the screen.
    var mapHeading: Double = 0

    /// The zoom the driver last chose, so following does not keep yanking it
    /// back to a default they have just rejected.
    var preferredDistance: Double = 1_400

    /// How long a deliberate pan buys before the map resumes following. Long
    /// enough to look at a camera up the road, short enough that nobody has to
    /// remember to press anything to get back to driving.
    static let freeLookSeconds: TimeInterval = 8

    private var pannedAt: Date?

    /// Free is a state you fall into, never one you have to climb out of. The
    /// old behaviour had no such notion: one stray pan switched the camera to
    /// manual and left it there for the rest of the drive, which is exactly
    /// what "the map is static" looks like from the driver's seat.
    var isFollowing: Bool {
        guard let pannedAt else { return true }
        return Date().timeIntervalSince(pannedAt) > Self.freeLookSeconds
    }

    func noteCameraChange(heading: Double, distance: Double, byUser: Bool) {
        mapHeading = heading
        guard byUser else { return }
        pannedAt = Date()
        preferredDistance = distance
    }

    func resume() { pannedAt = nil }

    func look(at coordinate: Coordinate, heading: Double) {
        camera = .camera(
            MapCamera(
                centerCoordinate: coordinate.clCoordinate,
                distance: preferredDistance,
                heading: heading,
                pitch: 0
            )
        )
    }
}

    /// The sections themselves, which are the only thing on this map that a
    /// camera-alert app does not already show.
    ///
    /// A pin says "there is a camera here". A section is a stretch of road with
    /// a start and an end, and the question a driver in one actually asks is
    /// "how much more of this is there" - which is spatial, and which the
    /// numbers on the card can only answer in the abstract. Drawing the road
    /// answers it in the shape the question was asked in.
    ///
    /// The active section is split at the driver: what is behind them is faded
    /// to the point of being scenery, what is ahead is the thing being driven.
    /// Its colour is the tier the engine decided, not a second opinion computed
    /// here, for the same reason the progress bar takes it rather than
    /// recomputing - a road that disagreed with the voice would be worse than
    /// no road at all.
/// The sections drawn on the map.
struct ZoneOverlays: MapContent {
    let activeZone: Zone?
    let advice: CoachingAdvice?
    let nearbyZones: [Zone]
    let here: Coordinate?

    @MapContentBuilder
    var body: some MapContent {
        ForEach(upcomingZones, id: \.id) { zone in
            if let path = zone.path {
                MapPolyline(coordinates: path.coordinates.map(\.clCoordinate))
                    .stroke(
                        .purple.opacity(0.45),
                        style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round)
                    )
            }
        }

        if let zone = activeZone, let path = zone.path {
            let split = path.split(atDistance: activeZoneProgressMeters(zone: zone, path: path))
            let tint = advice.map { TierPalette.tint(for: $0.tier) } ?? .green

            // A casing under the whole section, because a coloured line on a
            // pale map is exactly as legible as the map happens to be that day.
            MapPolyline(coordinates: path.coordinates.map(\.clCoordinate))
                .stroke(
                    .black.opacity(0.28),
                    style: StrokeStyle(lineWidth: 12, lineCap: .round, lineJoin: .round)
                )

            if split.covered.count >= 2 {
                MapPolyline(coordinates: split.covered.map(\.clCoordinate))
                    .stroke(
                        tint.opacity(0.3),
                        style: StrokeStyle(lineWidth: 7, lineCap: .round, lineJoin: .round)
                    )
            }

            if split.remaining.count >= 2 {
                MapPolyline(coordinates: split.remaining.map(\.clCoordinate))
                    .stroke(tint, style: StrokeStyle(lineWidth: 7, lineCap: .round, lineJoin: .round))
            }
        }
    }

    /// How far along its own polyline the driver is.
    ///
    /// Scaled, because `distanceMeters` is the authoritative road distance and
    /// the stored polyline is a simplification that rarely adds up to exactly
    /// the same number. Using the polyline's own length would drift the drawn
    /// position away from the distance the card is quoting.
    func activeZoneProgressMeters(zone: Zone, path: RoadPath) -> Double {
        guard zone.distanceMeters > 0, let advice = advice else { return 0 }
        let covered = zone.distanceMeters - advice.distanceRemainingMeters
        return path.totalDistance * min(1, max(0, covered / zone.distanceMeters))
    }

    /// Sections nearby but not yet entered, nearest first.
    ///
    /// Capped at a dozen: the monitor holds zones out to sixty kilometres so
    /// that geofences can be placed ahead of time, and drawing all of them
    /// would put roads on the map the driver will not reach for half an hour.
    /// This is a drawing limit, not a coverage limit - every one of them is
    /// still armed and will still be announced.
    var upcomingZones: [Zone] {
        let zones = (nearbyZones).filter { $0.id != activeZone?.id }
        guard let here else { return Array(zones.prefix(12)) }
        let byDistance = zones.sorted { here.distance(to: $0.entry) < here.distance(to: $1.entry) }
        return Array(byDistance.prefix(12))
    }
}

/// A camera on the map. Shape carries the type, so the pins are still
/// distinguishable in greyscale and for a colour-blind driver.
struct CameraPin: View {
    let type: CameraType
    let verified: Bool

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 26, height: 26)
            .background(background, in: Circle())
            .overlay(
                Circle().strokeBorder(.white.opacity(0.7), lineWidth: 1.5)
            )
            // An unverified camera is one that vanished from the map data. It
            // is still shown, because it may well still be there, but it is
            // shown as the guess it is.
            .opacity(verified ? 1 : 0.45)
            .shadow(radius: 2, y: 1)
    }

    private var symbol: String {
        switch type {
        case .fixed: return "camera.fill"
        case .redLight: return "light.beacon.max.fill"
        case .combined: return "camera.badge.ellipsis"
        case .seatbeltPhone: return "iphone.gen3.slash"
        case .busLane: return "bus.fill"
        case .mobileHotspot: return "questionmark"
        case .zoneEntry: return "arrow.right.to.line"
        case .zoneExit: return "arrow.left.to.line"
        }
    }

    private var background: Color {
        switch type {
        case .zoneEntry, .zoneExit: return .purple
        case .mobileHotspot: return .gray
        case .redLight: return .red
        case .seatbeltPhone, .busLane: return .blue
        case .fixed, .combined: return .orange
        }
    }
}
