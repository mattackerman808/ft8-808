import SwiftUI
import FT8808Engine

/// The bottom "control deck": station readout (VFO, mode, PTT lamp) plus the
/// three analog meters. A single TimelineView clock drives every needle's
/// damper so they move in lockstep.
struct MeterDeck: View {
    @ObservedObject var model: WaterfallModel

    @State private var pwr = NeedleDamper()
    @State private var swr = NeedleDamper()
    @State private var alc = NeedleDamper()

    var body: some View {
        TimelineView(.animation) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            let target = model.meterTargets(testTime: t)
            let glow = model.transmitting ? 1.0 : (model.meterTest ? 0.65 : 0.32)

            HStack(spacing: 18) {
                stationReadout
                Spacer(minLength: 8)
                VUMeter(title: "PWR  W", value: pwr.step(target.0, t),
                        labels: ["0", "25", "50", "75", "100"], dangerFrom: 1.0, glow: glow)
                VUMeter(title: "SWR", value: swr.step(target.1, t),
                        labels: ["1", "1.5", "2", "3", "∞"], dangerFrom: 0.5, glow: glow)
                VUMeter(title: "ALC", value: alc.step(target.2, t),
                        labels: ["0", "", "MAX"], dangerFrom: 0.66, glow: glow)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(height: 150)
            .background(deckBackground)
        }
    }

    private var stationReadout: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle()
                    .fill(model.transmitting ? Color.red : (model.rigState.connected ? Color.green : Color.gray))
                    .frame(width: 9, height: 9)
                    .shadow(color: model.transmitting ? .red : .clear, radius: 6)
                Text(model.transmitting ? "TX" : (model.rigState.connected ? "RX" : "—"))
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(model.transmitting ? .red : .secondary)
            }
            Text(freqText)
                .font(.system(size: 26, weight: .semibold, design: .monospaced))
                .foregroundStyle(.primary)
            Text(modeText)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
            Toggle("Test", isOn: $model.meterTest)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .font(.caption2)
        }
        .frame(width: 160, alignment: .leading)
    }

    private var freqText: String {
        let mhz = Double(model.rigState.frequencyHz) / 1_000_000
        return model.rigState.connected ? String(format: "%.3f", mhz) : "––.–––"
    }

    private var modeText: String {
        model.rigState.connected ? "\(model.rigState.mode)".uppercased() : "MHz"
    }

    private var deckBackground: some View {
        LinearGradient(colors: [Color(white: 0.12), Color(white: 0.06)],
                       startPoint: .top, endPoint: .bottom)
            .overlay(Rectangle().frame(height: 1).foregroundStyle(Color.white.opacity(0.06)),
                     alignment: .top)
    }
}
