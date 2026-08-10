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

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Internal rather than private: the scene behind the panels is drawn from
    /// the same step, and a second source of truth for "where are we" is how
    /// the words and the picture end up disagreeing.
    enum Step: Int, CaseIterable {
        case intro
        case whenInUse
        case always
        case data
    }

    var body: some View {
        ZStack {
            OnboardingScene(step: step)

            GeometryReader { proxy in
              VStack(spacing: 0) {
                // A fixed window onto the road. Centring the panel instead put
                // it straight over the vanishing point, which hid the horizon,
                // the glow and every gantry - the whole reason the scene is
                // there - behind the words describing them.
                Color.clear.frame(height: proxy.size.height * 0.42)

                content
                    .padding(28)
                    .zonexploGlass(cornerRadius: 34)
                    .padding(.horizontal, 20)
                    // Each panel arrives from the direction of travel and the
                    // one before it leaves the same way, so the sequence reads
                    // as continuing rather than as four separate screens.
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .move(edge: .leading).combined(with: .opacity)
                    ))
                    .id(step)

                Spacer(minLength: 0)

                progress
                footer
              }
            }
        }
        .preferredColorScheme(.dark)
        .animation(motion, value: step)
    }

    /// One authored curve for the whole flow. Exponential ease-out, because a
    /// panel that decelerates into place feels arrived-at, and a linear one
    /// feels dragged.
    private var motion: Animation {
        reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.55, dampingFraction: 0.86)
    }

    /// Where the driver is in the sequence. Four steps is short enough that a
    /// bar would be over-instrumentation, and long enough that no indication at
    /// all leaves people wondering how much of this there is.
    private var progress: some View {
        HStack(spacing: 7) {
            ForEach(Step.allCases, id: \.rawValue) { item in
                Capsule()
                    .fill(item == step ? Color.white : Color.white.opacity(0.28))
                    .frame(width: item == step ? 22 : 7, height: 7)
            }
        }
        .padding(.bottom, 20)
        .accessibilityElement()
        .accessibilityLabel("Step \(step.rawValue + 1) of \(Step.allCases.count)")
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
                .foregroundStyle(OnboardingScene.accent(for: step))
                .symbolRenderingMode(.hierarchical)

            Text(title)
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
                .foregroundStyle(.white)
                // Without this the longest title truncates to one line -
                // "It needs to know where you a..." - because the panel offers
                // a width and Text takes it as a licence to clip.
                .fixedSize(horizontal: false, vertical: true)

            Text(text)
                .font(.callout)
                // Tinted off the scene's own blue rather than grey, which on a
                // navy backdrop reads as dirt.
                .foregroundStyle(Color(red: 0.78, green: 0.86, blue: 0.95))
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Actions

    private var footer: some View {
        VStack(spacing: 12) {
            Button(primaryTitle) { advance() }
                .buttonStyle(.glassProminent)
                // The call to action joins the scene it is standing on. A cyan
                // button on the mint screen was the last thing still insisting
                // all four steps were the same screen.
                .tint(OnboardingScene.accent(for: step))
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

}
