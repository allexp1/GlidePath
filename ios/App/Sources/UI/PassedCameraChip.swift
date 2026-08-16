import SwiftUI
import ZonexploCore

/// "Was it actually there?", asked at the only moment anyone knows.
///
/// Data quality is the weakest part of this product, and the only people who
/// can see that a camera is wrong are the drivers passing it. Today's harvest
/// translated 3,788 licence-plate readers in one state as speed cameras, and
/// nothing in the system would have said so.
///
/// The timing is the design. While a camera is ahead the driver is guessing; a
/// minute later they have stopped thinking about it. The seconds just after
/// passing are the only window where the answer is both known and still
/// interesting, so the question is asked there and nowhere else.
///
/// One tap, no typing, no confirmation step, and it goes away by itself. A
/// report screen at 100 km/h is a hazard, not a feature - so this is a single
/// target the size of a thumb, and everything else about the report is
/// inferred from what the app already knows.
///
/// Nothing is deleted. The camera keeps warning exactly as it did; the report
/// joins a queue for a human. A driver who is wrong, or malicious, costs
/// somebody a moment reading a row.
struct PassedCameraChip: View {
    let camera: ZonexploCore.Camera
    let onReport: () async -> Bool
    let onDismiss: () -> Void

    @State private var stage = Stage.asking

    /// Named Stage rather than State: an enum called State shadows the
    /// @State attribute and the compiler rejects the property wrapper outright.
    private enum Stage {
        case asking
        case sending
        case sent
        case failed
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 26)
                .accessibilityHidden(true)

            Text(message)
                .font(.subheadline.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 8)

            if stage == .asking || stage == .failed {
                Button {
                    report()
                } label: {
                    Text("No")
                        .font(.subheadline.weight(.semibold))
                        // The question wraps before the answer does. Without
                        // this the label breaks across two lines inside its own
                        // button, which is a strange thing to ask a driver to
                        // parse at speed.
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.horizontal, 16)
                        .frame(height: 44)
                }
                .buttonStyle(.glassProminent)
                .tint(.orange)
                .accessibilityLabel("Report that there is no \(name) here")

                Button {
                    onDismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Dismiss")
            } else if stage == .sending {
                ProgressView().frame(width: 44, height: 44)
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .zonexploGlass(cornerRadius: 22)
        .animation(.snappy(duration: 0.25), value: stage)
    }

    private func report() {
        stage = .sending
        Task {
            let ok = await onReport()
            stage = ok ? .sent : .failed
            if ok {
                Analytics.capture(.cameraReported, ["kind": "camera_gone", "from": "passed_chip"])
                // Left up long enough to be believed, then out of the way.
                try? await Task.sleep(for: .seconds(2.5))
                onDismiss()
            }
        }
    }

    private var message: String {
        switch stage {
        // Three words, because it has to be read in the time it takes to
        // glance up. Naming the camera type wrapped the chip onto three lines
        // and told the driver nothing they had not just been told out loud.
        case .asking: return "Was it there?"
        case .sending: return "Sending"
        case .sent: return "Thank you - somebody will check it"
        case .failed: return "That did not send. It needs a connection."
        }
    }

    private var symbol: String {
        switch stage {
        case .sent: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        default: return "questionmark.circle"
        }
    }

    private var tint: Color {
        switch stage {
        case .sent: return .green
        case .failed: return .orange
        default: return .secondary
        }
    }

    /// Named as the driver would name it, so the question is answerable without
    /// working out what the app meant.
    private var name: String {
        switch camera.type {
        case .redLight: return "red light camera"
        case .combined: return "camera"
        case .busLane: return "bus lane camera"
        case .seatbeltPhone: return "seat belt camera"
        case .mobileHotspot: return "mobile unit"
        default: return "speed camera"
        }
    }
}
