import SwiftUI

/// Where you are, and which way you are pointing.
///
/// Replaces `UserAnnotation()` for two reasons, and the first one is a bug
/// rather than a preference. Map content draws in the order it is declared, so
/// the stock blue dot - declared before the camera pins - sits *underneath*
/// them. On a road with a camera at your position you simply vanish, which is
/// the one thing on this screen that must never happen. Declared last, this
/// cannot be covered by anything.
///
/// The second is that a dot says "a phone is here" when the useful sentence is
/// "a car is here, pointing that way". With a zone drawn ahead of you, which
/// end of it you are facing is the whole question.
///
/// **Rotated by course over ground, never by the compass.** Device heading is
/// where the phone is pointing, and a phone in a cup holder points at the
/// ceiling; course is where the car is actually going. It is unavailable below
/// walking pace - the receiver reports it as invalid rather than guessing - and
/// a chevron that spins while you sit at a light is worse than no chevron, so
/// stationary falls back to a plain dot.
struct UserPuck: View {
    /// Direction of travel, degrees from true north. Nil when stopped.
    let courseDegrees: Double?

    /// Which way the map itself is facing, so the puck can point at the road
    /// rather than at the top of the screen. Zero in north-up; in course-up
    /// the two cancel out and the chevron sits still pointing up, which is what
    /// makes a rotating map readable.
    let mapHeadingDegrees: Double

    private var isMoving: Bool { courseDegrees != nil }

    var body: some View {
        ZStack {
            // A soft halo, so the puck separates from a busy map without
            // needing a heavy outline that would read as another pin.
            Circle()
                .fill(Color.accentColor.opacity(0.18))
                .frame(width: 46, height: 46)

            if isMoving {
                Chevron()
                    .fill(Color.accentColor)
                    .frame(width: 26, height: 28)
                    .overlay(Chevron().stroke(.white, lineWidth: 2.5))
                    .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
                    .rotationEffect(.degrees((courseDegrees ?? 0) - mapHeadingDegrees))
            } else {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 18, height: 18)
                    .overlay(Circle().strokeBorder(.white, lineWidth: 3))
                    .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
            }
        }
        // Never eat a tap meant for a camera underneath.
        .allowsHitTesting(false)
        .animation(.snappy(duration: 0.25), value: isMoving)
        .accessibilityHidden(true)
    }
}

/// A blunt arrowhead with a notched tail - the shape every map uses for "you,
/// facing this way", because it reads at 20 points where an arrow does not.
private struct Chevron: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY - rect.height * 0.28))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}
