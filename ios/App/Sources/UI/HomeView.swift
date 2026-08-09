import ZonexploCore
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
                        SpeedLimitRoundel(
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

                if let zone = monitor?.activeZone, let advice = monitor?.currentAdvice {
                    ZoneLiveCard(zone: zone, advice: advice, units: model.settings.units)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                } else {
                    standbyCard
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
        .animation(.smooth(duration: 0.4), value: monitor?.activeZone?.id)
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

        return HStack(spacing: 10) {
            Image(systemName: outcome.passed ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(outcome.passed ? .green : .red)

            VStack(alignment: .leading, spacing: 1) {
                Text(outcome.passed ? "Last zone: clear" : "Last zone: over the limit")
                    .font(.subheadline.weight(.medium))
                Text(
                    "Averaged \(phrasebook.speedPhrase(outcome.averageKph)) "
                        + "against \(phrasebook.speedPhrase(outcome.limitKph))"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .zonexploGlass(cornerRadius: 18)
    }
}

/// The posted limit for the road under the car, drawn as the sign it comes from.
///
/// A European limit sign is a red annulus around a black number on white, and
/// copying it is not decoration: it is the one piece of iconography a driver can
/// read without reading, which is the entire requirement for something glanced
/// at from a moving car. A number in a rounded rectangle would have to be
/// interpreted.
///
/// The current speed sits underneath rather than inside, and goes red when over.
/// Colour alone never carries it - the number itself is the message - because a
/// red-green deficiency is common and a driver squinting at a phone in low
/// afternoon sun has effectively acquired one.
struct SpeedLimitRoundel: View {
    let limitKph: Double
    let speedKph: Double?
    let units: DistanceUnits

    private var phrasebook: Phrasebook { Phrasebook(units: units) }

    private var isOver: Bool {
        guard let speedKph else { return false }
        return speedKph - limitKph >= SpeedLimitMonitor.Thresholds.standard.allowance(for: limitKph)
    }

    var body: some View {
        VStack(spacing: 5) {
            Text(phrasebook.speedPhrase(limitKph))
                .font(.system(size: 25, weight: .heavy, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.black)
                .frame(width: 62, height: 62)
                .background(.white, in: Circle())
                .overlay(Circle().strokeBorder(.red, lineWidth: 7))
                .shadow(radius: 3, y: 1)

            if let speedKph {
                Text(phrasebook.speedPhrase(speedKph))
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(isOver ? .red : .primary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 3)
                    .zonexploGlass(cornerRadius: 11)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        let limit = "Speed limit \(phrasebook.speedPhrase(limitKph))"
        guard let speedKph else { return limit }
        return "\(limit). You are doing \(phrasebook.speedPhrase(speedKph))"
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
