import SwiftUI

/// What the law says where this country is, before its cameras are downloaded.
///
/// Several countries restrict camera warnings and they do it in different ways:
/// Germany prohibits *operating* such a device while driving, Austria and
/// Switzerland prohibit the device itself, France requires broad danger zones
/// rather than exact positions. An app that offers all 243 countries and
/// mentions none of this is leaving the driver to find out from a police
/// officer.
///
/// The posture is informed consent rather than a block. Hiding these countries
/// would decide for an adult in a jurisdiction we have not taken advice on, and
/// would also hide the country from somebody merely planning a route. So the
/// notice names the specific law - "it may be illegal" is not something anyone
/// can act on - and the driver chooses.
struct LegalNoticeSheet: View {
    let country: CountrySyncService.CountryStatus
    let decision: (Bool) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Label {
                        Text(country.isProhibited
                             ? "Prohibited in \(country.name)"
                             : "Restricted in \(country.name)")
                            .font(.title3.weight(.semibold))
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(country.isProhibited ? .red : .orange)
                    }

                    if let note = country.legalNote {
                        Text(note)
                            .font(.callout)
                    }

                    Text(
                        "Zonexplo cannot tell you what to do here, and downloading the data is "
                            + "not itself the issue - using it while driving is. You are "
                            + "responsible for whether you run the app in this country."
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                    Text(
                        "You can download the country now and leave alerts switched off, or turn "
                            + "watching off before you cross the border."
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
            .navigationTitle("Before you download")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 10) {
                    Button("I understand — download anyway") { decision(true) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .frame(maxWidth: .infinity)

                    Button("Cancel") { decision(false) }
                        .controlSize(.large)
                }
                .padding(20)
                .background(.bar)
            }
        }
        .presentationDetents([.medium, .large])
    }
}
