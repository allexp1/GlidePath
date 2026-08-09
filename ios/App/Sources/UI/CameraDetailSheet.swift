import CoreLocation
import ZonexploCore
import MapKit
import SwiftUI

/// What you get when you tap a camera on the map.
///
/// The point is not decoration: the app spends its life making claims about
/// cameras out loud, and a driver who has just been warned about something is
/// entitled to see what the app actually knows. That includes the parts it is
/// unsure about, which is why `verified` gets a plain-English explanation rather
/// than being hidden.
struct CameraDetailSheet: View {
    let camera: ZonexploCore.Camera
    let units: DistanceUnits

    /// Where the driver is, when known, so the sheet can say how far away it is.
    let from: Coordinate?

    @Environment(\.dismiss) private var dismiss

    private var phrasebook: Phrasebook { Phrasebook(units: units) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    header

                    facts

                    if !camera.verified {
                        unverifiedNote
                    }

                    openInMaps
                }
                .padding(20)
            }
            .navigationTitle("Camera")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: - Pieces

    private var header: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 40, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 78, height: 78)
                .background(tint, in: Circle())

            Text(title)
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)

            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    private var facts: some View {
        VStack(spacing: 0) {
            if let limit = camera.speedLimitKph {
                fact("Speed limit", phrasebook.speedPhrase(limit), symbol: "speedometer")
                divider
            }

            fact("Direction", directionText, symbol: "arrow.triangle.turn.up.right.diamond")

            if let distance = distanceText {
                divider
                fact("Distance from you", distance, symbol: "location")
            }

            divider
            fact("Speed enforced", camera.type.enforcesInstantaneousSpeed ? "Yes" : "No", symbol: "gauge")

            divider
            fact(
                "Coordinates",
                String(format: "%.5f, %.5f", camera.coordinate.latitude, camera.coordinate.longitude),
                symbol: "mappin.and.ellipse"
            )
        }
        .padding(4)
        .zonexploGlass(cornerRadius: 20)
    }

    private var divider: some View {
        Divider().padding(.leading, 44)
    }

    private func fact(_ label: String, _ value: String, symbol: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(width: 22)

            Text(label)
                .font(.subheadline)

            Spacer(minLength: 12)

            Text(value)
                .font(.subheadline.weight(.medium))
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
    }

    private var unverifiedNote: some View {
        Label {
            Text(
                "This camera has disappeared from the map data it came from. It may have been "
                    + "removed, or the change upstream may simply be wrong, so Zonexplo keeps "
                    + "warning about it and shows it faded rather than dropping it."
            )
            .font(.footnote)
        } icon: {
            Image(systemName: "questionmark.circle.fill")
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .zonexploGlass(cornerRadius: 18, tint: .orange)
    }

    private var openInMaps: some View {
        Button {
            let placemark = MKPlacemark(
                coordinate: CLLocationCoordinate2D(
                    latitude: camera.coordinate.latitude,
                    longitude: camera.coordinate.longitude
                )
            )
            let item = MKMapItem(placemark: placemark)
            item.name = title
            item.openInMaps()
        } label: {
            Label("Open in Maps", systemImage: "map")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.glass)
        .controlSize(.large)
    }

    // MARK: - Text

    private var title: String {
        switch camera.type {
        case .fixed: return "Speed camera"
        case .redLight: return "Red light camera"
        case .combined: return "Speed and red light camera"
        case .seatbeltPhone: return "Seat belt and phone camera"
        case .busLane: return "Bus lane camera"
        case .mobileHotspot: return "Mobile camera spot"
        case .zoneEntry: return "Average speed zone entry"
        case .zoneExit: return "Average speed zone exit"
        }
    }

    private var subtitle: String {
        switch camera.type {
        case .mobileHotspot:
            return "Somewhere police are known to park a mobile unit. A warning that one "
                + "might be here, not that one is."
        case .zoneEntry:
            return "Your average speed starts being measured here."
        case .zoneExit:
            return "This is the camera the average speed coaching is aiming at."
        case .seatbeltPhone:
            return "Checks for seat belts and handheld phone use. It does not measure speed."
        case .redLight:
            return "Catches vehicles crossing on red. It does not measure speed."
        case .busLane:
            return "Enforces a restricted lane."
        case .fixed, .combined:
            return "A fixed installation that measures your speed as you pass."
        }
    }

    private var directionText: String {
        guard let bearing = camera.directionDegrees else { return "Both directions" }
        return "Traffic heading \(compass(bearing))"
    }

    private func compass(_ degrees: Double) -> String {
        let points = ["north", "north east", "east", "south east", "south", "south west", "west", "north west"]
        let index = Int(((degrees.truncatingRemainder(dividingBy: 360) + 360) / 45).rounded()) % 8
        return points[index]
    }

    private var distanceText: String? {
        guard let from else { return nil }
        return phrasebook.distancePhrase(from.distance(to: camera.coordinate))
    }

    private var symbol: String {
        switch camera.type {
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

    private var tint: Color {
        switch camera.type {
        case .zoneEntry, .zoneExit: return .purple
        case .mobileHotspot: return .gray
        case .redLight: return .red
        case .seatbeltPhone, .busLane: return .blue
        case .fixed, .combined: return .orange
        }
    }
}
