import SwiftUI

/// Tuner controls: key a steady carrier (Tune), adjust drive, or run Auto to
/// find the power knee. This transmits — the gauges in the top bar show the
/// power / SWR / ALC response live.
struct TunerView: View {
    @ObservedObject var model: WaterfallModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Tuner").font(.headline)

            if !model.rigState.connected {
                Text("No rig connected — set it up in Settings.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                Button(model.tuning ? "Stop" : "Tune") { model.toggleTune() }
                    .keyboardShortcut(.return)
                    .disabled(model.autoTuning || !model.rigState.connected)
                Button(model.autoTuning ? "Auto…" : "Auto") { Task { await model.autoTune() } }
                    .disabled(model.autoTuning || !model.rigState.connected)
                if model.tuning {
                    Label("ON AIR", systemImage: "dot.radiowaves.left.and.right")
                        .font(.caption.bold()).foregroundStyle(.red)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Drive").font(.caption)
                    Spacer()
                    Text(String(format: "%+.0f dBFS", model.txLevelDb))
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Slider(value: Binding(get: { Double(model.txLevelDb) },
                                      set: { model.setDrive(Float($0)) }),
                       in: -60...0, step: 1,
                       onEditingChanged: { editing in if !editing { model.commitDrive() } })
                    .disabled(model.autoTuning)
            }

            Text(model.status)
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            Label("Keys the transmitter — make sure you're on a clear frequency or a dummy load.",
                  systemImage: "exclamationmark.triangle")
                .font(.caption2).foregroundStyle(.orange)
        }
        .padding(16)
        .frame(width: 320)
    }
}
