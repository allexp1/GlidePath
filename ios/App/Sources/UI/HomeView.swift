import GlidePathCore
import MapKit
import SwiftUI

/// The home screen: a map you are not meant to look at.
///
/// GlidePath is not a navigator and must not compete with one. The map exists
/// to answer one question, "is it actually watching?", and to make the camera
/// data tangible enough to trust. The moment a zone starts, the live card takes
/// over the screen and the map becomes background texture.
struct HomeView: View {
    @Environment(AppModel.self) private var model

    @State private var camera: MapCameraPosition = .userLocation(fallback: .automatic)

    private var monitor: DriveMonitor? { model.monitor }

    var body: some View {
        ZStack(alignment: .bottom) {
            map
                .ignoresSafeArea()

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
    }

    // MARK: - Map

    private var map: some View {
        Map(position: $camera) {
            UserAnnotation()

            ForEach(monitor?.nearbyCameras.prefix(120) ?? [], id: \.id) { camera in
                Annotation(
                    "",
                    coordinate: CLLocationCoordinate2D(
                        latitude: camera.coordinate.latitude,
                        longitude: camera.coordinate.longitude
                    )
                ) {
                    CameraPin(type: camera.type, verified: camera.verified)
                }
            }
        }
        .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
        .mapControls {
            MapUserLocationButton()
            MapCompass()
        }
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
            .glidePathGlass(cornerRadius: 30)
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
        .glidePathGlass(cornerRadius: 18)
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
