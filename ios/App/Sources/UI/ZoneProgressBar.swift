import SwiftUI
import ZonexploCore

/// How far through the section you are, and whether you are going to make it.
///
/// An average-speed zone is the one situation where a driver genuinely cannot
/// tell how they are doing. Instantaneous speed says nothing: you can be under
/// the limit at this instant and still be caught, and the exit camera will not
/// tell you until the fine arrives. The spoken target answers *what to do*.
/// This answers *how it is going*, which is the question people keep asking.
///
/// Two facts, one bar:
///
/// - **Length** is the section. The fill is how much of it is behind you, so
///   "nearly out of this" is readable without a number.
/// - **Colour** is the verdict. Green while the allowance is at or above the
///   limit, amber while it is below but still above the safety floor, red when
///   no legal speed is left. It is the tier the engine already decided, not a
///   second opinion computed here — a bar that disagreed with the voice would
///   be worse than no bar.
///
/// The marker is deliberately a hairline rather than a dot: this sits under a
/// live coaching number, and anything with more weight competes with it.
struct ZoneProgressBar: View {
    let advice: CoachingAdvice
    let zoneDistanceMeters: Double
    let units: DistanceUnits

    private var phrasebook: Phrasebook { Phrasebook(units: units) }

    private var progress: Double {
        guard zoneDistanceMeters > 0 else { return 0 }
        let covered = zoneDistanceMeters - advice.distanceRemainingMeters
        return min(1, max(0, covered / zoneDistanceMeters))
    }

    private var tint: Color { TierPalette.tint(for: advice.tier) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.white.opacity(0.14))

                    Capsule()
                        .fill(tint.gradient)
                        .frame(width: max(6, proxy.size.width * progress))

                    // Where you are. A hairline, because the number above is
                    // the thing being read and this is context for it.
                    Capsule()
                        .fill(.white)
                        .frame(width: 2.5)
                        .offset(x: max(0, proxy.size.width * progress - 1.25))
                        .shadow(color: .black.opacity(0.4), radius: 2)
                }
            }
            .frame(height: 10)
            .animation(.smooth(duration: 0.6), value: progress)
            .animation(.smooth(duration: 0.4), value: advice.tier)

            HStack {
                Text(verdict)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(tint)

                Spacer()

                Text("\(phrasebook.distancePhrase(advice.distanceRemainingMeters)) left")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(verdict). \(phrasebook.distancePhrase(advice.distanceRemainingMeters)) remaining "
                + "of the zone."
        )
    }

    /// Named for what it means to the driver rather than for the enum case.
    /// "Tight" is engine vocabulary; "hold this speed" is an instruction.
    private var verdict: String {
        switch advice.tier {
        case .normal: return "On track"
        case .tight: return "Hold this speed"
        case .impossible: return "Cannot make this one"
        }
    }
}
