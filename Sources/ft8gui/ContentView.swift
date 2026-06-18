import SwiftUI

struct ContentView: View {
    @StateObject private var model = WaterfallModel()

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            HStack(spacing: 0) {
                waterfall
                Divider()
                decodeList
                    .frame(width: 280)
            }
            Divider()
            MeterDeck(model: model)
        }
        .frame(minWidth: 900, minHeight: 640)
    }

    // MARK: Controls

    private var controls: some View {
        HStack(spacing: 14) {
            Picker("Input", selection: $model.selectedUID) {
                ForEach(model.devices) { dev in
                    Text(dev.likelyRig ? "📻 \(dev.name)" : dev.name)
                        .tag(Optional(dev.uid))
                }
            }
            .frame(maxWidth: 260)
            .disabled(model.isRunning)

            Picker("", selection: $model.mode) {
                Text("3D").tag(WaterfallMode.threeD)
                Text("2D").tag(WaterfallMode.twoD)
            }
            .pickerStyle(.segmented)
            .frame(width: 96)

            Button(model.isRunning ? "Stop" : "Start") { model.toggle() }
                .keyboardShortcut(.defaultAction)

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(model.status)
                    .font(.caption)
                    .foregroundStyle(model.isRunning ? .green : .secondary)
                if model.isRunning {
                    Text(String(format: "%.0f rows/s · %d decodes", model.frameRate, model.decodes.count))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    // MARK: Waterfall + overlay

    private var waterfall: some View {
        // Decode tags are drawn inside the Metal pass (see WaterfallRenderer),
        // so they stay frame-locked to the scrolling waterfall.
        MetalWaterfallView(renderer: model.renderer)
            .background(Color.black)
    }

    // MARK: Decode list

    private var decodeList: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Decodes").font(.headline)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(model.decodes) { d in
                        decodeRow(d)
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private func decodeRow(_ d: Decode) -> some View {
        HStack(spacing: 8) {
            Text(String(format: "%+03d", Int(d.snr.rounded())))
                .foregroundStyle(snrColor(d.snr))
                .frame(width: 30, alignment: .trailing)
            Text(String(format: "%4d", Int(d.freq.rounded())))
                .foregroundStyle(.secondary)
                .frame(width: 38, alignment: .trailing)
            Text(d.text)
                .foregroundStyle(d.isCQ ? .yellow : .primary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .font(.system(size: 11, design: .monospaced))
        .padding(.horizontal, 10)
        .padding(.vertical, 1)
    }

    private func snrColor(_ snr: Float) -> Color {
        switch snr {
        case 0...:      return .green
        case -12..<0:   return .primary
        default:        return .orange
        }
    }
}
