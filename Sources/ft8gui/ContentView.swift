import SwiftUI

struct ContentView: View {
    @StateObject private var model = WaterfallModel()
    @State private var showSettings = false
    @State private var showTuner = false

    var body: some View {
        VStack(spacing: 0) {
            topBar                           // status + controls + gauges
            Divider()
            if model.waterfallEnabled {
                VSplitView {
                    waterfallPane
                        .frame(minHeight: 180)
                    bottomPanels
                        .frame(minHeight: 160, idealHeight: 320)
                }
            } else {
                bottomPanels
            }
        }
        .frame(minWidth: 1040, minHeight: 680)
    }

    // Bottom row: passband ↔ QSO, horizontally resizable.
    private var bottomPanels: some View {
        HSplitView {
            passband
                .frame(minWidth: 320)
            qsoColumn
                .frame(minWidth: 340, idealWidth: 380)
        }
    }

    // MARK: Top bar — display, controls, status, gauges

    private var topBar: some View {
        HStack(spacing: 12) {
            Picker("", selection: displayBinding) {
                Text("Off").tag(0)
                Text("2D").tag(1)
                Text("3D").tag(2)
            }
            .pickerStyle(.segmented)
            .frame(width: 132)
            .help("Waterfall display")

            Button { showTuner.toggle() } label: {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .foregroundStyle(model.tuning ? .red : .primary)
            }
            .popover(isPresented: $showTuner, arrowEdge: .bottom) { TunerView(model: model) }
            .help("Tuner")

            Button { showSettings = true } label: { Image(systemName: "gearshape") }
                .help("Settings")
                .sheet(isPresented: $showSettings) {
                    SettingsView(model: model, isPresented: $showSettings)
                }

            if model.isRunning {
                Text(String(format: "%.0f rows/s\n%d decodes", model.frameRate, model.decodes.count))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            VFODisplay(model: model)
            MeterStrip(model: model)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .frame(height: 92)
    }

    private var displayBinding: Binding<Int> {
        Binding(get: { model.displayModeRaw }, set: { model.setDisplayMode($0) })
    }

    // MARK: Bottom-left — passband (entire band, optional CQ-only)

    private var passband: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Passband").font(.headline)
                Spacer()
                Toggle(isOn: $model.cqOnly) {
                    Text("CQ").font(.system(size: 11, weight: .bold, design: .monospaced))
                }
                .toggleStyle(.button)
                .controlSize(.small)
                .help("Show only CQ calls")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            Divider()
            DecodeListView(title: "",
                           decodes: model.passbandDecodes,
                           selectedID: model.selectedID,
                           onSelect: { model.select($0) })
        }
    }

    // MARK: Bottom-right — RX-frequency window (top, fills) + QSO/sequencer

    private var qsoColumn: some View {
        VStack(spacing: 0) {
            HStack {
                Text("RX Frequency").font(.headline)
                Spacer()
                Text("\(Int(model.txOffsetHz)) Hz ±80")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            Divider()
            DecodeListView(title: "",
                           decodes: model.rxDecodes,
                           selectedID: model.selectedID,
                           onSelect: { model.select($0) })
                .frame(maxHeight: .infinity)   // the window list gets the room
            Divider()
            QSOPanel(model: model)             // sequencer below (≈6 lines)
        }
    }

    // MARK: Waterfall pane (waterfall + tuning bar)

    private var waterfallPane: some View {
        VStack(spacing: 0) {
            waterfall
            TuningBar(model: model)
        }
    }

    private var waterfall: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                MetalWaterfallView(renderer: model.renderer)
                    .background(Color.black)

                // 2D: vertical marker line straight above the tuning-bar flag.
                // (3D: the marker is drawn in Metal on the surface.)
                if model.mode == .twoD {
                    Rectangle()
                        .fill(Color.pink.opacity(0.85))
                        .frame(width: 2)
                        .frame(maxHeight: .infinity)
                        .position(x: txX(geo.size.width), y: geo.size.height / 2)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onEnded { v in
                        guard geo.size.width > 0 else { return }
                        let frac: Float?
                        if model.mode == .twoD {
                            frac = Float(v.location.x / geo.size.width)
                        } else {
                            // 3D: cast the click ray onto the surface ground plane.
                            frac = model.renderer.freqFraction(atViewPoint: v.location, viewSize: geo.size)
                        }
                        guard let frac else { return }
                        model.setTxOffset(model.fMin + frac * (model.fMax - model.fMin))
                    }
            )
        }
    }

    private func txX(_ width: CGFloat) -> CGFloat {
        let span = model.fMax - model.fMin
        guard span > 0 else { return 0 }
        return CGFloat((model.txOffsetHz - model.fMin) / span) * width
    }
}
