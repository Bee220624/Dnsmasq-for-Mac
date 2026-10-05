import SwiftUI

enum ConnectionPalette {
    static let blue = Color(red: 52 / 255, green: 120 / 255, blue: 246 / 255)
    static let ink = Color(red: 0.20, green: 0.24, blue: 0.31)
    static let red = Color(red: 0.89, green: 0.25, blue: 0.29)
    static let green = Color(red: 0.20, green: 0.73, blue: 0.46)
}

enum ConnectionMotion {
    static let animation = Animation.timingCurve(0.22, 0.8, 0.32, 1, duration: 0.38)
    static let fade = Animation.timingCurve(0.25, 0.1, 0.25, 1, duration: 0.24)

    /// Evaluates the same cubic Bézier used by SwiftUI, for Canvas geometry.
    static func curve(_ value: Double, _ x1: Double = 0.22, _ y1: Double = 0.8,
                      _ x2: Double = 0.32, _ y2: Double = 1) -> Double {
        let x = min(1, max(0, value))
        if x == 0 || x == 1 { return x }
        func bezier(_ t: Double, _ a: Double, _ b: Double) -> Double {
            3 * (1 - t) * (1 - t) * t * a + 3 * (1 - t) * t * t * b + t * t * t
        }
        var lower = 0.0, upper = 1.0
        for _ in 0..<12 {
            let t = (lower + upper) / 2
            if bezier(t, x1, x2) < x { lower = t } else { upper = t }
        }
        return bezier((lower + upper) / 2, y1, y2)
    }

    static func pulse(_ time: Double, period: Double) -> Double {
        let cycle = time.truncatingRemainder(dividingBy: period) / period
        return curve(cycle < 0.5 ? cycle * 2 : (1 - cycle) * 2, 0.42, 0, 0.58, 1)
    }
}

/// One drawing surface for the tunnel; the two device cards remain native SwiftUI views.
struct ConnectionDiagram: View {
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.connectionReducedMotionPreview) private var previewReduceMotion
    private var reduceMotion: Bool { systemReduceMotion || previewReduceMotion }
    let frame: ConnectionJourneyFrame
    let date: Date

    private var progress: Double { ConnectionMotion.curve(frame.phaseProgress) }
    private var isFailure: Bool { frame.phase == .failed || frame.phase == .failing }
    private var tint: Color { isFailure ? ConnectionPalette.red : ConnectionPalette.blue }

    private var flightPresence: Double {
        switch frame.phase {
        case .flying: return ConnectionMotion.curve(frame.flightElapsed / 0.35)
        case .arriving: return 1 - ConnectionMotion.curve(frame.phaseProgress / 0.75)
        case .failing:
            return ConnectionMotion.curve(frame.flightElapsed / 0.35) * (1 - progress)
        default: return 0
        }
    }

    private var charge: Double {
        switch frame.phase {
        case .charging: return progress
        case .flying, .arriving, .connected: return 1
        default: return 0
        }
    }

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let width = min(158.0, size.width * 0.25)
            let inset = width / 2 + 24
            let centerY = size.height / 2
            let push = reduceMotion ? 0 : flightPresence
            let lift = reduceMotion ? 0 : cardLift

            ZStack {
                Canvas(opaque: false, rendersAsynchronously: true) { context, canvasSize in
                    drawConnection(in: &context, size: canvasSize, inset: inset, cardWidth: width)
                    if !reduceMotion && flightPresence > 0.001 {
                        drawTunnel(in: &context, size: canvasSize)
                    }
                }

                deviceCard(isServer: false, width: width)
                    .scaleEffect(1 + push * 0.22)
                    .opacity(1 - flightPresence * (reduceMotion ? 0.2 : 1))
                    .position(x: inset - push * size.width * 0.17, y: centerY + lift)

                deviceCard(isServer: true, width: width)
                    .scaleEffect(1 + push * 0.22)
                    .opacity(1 - flightPresence * (reduceMotion ? 0.2 : 1))
                    .position(x: size.width - inset + push * size.width * 0.17, y: centerY + lift)

                centerIndicator
                    .position(x: size.width / 2, y: centerY - 10)

                if frame.phase == .arriving && !reduceMotion {
                    Color.white.opacity(arrivalFlash)
                        .allowsHitTesting(false)
                }
            }
            .clipped()
        }
        .frame(height: 294)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("MacBook to server"))
        .accessibilityIdentifier("overview.connectionDiagram")
    }

    private var cardLift: Double {
        switch frame.phase {
        case .pressing: return -6 * progress
        case .charging, .flying: return -6
        case .arriving, .failing: return -6 * (1 - progress)
        default: return 0
        }
    }

    private var arrivalFlash: Double {
        let p = frame.phaseProgress
        return p < 0.18
            ? 0.85 * ConnectionMotion.curve(p / 0.18)
            : 0.85 * (1 - ConnectionMotion.curve((p - 0.18) / 0.4))
    }

    private func deviceCard(isServer: Bool, width: Double) -> some View {
        VStack(spacing: 19) {
            if isServer {
                serverIllustration
                    .frame(width: 72, height: 68)
            } else {
                laptopIllustration
                    .frame(width: 94, height: 68)
            }
            Text(isServer ? "Server" : "MacBook")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(ConnectionPalette.ink)
        }
        .frame(width: width, height: 170)
        .background {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(Color(red: 0.969, green: 0.976, blue: 0.987))
                .overlay {
                    RoundedRectangle(cornerRadius: 26, style: .continuous)
                        .strokeBorder(.white, lineWidth: 1.5)
                }
                .shadow(color: Color(red: 0.22, green: 0.32, blue: 0.5)
                    .opacity(frame.isConnecting ? 0.12 : 0.065),
                        radius: !reduceMotion && frame.isConnecting ? 20 : 14,
                        y: !reduceMotion && frame.isConnecting ? 12 : 8)
        }
    }

    private var laptopIllustration: some View {
        VStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 5)
                .fill(Color.white)
                .overlay {
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(ConnectionPalette.ink.opacity(0.75), lineWidth: 1.8)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(LinearGradient(colors: [Color(red: 0.90, green: 0.94, blue: 1), .white],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                        .padding(5)
                        .overlay {
                            Image(systemName: "terminal")
                                .font(.system(size: 17, weight: .light))
                                .foregroundStyle(ConnectionPalette.blue.opacity(0.7))
                        }
                }
                .frame(width: 77, height: 51)

            UnevenRoundedRectangle(bottomLeadingRadius: 5, bottomTrailingRadius: 5)
                .fill(Color(red: 0.79, green: 0.82, blue: 0.87))
                .overlay(alignment: .top) {
                    Capsule().fill(ConnectionPalette.ink.opacity(0.25)).frame(width: 20, height: 2)
                }
                .frame(height: 5)
        }
    }

    private var serverIllustration: some View {
        VStack(spacing: 4) {
            ForEach(0..<3) { index in
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 1).fill(ConnectionPalette.ink.opacity(0.3))
                        .frame(width: 20, height: 2)
                    Spacer(minLength: 0)
                    Circle().fill(ConnectionPalette.green.opacity(lightOpacity(index)))
                        .background(Circle().fill(ConnectionPalette.ink.opacity(0.14)))
                        .frame(width: 5, height: 5)
                }
                .padding(.horizontal, 9)
                .frame(height: 19)
                .background(.white, in: RoundedRectangle(cornerRadius: 4))
                .overlay {
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(ConnectionPalette.ink.opacity(0.66), lineWidth: 1.4)
                }
            }
        }
    }

    private func lightOpacity(_ index: Int) -> Double {
        if frame.phase == .connected { return 1 }
        guard frame.phase == .arriving else { return 0 }
        return ConnectionMotion.curve((frame.phaseProgress - 0.23 - Double(index) * 0.18) / 0.16)
    }

    private var centerIndicator: some View {
        let arrived = frame.phase == .connected || frame.phase == .arriving
        let visible = arrived ? (frame.phase == .connected ? 1 : ConnectionMotion.curve((frame.phaseProgress - 0.48) / 0.4))
            : (frame.phase == .charging ? 1 - progress : (frame.phase == .flying || frame.phase == .failing ? 0 : 1))
        let breath = reduceMotion ? 0 : ConnectionMotion.pulse(date.timeIntervalSinceReferenceDate, period: 2)
        let scale = reduceMotion ? 1 : (frame.phase == .charging ? 1 + progress * 0.7 : 1 + breath * 0.05)
        return Image(systemName: arrived ? "checkmark" : (isFailure ? "exclamationmark" : "ellipsis"))
            .font(.system(size: arrived ? 16 : 18, weight: .semibold))
            .foregroundStyle(arrived || isFailure ? tint : Color(red: 0.61, green: 0.65, blue: 0.72))
            .frame(width: 40, height: 40)
            .background(.white, in: Circle())
            .overlay { Circle().strokeBorder(tint.opacity(arrived || isFailure ? 0.2 : 0.07), lineWidth: 1) }
            .shadow(color: tint.opacity(arrived ? 0.12 : 0.035), radius: 10, y: 3)
            .scaleEffect(arrived || isFailure ? 1 : scale)
            .opacity(visible)
    }

    private func drawConnection(in context: inout GraphicsContext, size: CGSize, inset: Double, cardWidth: Double) {
        let y = size.height / 2 - 10
        let start = inset + cardWidth / 2 + 8
        let end = size.width - start
        let center = size.width / 2
        let visibility = 1 - flightPresence
        var line = Path()
        line.move(to: CGPoint(x: start, y: y))
        line.addLine(to: CGPoint(x: isFailure ? center - 22 : end, y: y))
        if isFailure {
            line.move(to: CGPoint(x: center + 22, y: y))
            line.addLine(to: CGPoint(x: end, y: y))
        }
        let cycle = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 8) / 8
        let drift = reduceMotion ? 0 : -12 * ConnectionMotion.curve(cycle, 0.42, 0, 0.58, 1)
        context.stroke(line, with: .color((isFailure ? ConnectionPalette.red : ConnectionPalette.ink)
            .opacity((isFailure ? 0.55 : 0.2) * visibility)),
                       style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [3, 9], dashPhase: drift))

        if charge > 0 {
            var pipe = Path()
            let halfWidth = (end - start) / 2 * (reduceMotion ? 1 : charge)
            let pipeVisibility = visibility * (reduceMotion ? charge : 1)
            pipe.move(to: CGPoint(x: center - halfWidth, y: y))
            pipe.addLine(to: CGPoint(x: center + halfWidth, y: y))
            context.stroke(pipe, with: .color(ConnectionPalette.blue.opacity(0.08 * pipeVisibility)),
                           style: StrokeStyle(lineWidth: 14, lineCap: .round))
            context.stroke(pipe, with: .color(ConnectionPalette.blue.opacity(0.16 * pipeVisibility)),
                           style: StrokeStyle(lineWidth: 6, lineCap: .round))
            context.stroke(pipe, with: .color(ConnectionPalette.blue.opacity(0.75 * pipeVisibility)),
                           style: StrokeStyle(lineWidth: 2, lineCap: .round))
        }
    }

    private func drawTunnel(in context: inout GraphicsContext, size: CGSize) {
        let center = CGPoint(x: size.width / 2, y: size.height / 2 - 10)
        let p = frame.phaseProgress
        let collapse = frame.phase == .arriving ? 1 - 0.96 * ConnectionMotion.curve(p / 0.55)
            : (frame.phase == .failing ? 1 - 0.92 * progress : 1)
        let flicker = frame.phase == .failing ? 0.32 + 0.68 * ConnectionMotion.pulse(p, period: 0.5) : 1
        context.opacity = flightPresence * flicker
        context.translateBy(x: center.x, y: center.y)
        context.scaleBy(x: collapse, y: collapse)
        let deceleration = frame.phase == .failing ? 0.2 * progress : 0
        let time = frame.flightElapsed + deceleration
        let distance = time < 0.55
            ? 0.68 * ConnectionMotion.curve(time / 0.55, 0.42, 0, 1, 1)
            : 0.68 + (time - 0.55) * 2.1

        for index in 0..<11 {
            let depth = (Double(index) / 11 + distance * 0.33).truncatingRemainder(dividingBy: 1)
            let expansion = 0.035 + ConnectionMotion.curve(depth, 0.55, 0, 1, 1) * 1.45
            let width = size.width * expansion
            let height = size.height * expansion * 1.18
            let ring = Path(roundedRect: CGRect(x: -width / 2, y: -height / 2, width: width, height: height),
                            cornerRadius: min(width, height) * 0.3)
            let alpha = 0.04 + 0.22 * ConnectionMotion.pulse(depth, period: 1)
            context.stroke(ring, with: .color(ConnectionPalette.blue.opacity(alpha)), lineWidth: 0.7 + depth * 0.5)
        }

        for index in 0..<68 {
            let seed = Double((index * 73 + 19) % 101) / 101
            let angle = Double(index) * 2.399963 + 0.24
            let depth = (seed + distance * (0.37 + seed * 0.16)).truncatingRemainder(dividingBy: 1)
            let radius = 0.025 + ConnectionMotion.curve(depth, 0.65, 0, 1, 1) * 1.3
            let tailRadius = max(0.018, radius - 0.025 - depth * depth * 0.16)
            let head = CGPoint(x: cos(angle) * size.width * 0.7 * radius,
                               y: sin(angle) * size.height * 0.9 * radius)
            let tail = CGPoint(x: cos(angle) * size.width * 0.7 * tailRadius,
                               y: sin(angle) * size.height * 0.9 * tailRadius)
            let alpha = min(1, depth * 5) * min(1, (1 - depth) * 5) * 0.57
            var streak = Path()
            streak.move(to: tail)
            streak.addLine(to: head)
            context.stroke(streak, with: .linearGradient(
                Gradient(colors: [ConnectionPalette.blue.opacity(0), ConnectionPalette.blue.opacity(alpha)]),
                startPoint: tail, endPoint: head), style: StrokeStyle(lineWidth: 0.8 + depth, lineCap: .round))
            let dotSize = 1.1 + depth * 1.8
            context.fill(Path(ellipseIn: CGRect(x: head.x - dotSize / 2, y: head.y - dotSize / 2,
                                                width: dotSize, height: dotSize)),
                         with: .color(ConnectionPalette.blue.opacity(alpha)))
            if index % 11 == 0 && depth > 0.24 && depth < 0.94 {
                let codes = ["0x3F", "IPMI", "192.168.x.x", "ACK", "0xA1", "BMC", "SYN"]
                let text = Text(verbatim: codes[index / 11])
                    .font(.system(size: 8 + depth * 5, weight: .medium, design: .monospaced))
                    .foregroundColor(ConnectionPalette.blue.opacity(alpha * 0.8))
                context.draw(text, at: CGPoint(x: head.x + 5, y: head.y - 8), anchor: .leading)
            }
        }
    }
}
