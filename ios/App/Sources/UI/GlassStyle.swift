import SwiftUI

/// The app's use of Liquid Glass, in one place.
///
/// Two rules the rest of the UI relies on:
///
/// 1. **Reduce Transparency wins.** iOS frosts glass more heavily on its own
///    when the setting is on, but a live coaching number over a moving map is
///    exactly the case where "more heavily frosted" is still not enough. When
///    the setting is on, the glass is switched off and a solid surface takes its
///    place. A driver who has asked for legibility gets legibility.
/// 2. **Glass never carries meaning alone.** Tier is communicated by the words
///    and the number; the tint is a reinforcement, never the signal, because
///    tinted translucency over an arbitrary map is not a colour anyone can rely
///    on reading correctly at a glance.
extension View {
    /// The standard GlidePath surface: a glass panel with a continuous corner.
    func glidePathGlass(
        cornerRadius: CGFloat = 28,
        tint: Color? = nil,
        interactive: Bool = false
    ) -> some View {
        modifier(
            GlidePathGlassModifier(
                shape: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous),
                tint: tint,
                interactive: interactive
            )
        )
    }

    /// A pill, for controls and small readouts.
    func glidePathGlassCapsule(tint: Color? = nil, interactive: Bool = true) -> some View {
        modifier(GlidePathGlassModifier(shape: Capsule(), tint: tint, interactive: interactive))
    }
}

// InsettableShape rather than Shape: strokeBorder draws the line inside the
// shape's bounds, which is what keeps the border from being clipped in half by
// the shape's own edge. Every shape this is used with qualifies.
private struct GlidePathGlassModifier<S: InsettableShape>: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    let shape: S
    let tint: Color?
    let interactive: Bool

    func body(content: Content) -> some View {
        if reduceTransparency {
            content
                .background(.background.secondary, in: shape)
                .overlay(shape.strokeBorder(Color(uiColor: .separator), lineWidth: 1))
        } else {
            content.glassEffect(glass, in: shape)
        }
    }

    private var glass: Glass {
        var glass = Glass.regular
        if let tint {
            glass = glass.tint(tint)
        }
        if interactive {
            glass = glass.interactive()
        }
        return glass
    }
}

/// Colour per coaching tier. Reinforcement only, never the sole signal.
enum TierPalette {
    static func tint(for tier: CoachingTierAppearance) -> Color {
        switch tier {
        case .normal: return .green
        case .tight: return .orange
        case .impossible: return .red
        case .idle: return .accentColor
        }
    }
}

enum CoachingTierAppearance {
    case idle
    case normal
    case tight
    case impossible
}
