import SwiftUI
import ZonexploCore

/// The posted limit, and whether you are over it, in one glance.
///
/// Two states rather than a dial, because a driver reads this in the fraction
/// of a second between looking up and looking back at the road:
///
/// - **Within the limit.** The sign shows the limit, ringed green. It is the
///   same shape as the sign on the pole, so it needs no learning.
/// - **Over it.** The sign fills red and the big number becomes *your* speed,
///   with the limit demoted to a chip above. When you are speeding the useful
///   number is the one you can change.
///
/// Filling rather than only re-tinting: a red ring on a white face reads as an
/// ordinary speed limit sign at a glance, which is exactly the glance this has
/// to survive. A solid red disc does not.
///
/// The threshold is the same one the voice uses, so the sign and the speech can
/// never disagree about whether you are speeding.
struct SpeedSign: View {
    let limitKph: Double
    let speedKph: Double?
    let units: DistanceUnits

    private var phrasebook: Phrasebook { Phrasebook(units: units) }

    private var isOver: Bool {
        guard let speedKph else { return false }
        return speedKph - limitKph >= SpeedLimitMonitor.Thresholds.standard.allowance(for: limitKph)
    }

    /// The limit when you are fine, your speed when you are not.
    private var headline: Double {
        isOver ? (speedKph ?? limitKph) : limitKph
    }

    var body: some View {
        VStack(spacing: 5) {
            if isOver {
                // Only present when over. A permanent second number would make
                // the compliant state busier than it needs to be.
                // A miniature of the sign itself rather than a dark pill.
                // Translucent black read as grey mush over a light map, which
                // is most of the time this chip is on screen; white with a
                // black numeral is legible over anything Apple Maps draws.
                Text(phrasebook.speedPhrase(limitKph))
                    .font(.system(size: 19, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.black)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 3)
                    .background(.white, in: Capsule())
                    .overlay(Capsule().strokeBorder(.black.opacity(0.85), lineWidth: 2.5))
                    .shadow(color: .black.opacity(0.3), radius: 3, y: 1)
                    .transition(.scale.combined(with: .opacity))
            }

            Text(phrasebook.speedPhrase(headline))
                .font(.system(size: 46, weight: .heavy, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(isOver ? .white : .black)
                .contentTransition(.numericText())
                .frame(width: 104, height: 104)
                .background(isOver ? Color.red : Color.white, in: Circle())
                .overlay(
                    Circle().strokeBorder(isOver ? Color.red : Color.green, lineWidth: 10)
                )
                // Enough shadow to hold an edge against a pale map without
                // reading as a drop-shadowed rectangle.
                .shadow(color: .black.opacity(0.4), radius: 7, y: 2)
        }
        .animation(.snappy(duration: 0.25), value: isOver)
        .animation(.snappy(duration: 0.25), value: headline)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            isOver
                ? "Over the limit. \(phrasePlain(speedKph ?? 0)) in a \(phrasePlain(limitKph))."
                : "Speed limit \(phrasePlain(limitKph))."
        )
    }

    private func phrasePlain(_ kph: Double) -> String {
        "\(phrasebook.speedPhrase(kph)) \(units == .metric ? "kilometres per hour" : "miles per hour")"
    }
}

/// A camera on the road ahead, shown as well as spoken.
///
/// The voice is the primary channel and stays that way — a driver should not
/// have to look at a phone to be warned. This is for the times the voice cannot
/// win: music loud, a passenger talking, a navigation instruction landing at
/// the same moment.
///
/// It states the distance, because "camera ahead" without one is an anxiety
/// rather than information.
struct CameraApproachBanner: View {
    let approach: CameraApproach
    let units: DistanceUnits

    private var phrasebook: Phrasebook { Phrasebook(units: units) }

    private var isImminent: Bool { approach.urgency == .imminent }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(isImminent ? .red : .orange)
                .frame(width: 28)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(phrasebook.distancePhrase(approach.distanceMeters))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }

            Spacer(minLength: 4)

            if let limit = approach.camera.speedLimitKph {
                Text(phrasebook.speedPhrase(limit))
                    .font(.system(size: 20, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.black)
                    .frame(width: 44, height: 44)
                    .background(.white, in: Circle())
                    .overlay(Circle().strokeBorder(.red, lineWidth: 5))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .zonexploGlass(cornerRadius: 20)
        .accessibilityElement(children: .combine)
    }

    private var title: String {
        switch approach.camera.type {
        case .mobileHotspot: return "Mobile camera spot"
        case .redLight: return "Red light camera"
        case .combined: return "Speed and red light camera"
        case .busLane: return "Bus lane camera"
        case .seatbeltPhone: return "Seat belt and phone camera"
        default: return isImminent ? "Camera now" : "Camera ahead"
        }
    }

    private var symbol: String {
        switch approach.camera.type {
        case .mobileHotspot: return "car.side.rear.and.exclamationmark.and.car.side.front"
        case .redLight, .combined: return "trafficlight.fill"
        case .busLane: return "bus.fill"
        case .seatbeltPhone: return "iphone.gen3.slash"
        default: return "camera.fill"
        }
    }
}
