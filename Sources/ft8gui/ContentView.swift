import SwiftUI
import AppKit

struct ContentView: View {
    @StateObject private var model = WaterfallModel()
    @State private var showSettings = false
    @State private var showTuner = false

    // Manual, persisted waterfall height — VSplitView won't honor a default
    // split, so we size the waterfall ourselves and let the bottom fill the rest.
    @AppStorage("waterfallHeight") private var waterfallHeight: Double = 320
    @State private var dragStartHeight: Double?

    var body: some View {
        VStack(spacing: 0) {
            topBar                           // status + controls + gauges
            Divider()
            if model.waterfallEnabled {
                GeometryReader { geo in
                    VStack(spacing: 0) {
                        waterfallPane
                            .frame(height: clampWaterfall(waterfallHeight, total: geo.size.height))
                        waterfallResizeBar(total: geo.size.height)
                        bottomPanels
                            .frame(maxHeight: .infinity)
                    }
                }
            } else {
                bottomPanels
            }
        }
        .frame(minWidth: 1040, minHeight: 680)
    }

    /// Keep the waterfall between 200 pt and (total − room for the bottom panels).
    private func clampWaterfall(_ value: Double, total: CGFloat) -> CGFloat {
        let maxH = max(200, total - 360)
        return min(max(200, value), maxH)
    }

    /// A thin draggable divider that resizes the waterfall vs. the bottom panels.
    private func waterfallResizeBar(total: CGFloat) -> some View {
        Divider()
            .frame(height: 6)
            .contentShape(Rectangle())
            .onHover { $0 ? NSCursor.resizeUpDown.set() : NSCursor.arrow.set() }
            .gesture(
                DragGesture()
                    .onChanged { v in
                        let base = dragStartHeight ?? Double(clampWaterfall(waterfallHeight, total: total))
                        if dragStartHeight == nil { dragStartHeight = base }
                        waterfallHeight = Double(clampWaterfall(base + Double(v.translation.height), total: total))
                    }
                    .onEnded { _ in dragStartHeight = nil }
            )
    }

    // Bottom row: passband ↔ QSO, horizontally resizable.
    private var bottomPanels: some View {
        GeometryReader { geo in
            let half = max(0, (geo.size.width - 1) / 2)   // -1 for the divider
            HStack(spacing: 0) {
                passband.frame(width: half)
                Divider()
                qsoColumn.frame(width: half)
            }
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

            Spacer()

            // Master transmit enable — centered, prominent, glows red when armed.
            Toggle(isOn: txEnabledBinding) {
                Text("Enable TX").font(.system(size: 12, weight: .semibold))
            }
            .toggleStyle(.switch)
            .tint(.green)
            .disabled(model.myCall.isEmpty)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8)
                .fill(model.txEnabled ? Color.red.opacity(0.22) : Color.primary.opacity(0.06)))
            .help("Master transmit enable")

            Spacer()

            VFOControl(model: model)
            MeterStrip(model: model)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .frame(height: 92)
    }

    private var displayBinding: Binding<Int> {
        Binding(get: { model.displayModeRaw }, set: { model.setDisplayMode($0) })
    }

    /// Flips the master TX toggle; `enableTX()` arms or disarms by current state.
    private var txEnabledBinding: Binding<Bool> {
        Binding(get: { model.txEnabled }, set: { _ in Task { await model.enableTX() } })
    }

    // MARK: Bottom-left — passband (entire band, optional CQ-only)

    private var passband: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Passband").font(.headline)
                if model.isRunning {
                    Text(String(format: "%.0f rows/s · %d decodes", model.frameRate, model.decodes.count))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
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
                           myCall: model.myCall,
                           worked: model.workedCalls,
                           onSelect: { model.select($0) })
        }
    }

    // MARK: Bottom-right — RX-frequency window (top, fills) + QSO/sequencer

    private var qsoColumn: some View {
        VStack(spacing: 0) {
            RxTxBar(model: model)              // TOP: RX/TX freq + 15 s cycle timer
            Divider()
            HStack {
                Text("RX Frequency").font(.headline)
                Spacer()
                Text("±80 Hz")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            Divider()
            DecodeListView(title: "",
                           decodes: model.rxDecodes,
                           selectedID: model.selectedID,
                           myCall: model.myCall,
                           worked: model.workedCalls,
                           onSelect: { model.select($0) })
                .frame(maxHeight: .infinity)   // the window list gets the room
            Divider()
            QSOPanel(model: model)             // MIDDLE controls + BOTTOM sequencer
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
