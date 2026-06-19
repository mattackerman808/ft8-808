import SwiftUI
import AppKit

/// The VFO display plus tuning controls: a band selector that loads the standard
/// FT8 dial frequency, and up/down steppers (auto-repeat on hold) that nudge the
/// rig's VFO by 1 kHz. All disabled with no rig, or while transmitting.
struct VFOControl: View {
    @ObservedObject var model: WaterfallModel

    private var canTune: Bool { model.rigState.connected && !model.sending }

    var body: some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(FT8Bands.all) { band in
                    Button {
                        model.tuneToBand(band)
                    } label: {
                        Text("\(band.name)\u{2003}\(band.dialMHz) MHz")
                    }
                }
            } label: {
                HStack(spacing: 3) {
                    Text(model.currentBand?.name ?? "Band")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                    Image(systemName: "chevron.down").font(.system(size: 7, weight: .bold))
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(!canTune)
            .help("Jump to a band's FT8 dial frequency")

            VFODisplay(model: model)

            Stepper("",
                    onIncrement: { model.nudgeFrequency(1_000) },
                    onDecrement: { model.nudgeFrequency(-1_000) })
                .labelsHidden()
                .disabled(!canTune)
                .help("Tune the VFO ±1 kHz")
        }
    }
}

/// Captures scroll-wheel events over the VFO digits and tunes: scroll over the
/// MHz / kHz / Hz portion of the readout to step that place. A mouse wheel steps
/// once per notch; trackpad scrolling accumulates for a smooth rate. Scroll up =
/// tune up.
struct ScrollTuneCatcher: NSViewRepresentable {
    let onTune: (Int) -> Void

    func makeNSView(context: Context) -> CatcherView {
        let v = CatcherView(); v.onTune = onTune; return v
    }
    func updateNSView(_ v: CatcherView, context: Context) { v.onTune = onTune }

    final class CatcherView: NSView {
        var onTune: ((Int) -> Void)?
        private var accum: CGFloat = 0

        override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeUpDown) }

        /// Step size by horizontal position over the readout: MHz | kHz | 100 Hz.
        private func step(at locationInWindow: NSPoint) -> Int {
            let x = convert(locationInWindow, from: nil).x
            let frac = bounds.width > 0 ? x / bounds.width : 0.5
            switch frac {
            case ..<0.30: return 1_000_000   // MHz group (left)
            case ..<0.66: return 1_000       // kHz group (middle)
            default:      return 100         // Hz group (right)
            }
        }

        override func scrollWheel(with event: NSEvent) {
            let mag = step(at: event.locationInWindow)
            if event.hasPreciseScrollingDeltas {   // trackpad
                accum += event.scrollingDeltaY
                let threshold: CGFloat = 6
                while abs(accum) >= threshold {
                    let dir = accum > 0 ? 1 : -1
                    accum -= CGFloat(dir) * threshold
                    onTune?(dir * mag)
                }
            } else {                                // mouse wheel: one step per notch
                let dir = event.scrollingDeltaY > 0 ? 1 : (event.scrollingDeltaY < 0 ? -1 : 0)
                if dir != 0 { onTune?(dir * mag) }
            }
        }
    }
}
