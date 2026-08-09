import CoreLocation
import SwiftUI

/// The permission explainer.
///
/// Zonexplo asks for Always location, which is the single most refused
/// permission on iOS and rightly so. The system prompt gives one line to
/// justify it, and one line is not enough, so the case is made here first and
/// the prompt is only raised once the driver has read it.
///
/// The order is forced by iOS: When In Use has to be granted before Always can
/// even be requested. Asking for Always cold does nothing at all.
struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    let onFinished: () -> Void

    @State private var step: Step = .intro

    private enum Step {
        case intro
        case whenInUse
        case always
        case data
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            content
                .padding(28)
                .zonexploGlass(cornerRadius: 34)
                .padding(.horizontal, 20)
            Spacer()
            footer
        }
        .background(backdrop)
        .animation(.smooth, value: step)
    }

    // MARK: - Steps

    @ViewBuilder
    private var content: some View {
        switch step {
        case .intro:
            panel(
                symbol: "gauge.with.needle",
                title: "A co-pilot, not a navigator",
                body: """
                    Keep using Waze or Google Maps. Zonexplo runs quietly behind them and \
                    speaks up about cameras.

                    In an average speed zone it works out the exact speed to hold so you \
                    come out under the limit, and tells you as the zone goes on.
                    """
            )

        case .whenInUse:
            panel(
                symbol: "location.fill",
                title: "It needs to know where you are",
                body: """
                    Your location is used to work out which cameras are ahead of you and how \
                    far along a zone you have travelled.

                    It never leaves your phone. There is no account, no tracking, and nothing \
                    about your journeys is uploaded anywhere.
                    """
            )

        case .always:
            panel(
                symbol: "moon.zzz.fill",
                title: "And while your screen is off",
                body: """
                    You will be looking at your navigation app, not at Zonexplo, so it has to \
                    keep working in the background. That is what "Always" allows.

                    It stays in a low power mode almost all the time and only switches on \
                    precise tracking inside a camera zone.
                    """
            )

        case .data:
            panel(
                symbol: "arrow.down.circle.fill",
                title: "Download your country",
                body: """
                    Camera data is downloaded once and then works with no signal at all, which \
                    matters on exactly the roads where signal is worst.

                    Updates after that are tiny.
                    """
            )
        }
    }

    private func panel(symbol: String, title: String, body text: String) -> some View {
        VStack(spacing: 18) {
            Image(systemName: symbol)
                .font(.system(size: 52, weight: .light))
                .foregroundStyle(.tint)
                .symbolRenderingMode(.hierarchical)

            Text(title)
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)

            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Actions

    private var footer: some View {
        VStack(spacing: 12) {
            Button(primaryTitle) { advance() }
                .buttonStyle(.glassProminent)
                .controlSize(.extraLarge)
                .frame(maxWidth: .infinity)

            if step == .always {
                Button("Not now") { step = .data }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 28)
    }

    private var primaryTitle: String {
        switch step {
        case .intro: return "Get started"
        case .whenInUse: return "Allow location"
        case .always: return "Allow in the background"
        case .data: return "Choose a country"
        }
    }

    private func advance() {
        switch step {
        case .intro:
            step = .whenInUse

        case .whenInUse:
            Task {
                let status = await model.location.requestWhenInUse()
                // A refusal is not a dead end: the app still works while it is
                // open, so carry on rather than stranding the driver on a
                // screen they cannot get past.
                step = status == .denied ? .data : .always
            }

        case .always:
            model.location.requestAlways()
            // The Always prompt is often deferred by iOS to a later moment of
            // its own choosing, so there is nothing to await here.
            step = .data

        case .data:
            onFinished()
        }
    }

    private var backdrop: some View {
        LinearGradient(
            colors: [.accentColor.opacity(0.35), .clear],
            startPoint: .top,
            endPoint: .center
        )
        .ignoresSafeArea()
        .background(Color(.systemBackground))
    }
}
