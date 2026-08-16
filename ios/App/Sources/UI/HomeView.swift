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

    @State private var selectedCamera: ZonexploCore.Camera?
    @State private var follow = MapFollowController()

    private var monitor: DriveMonitor? { model.monitor }

    var body: some View {
        ZStack(alignment: .bottom) {
            map
                .ignoresSafeArea()

            // Above the map rather than in it, and only when following - which
            // is when the driver is at the centre of the screen by definition,
            // so no coordinate conversion is needed and nothing MapKit draws
            // can ever cover it.
            if isFollowing {
                UserPuck(courseDegrees: steadyCourse, mapHeadingDegrees: follow.mapHeading)
                    .frame(maxHeight: .infinity)
            }

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
                report: { kind in await model.reportCamera(tapped, kind: kind) },
                postedLimit: { await model.postedLimit(at: tapped) }
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
                    withAnimation(.smooth) { cycleFollowMode() }
                } label: {
                    controlIcon(followSymbol)
                        .foregroundStyle(isFollowing ? Color.accentColor : .primary)
                }
                .zonexploGlassCapsule()
                .accessibilityLabel(followLabel)

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
        @Bindable var follow = follow

        return Map(position: $follow.camera) {
            ZoneOverlays(
                activeZone: monitor?.activeZone,
                advice: monitor?.currentAdvice,
                nearbyZones: monitor?.nearbyZones ?? [],
                here: model.location.latestFix?.coordinate
            )

            cameraPins

            // Only while the driver has panned away. Following puts them at
            // the centre of the screen by construction, and the puck is drawn
            // over the map there instead - see `body`.
            //
            // Declaration order does not settle this. MapKit z-orders
            // annotations by its own rules, and a camera pin at the same point
            // wins however late the puck is declared, which is the bug being
            // fixed: on a road with a camera at your position you vanished.
            if !isFollowing, let fix = model.location.latestFix {
                Annotation("", coordinate: fix.coordinate.clCoordinate) {
                    UserPuck(
                        courseDegrees: steadyCourse,
                        mapHeadingDegrees: follow.mapHeading
                    )
                }
            }
        }
        .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
        // Stock controls are positioned inside the map's bounds, which ignore
        // the safe area here, so they collide with the status bar. Replaced by
        // topControls above.
        .mapControlVisibility(.hidden)
        .onMapCameraChange(frequency: .continuous) { context in
            follow.noteCameraChange(
                heading: context.camera.heading,
                distance: context.camera.distance,
                byUser: follow.camera.positionedByUser
            )
        }
        // Driven by the fix stream rather than a timer: at 1 Hz the follow is
        // smooth enough, and the free-mode window expires on the next fix
        // without anything needing to wake up and check.
        .onChange(of: model.location.latestFix?.timestamp) { _, _ in
            followDriverIfDue()
        }
    }

    @MapContentBuilder
    private var cameraPins: some MapContent {
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

    // MARK: - Following

    private var isFollowing: Bool { follow.isFollowing }

    /// Course, but only when it means something.
    ///
    /// The receiver reports course as invalid below walking pace, and what it
    /// reports just above that is noise. A puck that spins at a red light, or a
    /// map that swings through ninety degrees while the car creeps in traffic,
    /// is worse than one that holds still.
    private var steadyCourse: Double? {
        guard let course = model.location.latestFix?.courseDegrees, course >= 0 else { return nil }
        guard (monitor?.currentSpeedKph ?? 0) >= 8 else { return nil }
        return course
    }

    private func followDriverIfDue() {
        guard isFollowing, let fix = model.location.latestFix else { return }

        // Holding the current heading rather than snapping to north is what
        // stops a stop-start crawl from rotating the world every few seconds.
        let heading = model.settings.mapOrientation == .courseUp
            ? (steadyCourse ?? follow.mapHeading)
            : 0

        withAnimation(.linear(duration: 1)) {
            follow.look(at: fix.coordinate, heading: heading)
        }
    }

    /// Three states in one glyph, so the button says what it will do next
    /// rather than only what it did last.
    private var followSymbol: String {
        guard isFollowing else { return "location" }
        return model.settings.mapOrientation == .courseUp ? "location.north.line.fill" : "location.fill"
    }

    private var followLabel: String {
        guard isFollowing else { return "Follow me again" }
        return model.settings.mapOrientation == .courseUp
            ? "Facing the way I drive. Tap for north up."
            : "North up. Tap to face the way I drive."
    }

    /// The tracking button, which cycles the way Apple Maps' does: off it
    /// starts following, on it swaps which way up the map is drawn.
    private func cycleFollowMode() {
        if !isFollowing {
            follow.resume()
        } else {
            model.settings.mapOrientation =
                model.settings.mapOrientation == .northUp ? .courseUp : .northUp
        }
        followDriverIfDue()
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
