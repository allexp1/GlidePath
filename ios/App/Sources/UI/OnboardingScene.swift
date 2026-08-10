import SwiftUI

/// A different animated scene behind each first-run panel.
///
/// Four ideas, four motions, four colours drawn from one family. The variety is
/// the argument: each screen asks for something different from the driver, and
/// a single looping backdrop would make four distinct requests feel like one
/// long preamble to get past.
///
/// | Step | Idea | Motion | Accent |
/// | --- | --- | --- | --- |
/// | intro | the road between two gantries | travel | cyan |
/// | whenInUse | a position being fixed | pulse | azure |
/// | always | the screen off, the app awake | breathe | indigo |
/// | data | coverage arriving | fill | mint |
///
/// The colours stay inside one blue-green family so the sequence reads as one
/// product changing subject rather than four themes. Everything is drawn in a
/// `Canvas`: these are a few dozen primitives a frame, and building them from
/// SwiftUI shapes would cost a view tree per dash.
struct OnboardingScene: View {
    let step: OnboardingView.Step

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: reduceMotion)) { timeline in
            Canvas(opaque: true, rendersAsynchronously: false) { context, size in
                // A fixed instant under Reduce Motion, chosen so each scene is
                // composed rather than caught mid-transit.
                let time = reduceMotion ? 8.0 : timeline.date.timeIntervalSinceReferenceDate
                draw(&context, size: size, time: time)
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }

    // MARK: - Palette

    /// One accent per step, all within a blue-green family.
    ///
    /// Static so the panel can ask for the same value. A symbol still tinted
    /// app-cyan over an indigo scene reads as two screens stacked rather than
    /// one, and that was exactly what it looked like.
    static func accent(for step: OnboardingView.Step) -> Color {
        switch step {
        case .intro:     return Color(red: 0.13, green: 0.78, blue: 0.88)  // cyan
        case .whenInUse: return Color(red: 0.30, green: 0.58, blue: 1.00)  // azure
        case .always:    return Color(red: 0.55, green: 0.50, blue: 0.96)  // indigo
        case .data:      return Color(red: 0.20, green: 0.86, blue: 0.66)  // mint
        }
    }

    private var accent: Color { Self.accent(for: step) }

    private var skyTop: Color {
        switch step {
        case .intro:     return Color(red: 0.02, green: 0.07, blue: 0.19)
        case .whenInUse: return Color(red: 0.02, green: 0.05, blue: 0.17)
        case .always:    return Color(red: 0.01, green: 0.02, blue: 0.07)
        case .data:      return Color(red: 0.01, green: 0.09, blue: 0.13)
        }
    }

    private var skyBottom: Color {
        switch step {
        case .intro:     return Color(red: 0.04, green: 0.17, blue: 0.38)
        case .whenInUse: return Color(red: 0.04, green: 0.13, blue: 0.34)
        case .always:    return Color(red: 0.05, green: 0.05, blue: 0.18)
        case .data:      return Color(red: 0.03, green: 0.22, blue: 0.26)
        }
    }

    // MARK: - Composition

    private func draw(_ context: inout GraphicsContext, size: CGSize, time: Double) {
        backdrop(&context, size: size)

        switch step {
        case .intro:     drawRoad(&context, size: size, time: time)
        case .whenInUse: drawFix(&context, size: size, time: time)
        case .always:    drawNight(&context, size: size, time: time)
        case .data:      drawCoverage(&context, size: size, time: time)
        }

        // The panel is translucent by design, so without this the scene runs
        // through the body copy and takes the contrast with it.
        context.fill(
            Path(CGRect(x: 0, y: size.height * 0.38, width: size.width, height: size.height * 0.62)),
            with: .linearGradient(
                Gradient(colors: [.black.opacity(0), .black.opacity(0.62)]),
                startPoint: CGPoint(x: 0, y: size.height * 0.38),
                endPoint: CGPoint(x: 0, y: size.height * 0.60)
            )
        )
    }

    private func backdrop(_ context: inout GraphicsContext, size: CGSize) {
        context.fill(
            Path(CGRect(origin: .zero, size: size)),
            with: .linearGradient(
                Gradient(colors: [skyTop, skyBottom, skyTop]),
                startPoint: .zero,
                endPoint: CGPoint(x: 0, y: size.height)
            )
        )
    }

    /// A soft light behind the subject. Many stops rather than two, because a
    /// two-stop radial gradient shows its own edge as a visible oval.
    private func halo(
        _ context: inout GraphicsContext,
        at centre: CGPoint,
        radius: CGFloat,
        colour: Color,
        strength: Double
    ) {
        let stops = (0...6).map { index -> Gradient.Stop in
            let t = Double(index) / 6.0
            return .init(color: colour.opacity(strength * pow(1 - t, 2.4)), location: t)
        }
        context.fill(
            Path(ellipseIn: CGRect(
                x: centre.x - radius, y: centre.y - radius,
                width: radius * 2, height: radius * 2
            )),
            with: .radialGradient(
                Gradient(stops: stops),
                center: centre,
                startRadius: 0,
                endRadius: radius
            )
        )
    }

    // MARK: - 1. The road · travel

    private func drawRoad(_ context: inout GraphicsContext, size: CGSize, time: Double) {
        let horizon = size.height * 0.30
        let centreX = size.width / 2

        halo(&context, at: CGPoint(x: centreX, y: horizon),
             radius: size.width * 0.62, colour: accent, strength: 0.40)

        var surface = Path()
        surface.move(to: CGPoint(x: centreX - 1.5, y: horizon))
        surface.addLine(to: CGPoint(x: centreX + 1.5, y: horizon))
        surface.addLine(to: CGPoint(x: centreX + roadHalf(1, size: size), y: size.height))
        surface.addLine(to: CGPoint(x: centreX - roadHalf(1, size: size), y: size.height))
        surface.closeSubpath()
        context.fill(surface, with: .color(Color(red: 0.01, green: 0.05, blue: 0.12).opacity(0.92)))

        for side in [-1.0, 1.0] {
            var edge = Path()
            edge.move(to: CGPoint(x: centreX + CGFloat(side) * 1.5, y: horizon))
            edge.addLine(to: CGPoint(x: centreX + CGFloat(side) * roadHalf(1, size: size), y: size.height))
            context.stroke(
                edge,
                with: .linearGradient(
                    Gradient(colors: [accent.opacity(0), accent]),
                    startPoint: CGPoint(x: 0, y: horizon),
                    endPoint: CGPoint(x: 0, y: size.height)
                ),
                style: StrokeStyle(lineWidth: 3.5, lineCap: .round)
            )
        }

        // Centre dashes, flowing toward the viewer.
        let dashes = 20
        for index in 0..<dashes {
            let raw = Double(index) / Double(dashes) + time * 0.16
            let depth = raw - raw.rounded(.down)
            guard depth > 0.02 else { continue }
            let y = depthY(depth, horizon: horizon, height: size.height)
            let scale = depthScale(depth)
            let dashWidth = max(1.2, size.width * 0.022 * scale)
            let dashHeight = max(2, size.height * 0.075 * scale)
            context.fill(
                Path(roundedRect: CGRect(
                    x: centreX - dashWidth / 2, y: y - dashHeight / 2,
                    width: dashWidth, height: dashHeight
                ), cornerRadius: dashWidth / 2),
                with: .color(accent.opacity(min(0.95, 0.34 + scale)))
            )
        }

        drawGantries(&context, size: size, time: time, horizon: horizon, centreX: centreX)
    }

    /// The gantries, and the arc between them: the app's own mark, arriving.
    private func drawGantries(
        _ context: inout GraphicsContext,
        size: CGSize,
        time: Double,
        horizon: CGFloat,
        centreX: CGFloat
    ) {
        for offset in [0.0, 0.34, 0.67] {
            let raw = time * 0.038 + offset
            let depth = raw - raw.rounded(.down)
            guard depth > 0.08 else { continue }
            let y = depthY(depth, horizon: horizon, height: size.height)
            let scale = depthScale(depth)
            let half = roadHalf(depth, size: size) * 1.16
            let postHeight = size.height * 0.34 * scale
            let postWidth = max(1.5, size.width * 0.028 * scale)
            let opacity = min(0.95, 0.30 + scale * 1.6)

            for side in [-1.0, 1.0] {
                context.fill(
                    Path(roundedRect: CGRect(
                        x: centreX + CGFloat(side) * half - postWidth / 2,
                        y: y - postHeight, width: postWidth, height: postHeight
                    ), cornerRadius: postWidth * 0.35),
                    with: .color(accent.opacity(opacity))
                )
            }

            var arc = Path()
            arc.move(to: CGPoint(x: centreX - half, y: y - postHeight))
            arc.addQuadCurve(
                to: CGPoint(x: centreX + half, y: y - postHeight),
                control: CGPoint(x: centreX, y: y - postHeight - half * 0.55)
            )
            context.stroke(
                arc, with: .color(accent.opacity(opacity * 0.85)),
                style: StrokeStyle(lineWidth: max(1.2, postWidth * 0.7), lineCap: .round)
            )
        }
    }

    // MARK: - 2. The fix · pulse

    /// A position settling. Rings go out from a fixed point over a ground plane
    /// that keeps moving, which says the phone is locating the car rather than
    /// the car waiting for the phone.
    private func drawFix(_ context: inout GraphicsContext, size: CGSize, time: Double) {
        let centre = CGPoint(x: size.width / 2, y: size.height * 0.26)

        halo(&context, at: centre, radius: size.width * 0.66, colour: accent, strength: 0.34)

        // A ground plane in perspective: horizontal rules receding, verticals
        // converging. Enough to read as "somewhere", not as a map.
        let horizon = size.height * 0.10
        for index in 0..<11 {
            let raw = Double(index) / 11.0 + time * 0.05
            let depth = raw - raw.rounded(.down)
            let y = depthY(depth, horizon: horizon, height: size.height * 0.62)
            var line = Path()
            line.move(to: CGPoint(x: 0, y: y))
            line.addLine(to: CGPoint(x: size.width, y: y))
            context.stroke(line, with: .color(accent.opacity(0.05 + depthScale(depth) * 0.16)), lineWidth: 1)
        }
        for index in -4...4 {
            var line = Path()
            line.move(to: CGPoint(x: size.width / 2 + CGFloat(index) * 6, y: horizon))
            line.addLine(to: CGPoint(x: size.width / 2 + CGFloat(index) * size.width * 0.30, y: size.height * 0.62))
            context.stroke(line, with: .color(accent.opacity(0.10)), lineWidth: 1)
        }

        // Three rings, staggered, expanding and fading.
        for ring in 0..<3 {
            let raw = time * 0.5 + Double(ring) / 3.0
            let pulse = raw - raw.rounded(.down)
            let radius = size.width * 0.06 + CGFloat(pulse) * size.width * 0.42
            context.stroke(
                Path(ellipseIn: CGRect(
                    x: centre.x - radius, y: centre.y - radius * 0.5,
                    width: radius * 2, height: radius
                )),
                with: .color(accent.opacity((1 - pulse) * 0.7)),
                lineWidth: 2
            )
        }

        // The car. Solid, still, and the only thing here that never moves.
        let dot = size.width * 0.024
        context.fill(
            Path(ellipseIn: CGRect(x: centre.x - dot, y: centre.y - dot, width: dot * 2, height: dot * 2)),
            with: .color(.white)
        )
    }

    // MARK: - 3. The night · breathe

    /// The screen is off and the app is not. A slow breath rather than a loop:
    /// nothing here travels, because the point is that nothing needs to.
    private func drawNight(_ context: inout GraphicsContext, size: CGSize, time: Double) {
        let centre = CGPoint(x: size.width / 2, y: size.height * 0.24)

        // Breath: 5.5 seconds in and out, near the resting rate of somebody
        // who is not looking at their phone.
        let breath = (sin(time * 2 * .pi / 5.5) + 1) / 2

        halo(&context, at: centre, radius: size.width * (0.42 + 0.10 * breath),
             colour: accent, strength: 0.20 + 0.16 * breath)

        // A phone, dark, with one line of light still alive inside it.
        let phoneWidth = size.width * 0.30
        let phoneHeight = phoneWidth * 1.72
        let phone = CGRect(
            x: centre.x - phoneWidth / 2, y: centre.y - phoneHeight / 2,
            width: phoneWidth, height: phoneHeight
        )
        context.fill(
            Path(roundedRect: phone, cornerRadius: phoneWidth * 0.22),
            with: .color(Color(red: 0.02, green: 0.02, blue: 0.06))
        )
        context.stroke(
            Path(roundedRect: phone, cornerRadius: phoneWidth * 0.22),
            with: .color(accent.opacity(0.30 + 0.35 * breath)),
            lineWidth: 1.6
        )

        var wave = Path()
        let waveY = centre.y
        wave.move(to: CGPoint(x: phone.minX + phoneWidth * 0.16, y: waveY))
        for stepIndex in 0...24 {
            let t = Double(stepIndex) / 24.0
            let x = phone.minX + phoneWidth * (0.16 + 0.68 * t)
            let amplitude = phoneHeight * 0.05 * sin(t * .pi) * (0.35 + breath)
            wave.addLine(to: CGPoint(x: x, y: waveY + CGFloat(amplitude * sin(t * 12 - time * 3))))
        }
        context.stroke(
            wave, with: .color(accent.opacity(0.55 + 0.35 * breath)),
            style: StrokeStyle(lineWidth: 2, lineCap: .round)
        )

        // Distant traffic, still going past in the dark.
        for index in 0..<7 {
            let raw = time * 0.07 + Double(index) / 7.0
            let depth = raw - raw.rounded(.down)
            let y = size.height * 0.06 + CGFloat(index % 3) * size.height * 0.035
            let x = size.width * CGFloat(depth)
            context.fill(
                Path(ellipseIn: CGRect(x: x, y: y, width: 2.5, height: 2.5)),
                with: .color(accent.opacity(0.18 + 0.2 * sin(depth * .pi)))
            )
        }
    }

    // MARK: - 4. Coverage · fill

    /// Europe, with the covered countries filling one after another.
    ///
    /// Real boundaries rather than shapes: hand-drawn polygons were tried and
    /// looked hand-drawn, and at this size a coastline is the only thing that
    /// reads as a map. The outlines are Natural Earth 110m simplified to 0.18
    /// degrees — the whole continent for 760 points.
    ///
    /// Uncovered countries stay as outline so the fill has something to be
    /// filled *within*. A lit country floating on black says nothing about
    /// where it is.
    private func drawCoverage(_ context: inout GraphicsContext, size: CGSize, time: Double) {
        let centre = CGPoint(x: size.width / 2, y: size.height * 0.23)
        halo(&context, at: centre, radius: size.width * 0.62, colour: accent, strength: 0.22)

        // The window, aspect-corrected on longitude. At 55 degrees north a
        // degree of longitude covers about cos(55) of the ground a degree of
        // latitude does, so x is what compresses; squashing y instead flattens
        // the continent into a smear, which is what the first attempt did.
        let minLon = -11.0, maxLon = 32.0, minLat = 35.0, maxLat = 71.5
        let lonSquash = CGFloat(cos(55.0 * .pi / 180))

        let scaleLon = min(
            size.width * 0.92 / CGFloat(maxLon - minLon),
            size.height * 0.36 / CGFloat(maxLat - minLat) * lonSquash
        )
        let scaleLat = scaleLon / lonSquash
        let boxWidth = CGFloat(maxLon - minLon) * scaleLon
        let boxHeight = CGFloat(maxLat - minLat) * scaleLat
        let originX = centre.x - boxWidth / 2
        let originY = centre.y - boxHeight / 2

        func project(_ lon: Double, _ lat: Double) -> CGPoint {
            CGPoint(
                x: originX + CGFloat(lon - minLon) * scaleLon,
                y: originY + boxHeight - CGFloat(lat - minLat) * scaleLat
            )
        }

        let order = EuropeMap.fillOrder
        let cycle = time.truncatingRemainder(dividingBy: Double(order.count) * 1.15)
        let activeIndex = Int(cycle / 1.15)
        let within = (cycle / 1.15) - Double(activeIndex)
        let active = order[min(activeIndex, order.count - 1)]

        for (iso, ring) in EuropeMap.outlines {
            var path = Path()
            for (index, point) in ring.enumerated() {
                let projected = project(point.0, point.1)
                if index == 0 { path.move(to: projected) } else { path.addLine(to: projected) }
            }
            path.closeSubpath()

            let isCovered = EuropeMap.covered.contains(iso)
            let isActive = iso == active
            let filled = order.firstIndex(of: iso).map { $0 < activeIndex } ?? false

            // Fills over the first third of its turn, then holds lit, so the
            // map settles rather than blinking.
            let fill: Double = isActive ? min(1, within / 0.32) : (filled ? 0.62 : 0)

            context.fill(
                path,
                with: .color(accent.opacity((isCovered ? 0.07 : 0.035) + fill * 0.42))
            )
            context.stroke(
                path,
                with: .color(accent.opacity((isCovered ? 0.34 : 0.16) + fill * 0.55)),
                style: StrokeStyle(lineWidth: isActive ? 1.8 : 0.9, lineJoin: .round)
            )
        }
    }

    // MARK: - Perspective
    //
    // `depth` runs 0 at the horizon to 1 at the viewer. The cube is what turns
    // a constant increase in it into something that looks like constant speed
    // rather than an object sliding down the screen.

    private func depthY(_ depth: Double, horizon: CGFloat, height: CGFloat) -> CGFloat {
        horizon + (height - horizon) * CGFloat(pow(max(depth, 0), 3.0))
    }

    private func depthScale(_ depth: Double) -> CGFloat {
        CGFloat(pow(max(depth, 0), 2.1))
    }

    private func roadHalf(_ depth: Double, size: CGSize) -> CGFloat {
        max(2, size.width * 0.78 * depthScale(depth))
    }
}
