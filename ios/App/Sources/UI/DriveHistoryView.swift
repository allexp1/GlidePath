import ZonexploCore
import SwiftUI

/// Every average-speed zone this phone has driven, and how it went.
///
/// The app succeeds by saying nothing. That is correct behaviour and it is also
/// indistinguishable from a broken app, which is a real problem for something a
/// driver has to trust before it has ever spoken to them. This screen is the
/// evidence: it is where "it never said anything" becomes "it took me through
/// eleven zones and I passed all of them".
///
/// The rows were already being written - `LocalCameraStore.record` has stored
/// every completed zone since v1 - and nothing has ever read them.
///
/// Local only, and it stays that way. Where somebody has been driving is the
/// one thing this product refuses to send anywhere, and a list of zones with
/// timestamps is exactly that.
struct DriveHistoryView: View {
    @Environment(AppModel.self) private var model

    @State private var runs: [ZoneRun] = []
    @State private var loaded = false

    var body: some View {
        List {
            if !runs.isEmpty {
                Section {
                    LabeledContent("Zones driven", value: "\(runs.count)")
                    LabeledContent("Came out legal", value: passRateLabel)
                } footer: {
                    Text(
                        "A zone counts here once you have driven from its entry camera to its "
                            + "exit. Anything you turned off before the end is not a result and "
                            + "is not recorded."
                    )
                }
            }

            Section {
                ForEach(runs) { row(for: $0) }
            } header: {
                if !runs.isEmpty { Text("Recent") }
            }
        }
        .navigationTitle("Drive history")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            runs = (try? await model.store?.recentZoneRuns(limit: 200)) ?? []
            loaded = true
        }
        .overlay {
            if loaded, runs.isEmpty {
                ContentUnavailableView(
                    "No zones yet",
                    systemImage: "road.lanes",
                    description: Text(
                        "Once you drive through an average-speed zone with Zonexplo watching, "
                            + "how it went is recorded here. Nothing leaves your phone."
                    )
                )
            }
        }
    }

    private func row(for run: ZoneRun) -> some View {
        HStack(spacing: 12) {
            Image(systemName: run.passed ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.title3)
                .foregroundStyle(run.passed ? .green : .orange)
                .frame(width: 26)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(run.zoneName ?? "Average-speed zone")
                    .font(.body)
                Text(detail(for: run))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Text(run.enteredAt, format: .dateTime.day().month().hour().minute())
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(run.zoneName ?? "Average-speed zone"). \(detail(for: run)). "
                + (run.passed ? "Passed." : "Over the limit.")
        )
    }

    /// The average held against the limit, which is the only number the exit
    /// camera cared about and therefore the only one worth showing.
    ///
    /// Formatted through the Phrasebook so the screen and the voice cannot
    /// disagree about what unit the driver asked for.
    private func detail(for run: ZoneRun) -> String {
        let phrasebook = Phrasebook(units: model.settings.units)
        let unit = model.settings.units == .metric ? "km/h" : "mph"
        let verdict = run.passed ? "held" : "averaged"

        return "\(verdict) \(phrasebook.speedPhrase(run.averageKph)) "
            + "in a \(phrasebook.speedPhrase(run.limitKph)) \(unit)"
    }

    private var passRateLabel: String {
        let passed = runs.filter(\.passed).count
        guard !runs.isEmpty else { return "—" }
        if passed == runs.count { return "Every one" }
        return "\(passed) of \(runs.count)"
    }
}
