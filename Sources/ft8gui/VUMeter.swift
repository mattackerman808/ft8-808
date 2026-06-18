import SwiftUI

/// Critically-damped follower that gives the needle analog inertia. Driven from
/// a single `TimelineView` clock in the deck; `step` is called once per frame
/// with the current target and time, and returns the smoothed value.
final class NeedleDamper {
    private var displayed = 0.0
    private var last = 0.0
    private var overshoot = 0.0

    func step(_ target: Double, _ time: Double) -> Double {
        let dt = last == 0 ? 0 : min(0.05, time - last)
        last = time
        // Spring-damper toward target with a touch of overshoot for realism.
        let stiffness = 60.0, damping = 11.0
        let force = (target - displayed) * stiffness - overshoot * damping
        overshoot += force * dt
        displayed += overshoot * dt
        return displayed
    }
}

/// An old-school analog panel meter: warm back-glow, cream face, arced scale,
/// danger zone, and a swinging needle. Pure drawing — `value` is the already
/// damped fraction in 0...1; the deck owns the animation clock.
struct VUMeter: View {
    let title: String
    let value: Double            // 0...1 needle position
    let labels: [String]         // tick labels, left → right
    var dangerFrom: Double = 1.0 // fraction where the red zone starts
    var glow: Double = 0.4       // back-glow intensity 0...1

    private let sweep = 52.0 * .pi / 180.0   // half-span from vertical

    var body: some View {
        Canvas { ctx, size in
            let rect = CGRect(origin: .zero, size: size)
            draw(ctx, rect)
        }
        .aspectRatio(1.25, contentMode: .fit)
    }

    private func angle(_ frac: Double) -> Double { -sweep + frac * 2 * sweep }

    private func draw(_ ctx: GraphicsContext, _ rect: CGRect) {
        let pivot = CGPoint(x: rect.midX, y: rect.maxY - rect.height * 0.16)
        let radius = min(rect.height * 0.92, (rect.width * 0.5 - 6) / sin(sweep))

        func pt(_ a: Double, _ r: Double) -> CGPoint {
            CGPoint(x: pivot.x + r * sin(a), y: pivot.y - r * cos(a))
        }
        func arc(_ f0: Double, _ f1: Double, _ r: Double) -> Path {
            var p = Path()
            let steps = 40
            for i in 0...steps {
                let f = f0 + (f1 - f0) * Double(i) / Double(steps)
                let q = pt(angle(f), r)
                if i == 0 { p.move(to: q) } else { p.addLine(to: q) }
            }
            return p
        }

        let face = RoundedRectangle(cornerRadius: rect.width * 0.06).path(in: rect)

        // Warm incandescent back-glow.
        let amber = Color(red: 1.0, green: 0.62, blue: 0.22)
        ctx.fill(face, with: .radialGradient(
            Gradient(colors: [amber.opacity(0.10 + 0.55 * glow), amber.opacity(0.0)]),
            center: CGPoint(x: pivot.x, y: pivot.y - radius * 0.45),
            startRadius: 2, endRadius: radius * 1.25))

        // Cream face with a subtle vertical warm gradient.
        ctx.fill(face, with: .linearGradient(
            Gradient(colors: [Color(red: 0.97, green: 0.93, blue: 0.82),
                              Color(red: 0.93, green: 0.85, blue: 0.68)]),
            startPoint: CGPoint(x: rect.midX, y: rect.minY),
            endPoint: CGPoint(x: rect.midX, y: rect.maxY)))

        let scaleR = radius
        // Danger zone (red) and, when present, a safe band (green) below it.
        if dangerFrom < 1.0 {
            ctx.stroke(arc(0, dangerFrom, scaleR),
                       with: .color(Color(red: 0.15, green: 0.5, blue: 0.2).opacity(0.85)),
                       style: StrokeStyle(lineWidth: rect.height * 0.05, lineCap: .butt))
        }
        ctx.stroke(arc(dangerFrom, 1, scaleR),
                   with: .color(Color(red: 0.82, green: 0.12, blue: 0.07)),
                   style: StrokeStyle(lineWidth: rect.height * 0.05, lineCap: .butt))

        // Thin scale arc.
        ctx.stroke(arc(0, 1, scaleR), with: .color(Color(red: 0.2, green: 0.14, blue: 0.06)),
                   style: StrokeStyle(lineWidth: 1.2))

        // Ticks + labels.
        let n = labels.count
        for (i, label) in labels.enumerated() {
            let f = n > 1 ? Double(i) / Double(n - 1) : 0
            let a = angle(f)
            var tick = Path()
            tick.move(to: pt(a, scaleR))
            tick.addLine(to: pt(a, scaleR - rect.height * 0.10))
            ctx.stroke(tick, with: .color(Color(red: 0.2, green: 0.14, blue: 0.06)), lineWidth: 1.6)
            if !label.isEmpty {
                var t = ctx.resolve(Text(label)
                    .font(.system(size: rect.height * 0.085, weight: .semibold, design: .rounded)))
                t.shading = .color(Color(red: 0.22, green: 0.15, blue: 0.07))
                ctx.draw(t, at: pt(a, scaleR - rect.height * 0.20))
            }
        }

        // Needle: dark body with a red tip, plus a counterweight tail and hub.
        let na = angle(min(max(value, 0), 1))
        let tip = pt(na, scaleR - rect.height * 0.02)
        let tail = pt(na + .pi, radius * 0.12)
        var needle = Path()
        needle.move(to: tail)
        needle.addLine(to: tip)
        ctx.stroke(needle, with: .color(Color(red: 0.12, green: 0.10, blue: 0.10)),
                   style: StrokeStyle(lineWidth: rect.height * 0.018, lineCap: .round))
        var tipP = Path()
        tipP.move(to: pt(na, scaleR - rect.height * 0.18))
        tipP.addLine(to: tip)
        ctx.stroke(tipP, with: .color(Color(red: 0.85, green: 0.12, blue: 0.06)),
                   style: StrokeStyle(lineWidth: rect.height * 0.022, lineCap: .round))

        let hubR = rect.height * 0.05
        let hub = Path(ellipseIn: CGRect(x: pivot.x - hubR, y: pivot.y - hubR,
                                         width: hubR * 2, height: hubR * 2))
        ctx.fill(hub, with: .radialGradient(
            Gradient(colors: [Color(white: 0.35), Color(white: 0.05)]),
            center: CGPoint(x: pivot.x - hubR * 0.3, y: pivot.y - hubR * 0.3),
            startRadius: 0, endRadius: hubR * 1.4))

        // Glass highlight + bezel.
        ctx.fill(face, with: .linearGradient(
            Gradient(colors: [Color.white.opacity(0.18), Color.white.opacity(0.0)]),
            startPoint: CGPoint(x: rect.minX, y: rect.minY),
            endPoint: CGPoint(x: rect.midX, y: rect.midY)))
        ctx.stroke(face, with: .color(Color(white: 0.05)), lineWidth: rect.width * 0.02)

        // Title.
        var titleText = ctx.resolve(Text(title)
            .font(.system(size: rect.height * 0.10, weight: .bold, design: .rounded)))
        titleText.shading = .color(Color(red: 0.22, green: 0.15, blue: 0.07))
        ctx.draw(titleText, at: CGPoint(x: rect.midX, y: pivot.y + rect.height * 0.08))
    }
}
