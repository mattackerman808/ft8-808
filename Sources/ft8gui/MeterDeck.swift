import SwiftUI
import FT8808Engine

/// The three analog gauges, compact, for the top status bar. One TimelineView
/// clock drives every needle's damper so they move in lockstep.
struct MeterStrip: View {
    @ObservedObject var model: WaterfallModel

    @State private var pwr = NeedleDamper()
    @State private var swr = NeedleDamper()
    @State private var alc = NeedleDamper()

    var body: some View {
        TimelineView(.animation) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            let target = model.meterTargets(testTime: t)
            let glow = model.transmitting ? 1.0 : (model.meterTest ? 0.65 : 0.32)

            HStack(spacing: 6) {
                VUMeter(title: "PWR W", value: pwr.step(target.0, t),
                        labels: ["0", "25", "50", "75", "100"], dangerFrom: 1.0, glow: glow)
                VUMeter(title: "SWR", value: swr.step(target.1, t),
                        labels: ["1", "1.5", "2", "3", "∞"], dangerFrom: 0.5, glow: glow)
                VUMeter(title: "ALC", value: alc.step(target.2, t),
                        labels: ["0", "", "MAX"], dangerFrom: 0.66, glow: glow)
            }
        }
    }
}

/// A radio-style VFO display: large seven-segment-ish amber digits on a dark
/// LCD panel (with a dim "off-segment" 8.888 backdrop and glow), plus a mode +
/// RX/TX lamp. Turns red on transmit.
struct VFODisplay: View {
    @ObservedObject var model: WaterfallModel

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Circle()
                        .fill(lamp)
                        .frame(width: 8, height: 8)
                        .shadow(color: model.transmitting ? .red : .clear, radius: 5)
                    Text(model.transmitting ? "TX" : "RX")
                        .foregroundStyle(model.transmitting ? .red : .secondary)
                }
                Text(modeText).foregroundStyle(.secondary)
            }
            .font(.system(size: 10, weight: .bold, design: .monospaced))

            ZStack(alignment: .trailing) {
                Text("88.888.888").foregroundStyle(digit.opacity(0.10))   // dim off-segments
                Text(freqText)
                    .foregroundStyle(digit)
                    .shadow(color: digit.opacity(0.55), radius: 5)
            }
            .font(.system(size: 28, weight: .bold, design: .monospaced))
            // Scroll over the digits to tune (MHz / kHz / 100 Hz by position).
            .overlay(ScrollTuneCatcher { model.nudgeFrequency($0) })

            Text("MHz")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(LinearGradient(colors: [Color(white: 0.07), Color(white: 0.02)],
                                     startPoint: .top, endPoint: .bottom))
                .overlay(RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
        )
    }

    private var lamp: Color {
        model.transmitting ? .red : (model.rigState.connected ? .green : .gray)
    }

    private var digit: Color {
        model.transmitting ? Color(red: 1.0, green: 0.30, blue: 0.20)
                           : Color(red: 1.0, green: 0.72, blue: 0.18)
    }

    private var freqText: String {
        guard model.rigState.connected else { return "––.–––.–––" }
        let hz = model.rigState.frequencyHz
        return String(format: "%d.%03d.%03d", hz / 1_000_000, (hz / 1000) % 1000, hz % 1000)
    }

    private var modeText: String {
        model.rigState.connected ? "\(model.rigState.mode)".uppercased() : "—"
    }
}
