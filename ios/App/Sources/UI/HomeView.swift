import ZonexploCore
import CoreLocation
import MapKit
import SwiftUI
import UIKit

/// The home screen: a map you are not meant to look at.
///
/// Zonexplo is not a navigator and must not compete with one. The map exists
/// to answer one question, "is it actually watching?", and to make the camera
/// data tangible enough to trust. The moment a zone starts, the live card takes
/// over the screen and the map becomes background texture.
struct HomeView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL

    @State private var camera: MapCameraPosition = .userLocation(fallback: .automatic)
    @State private var selectedCamera: ZonexploCore.Camera?

    private var monitor: DriveMonitor? { model.monitor }

    var body: some View {
        ZStack(alignment: .bottom) {
            map
                .ignoresSafeArea()

            // The map deliberately runs under the status bar, which is why its
            // own controls end up there too. These live outside the map, so they
            // inset properly, and they match the app's glass styling instead of
            // MapKit's stock chrome.
            VStack(spacing: 8) {
                topControls
                permissionBanner
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 6)

            // Opposite corner from the controls, so a thumb reaching for
            // settings never covers the number.
            VStack(spacing: 0) {
                HStack {
                    if model.settings.showSpeedLimit, let match = monitor?.currentRoadLimit {
                        SpeedSign(
                            limitKph: match.limitKph,
                            speedKph: monitor?.currentSpeedKph,
                            units: model.settings.units
                        )
                        .transition(.scale.combined(with: .opacity))
                    }
                    Spacer()
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 6)
            .animation(.smooth(duration: 0.3), value: monitor?.currentRoadLimit?.limitKph)

            VStack(spacing: 14) {
                Spacer()

                // Above the card, because a camera warning is about the road
                // ahead and the card is about the section you are inside.
                if let approach = monitor?.currentApproach, monitor?.activeZone == nil {
                    CameraApproachBanner(approach: approach, units: model.settings.units)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                if let zone = monitor?.activeZone, let advice = monitor?.currentAdvice {
                    ZoneLiveCard(
                        zone: zone,
                        advice: advice,
                        units: model.settings.units,
                        isMuted: model.isMutedForSession
                    )
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                } else {
                    standbyCard
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
        .animation(.smooth(duration: 0.4), value: monitor?.activeZone?.id)
        .animation(.snappy(duration: 0.3), value: monitor?.currentApproach?.camera.id)
        .sheet(item: $selectedCamera) { tapped in
            CameraDetailSheet(
                camera: tapped,
                units: model.settings.units,
                from: model.location.latestFix?.coordinate,
                report: { kind in await model.reportCamera(tapped, kind: kind) }
            )
        }
    }

    // MARK: - Controls

    /// The one failure the driver cannot see for themselves.
    ///
    /// Without Always, iOS will not wake the app for a geofence, so no warning
    /// can be spoken with the phone locked - which is every warning that
    /// matters, because the phone is in a cradle showing a navigator or in a
    /// pocket. The app looks like it is working: the map moves, the card says
    /// "watching the road", and nothing is ever announced.
    ///
    /// It lives on the home screen rather than in Settings because nobody
    /// visits Settings to discover a problem they do not know they have.
    @ViewBuilder
    private var permissionBanner: some View {
        if let message = permissionProblem {
            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(message.title).font(.subheadline.weight(.semibold))
                        Text(message.detail).font(.caption)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)
            .zonexploGlass(cornerRadius: 18)
            .accessibilityHint("Opens iOS Settings")
        }
    }

    private var permissionProblem: (title: String, detail: String)? {
        switch model.location.authorizationStatus {
        case .authorizedAlways:
            return nil
        case .authorizedWhenInUse:
            return (
                "Warnings are off when the screen is locked",
                "Zonexplo needs Always to warn you with another app on screen. Tap to fix."
            )
        case .denied, .restricted:
            return (
                "Zonexplo cannot see where you are",
                "Location is turned off, so nothing can be announced. Tap to fix."
            )
        case .notDetermined:
            return (
                "Location access not granted yet",
                "Nothing can be announced until it is. Tap to fix."
            )
        @unknown default:
            return nil
        }
    }

    private var topControls: some View {
        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 10) {
                Spacer()

                Button {
                    withAnimation(.snappy) { model.isMutedForSession.toggle() }
                } label: {
                    controlIcon(model.isMutedForSession ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .foregroundStyle(model.isMutedForSession ? .orange : .primary)
                }
                .zonexploGlassCapsule()
                .accessibilityLabel(model.isMutedForSession ? "Unmute Zonexplo" : "Mute until I reopen the app")

                Button {
                    withAnimation(.smooth) {
                        camera = .userLocation(fallback: .automatic)
                    }
                } label: {
                    controlIcon("location.fill")
                }
                .zonexploGlassCapsule()
                .accessibilityLabel("Centre the map on my location")

                NavigationLink {
                    SettingsView()
                } label: {
                    controlIcon("gearshape.fill")
                }
                .zonexploGlassCapsule()
                .accessibilityLabel("Settings")
            }
        }
    }

    /// 44 points square, which is the smallest thing anyone should have to hit
    /// while holding a phone in a moving car.
    private func controlIcon(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(.primary)
            .frame(width: 44, height: 44)
    }

    // MARK: - Map

    private var map: some View {
        Map(position: $camera) {
            UserAnnotation()

            zoneOverlays

            ForEach(monitor?.nearbyCameras.prefix(120) ?? [], id: \.id) { pin in
                Annotation(
                    "",
                    coordinate: CLLocationCoordinate2D(
                        latitude: pin.coordinate.latitude,
                        longitude: pin.coordinate.longitude
                    )
                ) {
                    // A Button rather than the map's selection binding: taps on
                    // a custom annotation view are far more predictable this
                    // way, and the hit area can be made bigger than the pin.
                    Button {
                        selectedCamera = pin
                    } label: {
                        CameraPin(type: pin.type, verified: pin.verified)
                            .contentShape(Circle().inset(by: -8))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Camera details")
                }
            }
        }
        .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
        // Stock controls are positioned inside the map's bounds, which ignore
        // the safe area here, so they collide with the status bar. Replaced by
        // topControls above.
        .mapControlVisibility(.hidden)
    }

    // MARK: - Zones on the map

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
    @MapContentBuilder
    private var zoneOverlays: some MapContent {
        ForEach(upcomingZones, id: \.id) { zone in
            if let path = zone.path {
                MapPolyline(coordinates: path.coordinates.map(\.clCoordinate))
                    .stroke(
                        .purple.opacity(0.45),
                        style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round)
                    )
            }
        }

        if let zone = monitor?.activeZone, let path = zone.path {
            let split = path.split(atDistance: activeZoneProgressMeters(zone: zone, path: path))
            let tint = monitor?.currentAdvice.map { TierPalette.tint(for: $0.tier) } ?? .green

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
    private func activeZoneProgressMeters(zone: Zone, path: RoadPath) -> Double {
        guard zone.distanceMeters > 0, let advice = monitor?.currentAdvice else { return 0 }
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
    private var upcomingZones: [Zone] {
        let zones = (monitor?.nearbyZones ?? []).filter { $0.id != monitor?.activeZone?.id }
        guard let here = model.location.latestFix?.coordinate else { return Array(zones.prefix(12)) }
        let byDistance = zones.sorted { here.distance(to: $0.entry) < here.distance(to: $1.entry) }
        return Array(byDistance.prefix(12))
    }

    // MARK: - Standby

    private var standbyCard: some View {
        GlassEffectContainer(spacing: 14) {
            VStack(spacing: 14) {
                HStack(spacing: 12) {
                    Image(systemName: monitor?.isMonitoring == true ? "dot.radiowaves.left.and.right" : "pause.circle")
                        .font(.title2)
                        .foregroundStyle(monitor?.isMonitoring == true ? .green : .secondary)
                        .symbolEffect(.pulse, isActive: monitor?.isMonitoring == true)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(monitor?.isMonitoring == true ? "Watching the road" : "Not watching")
                            .font(.headline)
                        Text(subtitle)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()
                }

                // A mute the driver set twenty minutes ago and a broken app are
                // the same experience. The speaker icon turns orange, but a
                // 44pt glyph is not what anyone reads at speed - the card is.
                if model.isMutedForSession {
                    DriveNotice(
                        symbol: "speaker.slash.fill",
                        tint: .orange,
                        title: "Muted for this drive",
                        detail: "Tap the speaker to bring the voice back. It returns by itself "
                            + "next time you open Zonexplo."
                    )
                }

                if let (title, detail) = limitNotice {
                    DriveNotice(
                        symbol: "signpost.right.and.left",
                        tint: .gray,
                        title: title,
                        detail: detail
                    )
                }

                if let outcome = monitor?.lastOutcome {
                    lastRunSummary(outcome)
                }

                Button(monitor?.isMonitoring == true ? "Stop" : "Start watching") {
                    if monitor?.isMonitoring == true {
                        model.stopMonitoring()
                    } else {
                        model.startMonitoring()
                    }
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .frame(maxWidth: .infinity)
            }
            .padding(20)
            .zonexploGlass(cornerRadius: 30)
        }
    }

    /// Why the roundel is not on screen.
    ///
    /// The sign simply vanishing is the trap: it looks the same whether the
    /// road is untagged, the download is partial, or the matcher is broken. The
    /// first needs nothing, the second needs a tap in Settings, and the third
    /// needs a bug report - so the screen has to separate them.
    private var limitNotice: (title: String, detail: String)? {
        switch monitor?.limitStatus {
        case .notPosted:
            return (
                "No limit posted on this road",
                "Nobody has recorded one in OpenStreetMap. Zonexplo will not guess at a limit."
            )
        case .noneNearby:
            return (
                "No speed limits for this area",
                "Camera warnings still work. Settings > Road speed limit to download limits "
                    + "for the country you are in."
            )
        case .waiting, .notApplicable, .none:
            return nil
        }
    }

    private var subtitle: String {
        guard monitor?.isMonitoring == true else {
            return "Tap start before you set off"
        }
        let count = monitor?.nearbyCameras.count ?? 0
        let zones = monitor?.nearbyZones.count ?? 0

        if count == 0 && zones == 0 {
            return "No cameras nearby. Download a country in Settings if this looks wrong."
        }
        return "\(count) cameras and \(zones) zones loaded near you"
    }

    private func lastRunSummary(_ outcome: ZoneOutcome) -> some View {
        let phrasebook = Phrasebook(units: model.settings.units)

        return DriveNotice(
            symbol: outcome.passed ? "checkmark.seal.fill" : "exclamationmark.triangle.fill",
            tint: outcome.passed ? .green : .red,
            title: outcome.passed ? "Last zone: clear" : "Last zone: over the limit",
            detail: "Averaged \(phrasebook.speedPhrase(outcome.averageKph)) "
                + "against \(phrasebook.speedPhrase(outcome.limitKph))"
        )
    }
}

private extension ZonexploCore.Coordinate {
    var clCoordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
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
