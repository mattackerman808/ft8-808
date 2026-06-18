import SwiftUI
import FT8808Engine
import HamlibRig

/// Station settings, mirroring the TUI's settings panel: call/grid, rig + CAT
/// serial, audio devices, protocol, and LoTW. Saves to config.json and reconnects
/// the rig if its spec changed.
struct SettingsView: View {
    @ObservedObject var model: WaterfallModel
    @Binding var isPresented: Bool

    @State private var call: String
    @State private var grid: String
    @State private var rigModel: Int          // 0 = none
    @State private var serial: String         // "none" or path
    @State private var baud: String
    @State private var audioIn: String        // "default" or name
    @State private var audioOut: String
    @State private var proto: String
    @State private var cqDirective: String
    @State private var lotwEnabled: Bool
    @State private var lotwLoc: String
    @State private var tqslPath: String
    @State private var pickingRig = false

    private let serialPorts = SerialPorts.list()
    private let inputs = AudioDevices.inputDevices()
    private let outputs = AudioDevices.outputDevices()
    private let lotwLocs: [String]
    private let bauds = ["4800", "9600", "19200", "38400", "57600", "115200"]

    init(model: WaterfallModel, isPresented: Binding<Bool>) {
        self.model = model
        _isPresented = isPresented
        let c = model.currentConfig
        let parts = (c.rigSpec ?? "").split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        let rigTok = parts.first ?? ""
        let modelNum = Int(rigTok) ?? RigSpec.aliases[rigTok.lowercased()] ?? 0
        _call = State(initialValue: c.callsign)
        _grid = State(initialValue: c.grid)
        _rigModel = State(initialValue: modelNum)
        _serial = State(initialValue: parts.count > 1 && !parts[1].isEmpty ? parts[1] : "none")
        _baud = State(initialValue: parts.count > 2 && !parts[2].isEmpty ? parts[2] : "38400")
        _audioIn = State(initialValue: c.audioInput ?? "default")
        _audioOut = State(initialValue: c.audioOutput ?? "default")
        _proto = State(initialValue: c.proto.isEmpty ? "ft8" : c.proto)
        _cqDirective = State(initialValue: c.cqDirective ?? "")
        _lotwEnabled = State(initialValue: c.lotwEnabled)

        var locs = TQSLUploader.stationLocations()
        if let cur = c.lotwLocation, !cur.isEmpty, !locs.contains(cur) { locs.insert(cur, at: 0) }
        if locs.isEmpty { locs = ["none"] }
        lotwLocs = locs
        _lotwLoc = State(initialValue: c.lotwLocation?.isEmpty == false ? c.lotwLocation! : locs[0])
        _tqslPath = State(initialValue: c.tqslPath ?? (TQSLUploader.resolveBinary() ?? ""))
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Station") {
                    TextField("Callsign", text: $call).textCase(.uppercase)
                    TextField("Grid", text: $grid).textCase(.uppercase)
                }
                Section("Rig (CAT)") {
                    HStack {
                        Text("Rig")
                        Spacer()
                        Text(rigName).foregroundStyle(.secondary)
                        Button("Choose…") { pickingRig = true }
                    }
                    Picker("Serial", selection: $serial) {
                        Text("none").tag("none")
                        ForEach(serialPorts) { p in
                            Text(p.likelyRig ? "📡 \(p.path)" : p.path).tag(p.path)
                        }
                    }
                    Picker("Baud", selection: $baud) {
                        ForEach(bauds, id: \.self) { Text($0).tag($0) }
                    }
                    LabeledContent("Status") {
                        Text(model.rigState.connected
                             ? "connected · \(String(format: "%.3f", Double(model.rigState.frequencyHz) / 1e6)) MHz"
                             : "not connected")
                            .foregroundStyle(model.rigState.connected ? .green : .secondary)
                    }
                }
                Section("Audio") {
                    Picker("Input (RX)", selection: $audioIn) {
                        Text("default").tag("default")
                        ForEach(inputs) { d in Text(d.name).tag(d.name) }
                    }
                    Picker("Output (TX)", selection: $audioOut) {
                        Text("default").tag("default")
                        ForEach(outputs) { d in Text(d.name).tag(d.name) }
                    }
                }
                Section("Mode") {
                    Picker("Protocol", selection: $proto) {
                        Text("FT8").tag("ft8"); Text("FT4").tag("ft4")
                    }.pickerStyle(.segmented)
                    TextField("CQ directive (e.g. DX, POTA)", text: $cqDirective)
                }
                Section("LoTW") {
                    Toggle("Sign + upload via TrustedQSL", isOn: $lotwEnabled)
                    Picker("Station location", selection: $lotwLoc) {
                        ForEach(lotwLocs, id: \.self) { Text($0).tag($0) }
                    }
                    TextField("tqsl path (blank = auto-detect)", text: $tqslPath)
                    Button("Upload log now") { model.uploadLog() }
                        .disabled(lotwLoc == "none" || lotwLoc.isEmpty)
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Text(model.status).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { isPresented = false }
                Button("Save") { save() }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 460, height: 560)
        .sheet(isPresented: $pickingRig) {
            RigPickerView(selected: $rigModel, isPresented: $pickingRig)
        }
    }

    private var rigName: String {
        guard rigModel != 0 else { return "none" }
        if let r = HamlibRigs.all().first(where: { $0.model == rigModel }) { return r.displayName }
        return "model \(rigModel)"
    }

    private func save() {
        var c = model.currentConfig
        c.callsign = call.uppercased()
        c.grid = grid.uppercased()
        let rig = rigModel == 0 ? "" : String(rigModel)
        let ser = serial == "none" ? "" : serial
        c.rigSpec = rig.isEmpty ? nil : (ser.isEmpty ? rig : "\(rig),\(ser),\(baud)")
        c.audioInput = audioIn == "default" ? nil : audioIn
        c.audioOutput = audioOut == "default" ? nil : audioOut
        c.proto = proto
        c.cqDirective = cqDirective.trimmingCharacters(in: .whitespaces).isEmpty ? nil
            : cqDirective.trimmingCharacters(in: .whitespaces)
        c.lotwEnabled = lotwEnabled
        c.lotwLocation = (lotwLoc.isEmpty || lotwLoc == "none") ? nil : lotwLoc
        let auto = TQSLUploader.resolveBinary() ?? ""
        let tq = tqslPath.trimmingCharacters(in: .whitespaces)
        c.tqslPath = (tq.isEmpty || tq == auto) ? nil : tq
        model.applySettings(c)
        isPresented = false
    }
}

/// Searchable picker over all Hamlib-supported rigs.
struct RigPickerView: View {
    @Binding var selected: Int
    @Binding var isPresented: Bool
    @State private var query = ""

    private let rigs = HamlibRigs.all()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Select rig").font(.headline)
                Spacer()
                Button("None") { selected = 0; isPresented = false }
                Button("Done") { isPresented = false }
            }
            .padding(12)
            Divider()
            List(filtered) { r in
                Button {
                    selected = r.model
                    isPresented = false
                } label: {
                    HStack {
                        Text(r.displayName)
                        Spacer()
                        if r.model == selected { Image(systemName: "checkmark").foregroundStyle(.tint) }
                        Text(r.status).font(.caption2).foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .searchable(text: $query, placement: .toolbar, prompt: "Manufacturer or model")
        }
        .frame(width: 440, height: 520)
    }

    private var filtered: [HamlibRigModel] {
        guard !query.isEmpty else { return rigs }
        let q = query.lowercased()
        return rigs.filter { $0.displayName.lowercased().contains(q) || String($0.model) == q }
    }
}
