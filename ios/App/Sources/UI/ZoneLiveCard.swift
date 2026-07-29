import GlidePathCore
import SwiftUI

/// The in-zone display: one enormous number and three supporting figures.
///
/// This is read at 110 km/h, in a glance measured in tenths of a second, so the
/// hierarchy is brutal. The target speed is the only thing sized to be read
/// peripherally. Everything else exists so a driver who does look properly can
/// check the app's reasoning, which matters for an app whose whole proposition
/// is "trust me, hold this speed".
struct ZoneLiveCard: View {
    let zone: Zone
    let advice: CoachingAdvice
    let units: DistanceUnits

    @Namespace private var glassNamespace

    private var phrasebook: Phrasebook { Phrasebook(units: units) }

    private var appearance: CoachingTierAppearance {
        switch advice.tier {
        case .normal: return .normal
        case .tight: return .tight
        case .impossible: return .impossible
        }
    }

    var body: some View {
        GlassEffectContainer(spacing: 18) {
            VStack(spacing: 18) {
                header

                if advice.isSuppressed {
                    suppressedBody
                } else {
                    targetSpeed
                }

                figures

                if case let .pause(seconds, stop, distance)? = advice.recovery {
                    recoveryNote(seconds: seconds, stop: stop, distance: distance)
                } else if case .unrecoverable? = advice.recovery {
                    unrecoverableNote
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity)
            .glidePathGlass(cornerRadius: 32, tint: TierPalette.tint(for: appearance))
            .glassEffectID("zone-card", in: glassNamespace)
        }
        .animation(.smooth(duration: 0.35), value: advice.tier)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
    }

    // MARK: - Pieces

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "camera.metering.matrix")
                .font(.footnote.weight(.semibold))
            Text(zone.name ?? zone.roadRef.map { "Route \($0)" } ?? "Average speed zone")
                .font(.footnote.weight(.semibold))
            Spacer()
            Text("Limit \(phrasebook.speedPhrase(zone.speedLimitKph))")
                .font(.footnote.weight(.medium))
                .monospacedDigit()
        }
        .foregroundStyle(.secondary)
    }

    private var targetSpeed: some View {
        VStack(spacing: 2) {
            Text(advice.targetSpeedKph.map { phrasebook.speedPhrase($0) } ?? "--")
                .font(.system(size: 96, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .minimumScaleFactor(0.5)
                .lineLimit(1)
                .contentTransition(.numericText())

            Text(instruction)
                .font(.headline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    /// In a jam, showing a target speed would be actively misleading. The card
    /// says why it has gone quiet instead of just going blank, so the driver
    /// does not assume the app has crashed.
    private var suppressedBody: some View {
        VStack(spacing: 8) {
            Image(systemName: "car.side.and.exclamationmark")
                .font(.system(size: 44, weight: .light))
            Text("Traffic")
                .font(.title2.weight(.semibold))
            Text("Waiting for you to get moving. Time spent stopped counts in your favour.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.vertical, 12)
    }

    private var instruction: String {
        switch advice.tier {
        case .normal: return "You are fine, hold this"
        case .tight: return "Hold this to the exit camera"
        case .impossible: return "Slowest safe speed"
        }
    }

    private var figures: some View {
        HStack(spacing: 12) {
            figure(
                label: "Average",
                value: phrasebook.speedPhrase(advice.currentAverageKph),
                emphasised: advice.currentAverageKph > zone.speedLimitKph
            )
            figure(
                label: "Left",
                value: phrasebook.distancePhrase(advice.distanceRemainingMeters)
            )
            figure(
                label: "Spare",
                value: spareTime
            )
        }
    }

    /// Seconds of slack against the minimum legal time. Negative is the number
    /// that matters: it is how far into the red the driver already is.
    private var spareTime: String {
        let budget = advice.allowance.remainingTimeBudgetSeconds
        let drivingTime = advice.distanceRemainingMeters / Units.mps(fromKph: zone.speedLimitKph)
        let spare = budget - drivingTime

        if spare >= 0 {
            return "+\(Int(spare.rounded()))s"
        }
        return "\(Int(spare.rounded()))s"
    }

    private func figure(label: String, value: String, emphasised: Bool = false) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.title3.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(emphasised ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(label)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.tertiary)
                .textCase(.uppercase)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .glidePathGlass(cornerRadius: 16)
    }

    private func recoveryNote(seconds: TimeInterval, stop: RestStop, distance: Double) -> some View {
        Label {
            Text(
                "\(stop.name ?? "A stop") in \(phrasebook.distancePhrase(distance)). "
                    + "Pause \(phrasebook.durationPhrase(seconds)) to come out clean."
            )
            .font(.subheadline)
        } icon: {
            Image(systemName: "pause.circle.fill")
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glidePathGlass(cornerRadius: 18, tint: .orange)
    }

    private var unrecoverableNote: some View {
        Label {
            Text("This one is already lost, and there is nowhere to stop. Drive normally.")
                .font(.subheadline)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glidePathGlass(cornerRadius: 18, tint: .red)
    }

    private var accessibilitySummary: String {
        guard !advice.isSuppressed else {
            return "In traffic. Coaching paused."
        }
        guard let target = advice.targetSpeedKph else { return "In an average speed zone." }
        return "Hold \(phrasebook.speedPhrase(target)). "
            + "\(phrasebook.distancePhrase(advice.distanceRemainingMeters)) remaining. "
            + "Average so far \(phrasebook.speedPhrase(advice.currentAverageKph))."
    }
}
