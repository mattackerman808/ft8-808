import SwiftUI

/// A frequency ruler under the waterfall with a draggable TX/RX flag. Click or
/// drag anywhere to set the frequency; the flag (and the waterfall marker above
/// it) follow. Frequency is linear across the passband, so the flag lines up
/// with the 2D waterfall's vertical marker directly above it.
struct TuningBar: View {
    @ObservedObject var model: WaterfallModel

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let span = model.fMax - model.fMin
            Canvas { ctx, size in
                guard span > 0 else { return }

                // 500 Hz ticks + labels (perspective-warped in 3D so they line
                // up with the surface).
                var f = (model.fMin / 500).rounded(.up) * 500
                while f <= model.fMax {
                    if let x = screenX(forFreq: f, width: size.width, span: span),
                       x >= 0, x <= size.width {
                        var tick = Path()
                        tick.move(to: CGPoint(x: x, y: 0))
                        tick.addLine(to: CGPoint(x: x, y: 5))
                        ctx.stroke(tick, with: .color(.secondary.opacity(0.6)), lineWidth: 1)
                        var lbl = ctx.resolve(Text("\(Int(f))")
                            .font(.system(size: 8, design: .monospaced)))
                        lbl.shading = .color(.secondary)
                        ctx.draw(lbl, at: CGPoint(x: x, y: size.height - 6))
                    }
                    f += 500
                }

                // The flag: downward triangle at the TX/RX frequency + label.
                let fx = screenX(forFreq: model.txOffsetHz, width: size.width, span: span)
                    ?? CGFloat((model.txOffsetHz - model.fMin) / span) * size.width
                var tri = Path()
                tri.move(to: CGPoint(x: fx, y: 1))
                tri.addLine(to: CGPoint(x: fx - 6, y: 11))
                tri.addLine(to: CGPoint(x: fx + 6, y: 11))
                tri.closeSubpath()
                ctx.fill(tri, with: .color(.pink))
                var flag = ctx.resolve(Text("\(Int(model.txOffsetHz))")
                    .font(.system(size: 9, weight: .bold, design: .monospaced)))
                flag.shading = .color(.pink)
                let lx = min(max(fx, 18), size.width - 18)
                ctx.draw(flag, at: CGPoint(x: lx, y: 17))
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in setFreq(v.location.x, w, span, persist: false) }
                    .onEnded   { v in setFreq(v.location.x, w, span, persist: true) }
            )
        }
        .frame(height: 26)
        .background(Color(white: 0.09))
    }

    /// Frequency → bar X. Linear in 2D; in 3D it matches the surface front-edge
    /// projection so the flag sits under the 3D marker.
    private func screenX(forFreq f: Float, width w: CGFloat, span: Float) -> CGFloat? {
        let gx = (f - model.fMin) / span
        if model.mode == .threeD {
            return model.renderer.frontEdgeViewX(fraction: gx, viewWidth: w)
        }
        return CGFloat(gx) * w
    }

    private func setFreq(_ x: CGFloat, _ w: CGFloat, _ span: Float, persist: Bool) {
        guard w > 0 else { return }
        let cx = min(max(x, 0), w)
        let frac: Float = model.mode == .threeD
            ? model.renderer.fractionForFrontEdgeViewX(cx, viewWidth: w)
            : Float(cx / w)
        model.setTxOffset(model.fMin + frac * span, persist: persist)
    }
}
