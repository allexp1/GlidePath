import SwiftUI

/// One line of state the driver chose and will forget they chose.
///
/// The home screen already says what the app is doing. This says what it is
/// *not* doing, and why — which is the harder half, because an app that has
/// been told to stay quiet looks exactly like an app that is working.
///
/// Deliberately the same shape wherever it appears: a driver who learns this
/// row means "read me, something is off the default" should not have to learn
/// it twice.
///
/// The colour is on the symbol and nowhere else. Tinting the glass itself was
/// tried and is wrong: a filled orange panel is louder than the headline it
/// sits under, so the card ends up shouting its footnotes, and the symbol
/// vanishes into a background of its own colour. These rows are subordinate to
/// the card by design and have to look it.
struct DriveNotice: View {
    let symbol: String
    let tint: Color
    let title: String
    var detail: String?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .zonexploGlass(cornerRadius: 18)
        .accessibilityElement(children: .combine)
    }
}
