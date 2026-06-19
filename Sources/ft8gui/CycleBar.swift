import SwiftUI
import FT8808Engine

/// Even/odd slot colours, matching the TUI (xterm 33 blue / 208 orange).
enum SlotColors {
    static let even = Color(red: 0x00 / 255, green: 0x87 / 255, blue: 0xFF / 255)  // :00/:30
    static let odd  = Color(red: 0xFF / 255, green: 0x87 / 255, blue: 0x00 / 255)  // :15/:45
}

/// A thin progress bar tracking position in the current 15 s slot — green on RX,
/// red while transmitting — with the current slot parity and (when armed) the TX
/// parity. Mirrors the TUI's cycle bar.
struct CycleBar: View {
    @ObservedObject var model: WaterfallModel

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { tl in
            let sec = tl.date.timeIntervalSince1970.truncatingRemainder(dividingBy: SlotClock.slotSeconds)
            let frac = sec / SlotClock.slotSeconds
            let parity = SlotClock.parity(at: tl.date)
            let txing = model.transmitting

            HStack(spacing: 8) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.secondary.opacity(0.18))
                        Capsule()
                            .fill(txing ? Color.red : Color.green)
                            .frame(width: max(0, geo.size.width * frac))
                    }
                }
                .frame(height: 6)

                Text(String(format: "%4.1fs", sec))
                    .foregroundStyle(.secondary)
                Text(parity == .even ? "EVEN" : "ODD")
                    .foregroundStyle(parity == .even ? SlotColors.even : SlotColors.odd)
                if model.txEnabled {
                    Text("TX \(model.txParity == .even ? "EVEN" : "ODD")")
                        .foregroundStyle(.red)
                }
            }
            .font(.system(size: 10, weight: .bold, design: .monospaced))
        }
        .frame(height: 14)
    }
}
