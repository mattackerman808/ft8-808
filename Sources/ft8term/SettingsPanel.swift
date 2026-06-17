import Foundation
import FT8808Engine
import HamlibRig

/// Editable model for the in-app Settings panel. Decomposes `StationConfig`
/// (notably the `rigSpec` string) into fields, carries the detected serial/audio
/// devices so it can describe and auto-detect the rig, and recomposes on save.
@MainActor
final class SettingsEditor {
    enum Kind {
        case text
        case choice([String])
    }
    struct Field {
        let label: String
        let kind: Kind
    }

    let fields: [Field]
    var values: [String]
    var selected = 0
    var editing = false
    var buffer = ""

    // Rig picker sub-state (the rig list is far too long to cycle through).
    let rigFieldIndex: Int
    var rigPicking = false
    var rigQuery = ""
    var rigSelected = 0

    private let serialPorts: [SerialPort]
    private let inputDevices: [AudioInputDevice]
    private let outputDevices: [AudioInputDevice]

    /// All Hamlib rigs, loaded once and cached across panel opens.
    private static var rigCache: [HamlibRigModel]?
    static func rigs() -> [HamlibRigModel] {
        if let c = rigCache { return c }
        let r = HamlibRigs.all()
        rigCache = r
        return r
    }

    /// The tqsl path that auto-resolves with no override — so apply() can tell
    /// "left as detected" (keep auto) from "user typed a custom path" (override).
    private let autoTqslPath: String

    init(config: StationConfig, serialPorts: [SerialPort],
         inputDevices: [AudioInputDevice], outputDevices: [AudioInputDevice]) {
        self.serialPorts = serialPorts
        self.inputDevices = inputDevices
        self.outputDevices = outputDevices

        // LoTW station locations come from the operator's TrustedQSL data; keep
        // the currently-saved one even if it isn't (yet) in that list.
        var lotwLocs = TQSLUploader.stationLocations()
        if let cur = config.lotwLocation, !cur.isEmpty, !lotwLocs.contains(cur) {
            lotwLocs.insert(cur, at: 0)
        }
        if lotwLocs.isEmpty { lotwLocs = ["none"] }

        autoTqslPath = TQSLUploader.resolveBinary() ?? ""

        fields = [
            Field(label: "Call",      kind: .text),
            Field(label: "Grid",      kind: .text),
            Field(label: "Rig",       kind: .choice(["none"])),   // selected via the rig picker
            Field(label: "Serial",    kind: .choice(["none"] + serialPorts.map(\.path))),
            Field(label: "Baud",      kind: .choice(["4800", "9600", "19200", "38400", "57600", "115200"])),
            Field(label: "Audio in",  kind: .choice(["default"] + inputDevices.map(\.name))),
            Field(label: "Audio out", kind: .choice(["default"] + outputDevices.map(\.name))),
            Field(label: "Proto",     kind: .choice(["ft8", "ft4"])),
            Field(label: "LoTW",      kind: .choice(["off", "on"])),
            Field(label: "LoTW loc",  kind: .choice(lotwLocs)),
            Field(label: "tqsl",      kind: .text),
        ]

        rigFieldIndex = 2

        let (rig, serial, baud) = Self.splitRig(config.rigSpec)
        // Normalize the rig token to a model number (aliases → number) for the picker.
        let rigValue = rig.isEmpty ? "none" : (RigSpec.aliases[rig.lowercased()].map(String.init) ?? rig)

        // Auto-detect: use the saved value only if that device/port is still
        // present; otherwise pick the likely rig (handles a swapped/unplugged rig).
        let rigSerial = serialPorts.first(where: { $0.likelyRig })?.path
        let rigInput = inputDevices.first(where: { Self.isRig($0) })?.name
        let rigOutput = outputDevices.first(where: { Self.isRig($0) })?.name

        func present(_ value: String?, in names: [String]) -> Bool {
            guard let value else { return false }
            return names.contains(value)
        }

        let serialValue = present(serial.isEmpty ? nil : serial, in: serialPorts.map(\.path))
            ? serial : (rigSerial ?? "none")
        let inValue = present(config.audioInput, in: inputDevices.map(\.name))
            ? config.audioInput! : (rigInput ?? "default")
        let outValue = present(config.audioOutput, in: outputDevices.map(\.name))
            ? config.audioOutput! : (rigOutput ?? "default")

        values = [
            config.callsign,
            config.grid,
            rigValue,
            serialValue,
            baud.isEmpty ? "38400" : baud,
            inValue,
            outValue,
            config.proto,
            config.lotwEnabled ? "on" : "off",
            config.lotwLocation?.isEmpty == false ? config.lotwLocation! : lotwLocs[0],
            config.tqslPath ?? autoTqslPath,
        ]
    }

    // MARK: navigation / editing

    func moveSelection(_ delta: Int) {
        guard !editing else { return }
        selected = max(0, min(fields.count - 1, selected + delta))
    }

    func cycle(_ dir: Int) {
        guard !editing, case let .choice(options) = fields[selected].kind, !options.isEmpty else { return }
        let cur = options.firstIndex(of: values[selected]) ?? 0
        let next = ((cur + dir) % options.count + options.count) % options.count
        values[selected] = options[next]
    }

    func activate() {
        switch fields[selected].kind {
        case .text:
            editing = true
            buffer = values[selected]
        case .choice:
            cycle(1)
        }
    }

    func commitEdit() {
        guard editing else { return }
        values[selected] = buffer.trimmingCharacters(in: .whitespaces)
        editing = false
    }

    func typeCharacter(_ c: Character) { buffer.append(c) }
    func backspace() { if !buffer.isEmpty { buffer.removeLast() } }

    // MARK: rig picker

    var filteredRigs: [HamlibRigModel] {
        let all = Self.rigs()
        guard !rigQuery.isEmpty else { return all }
        let q = rigQuery.lowercased()
        return all.filter { $0.displayName.lowercased().contains(q) || String($0.model) == q }
    }

    func startRigPicker() {
        rigPicking = true
        rigQuery = ""
        // Start the cursor on the current rig if any.
        if let model = Int(values[rigFieldIndex]),
           let idx = filteredRigs.firstIndex(where: { $0.model == model }) {
            rigSelected = idx
        } else {
            rigSelected = 0
        }
    }

    func rigPickerType(_ c: Character) { rigQuery.append(c); rigSelected = 0 }
    func rigPickerBackspace() { if !rigQuery.isEmpty { rigQuery.removeLast(); rigSelected = 0 } }
    func rigPickerMove(_ d: Int) {
        let n = filteredRigs.count
        if n > 0 { rigSelected = max(0, min(n - 1, rigSelected + d)) }
    }
    func rigPickerChoose() {
        let f = filteredRigs
        if rigSelected < f.count { values[rigFieldIndex] = String(f[rigSelected].model) }
        rigPicking = false
    }
    func rigPickerCancel() { rigPicking = false }

    /// Display string for a field's value (the Rig field shows the rig name).
    func displayValue(at index: Int) -> String {
        if index == rigFieldIndex {
            let v = values[index]
            if v == "none" { return "none" }
            if let model = Int(v), let r = Self.rigs().first(where: { $0.model == model }) {
                return r.displayName
            }
            return v
        }
        return values[index]
    }

    // MARK: detail line for the selected field

    /// A human description of the current value (USB chip, transport, "likely rig"…).
    func detail() -> String? {
        let value = values[selected]
        switch fields[selected].label {
        case "Serial":
            if value == "none" { return "no CAT control" }
            return serialPorts.first(where: { $0.path == value })?.detail
        case "Audio in":
            return audioDetail(value, in: inputDevices)
        case "Audio out":
            return audioDetail(value, in: outputDevices)
        case "Rig":
            if value == "none" { return "no rig control" }
            return RigSpec.aliases[value].map { "Hamlib model \($0)" }
        case "LoTW":
            if value == "off" { return "LoTW auto-upload off" }
            return TQSLUploader.resolveBinary() != nil
                ? "sign + upload each QSO via tqsl"
                : "tqsl not found — install TrustedQSL"
        case "LoTW loc":
            if value == "none" { return "no station location — set one up in TrustedQSL" }
            return "TQSL station location"
        case "tqsl":
            if value.isEmpty { return "tqsl not found — install TrustedQSL or type a path" }
            if !FileManager.default.isExecutableFile(atPath: value) { return "no executable at this path" }
            return value == autoTqslPath ? "auto-detected" : "custom path (overrides auto-detect)"
        default:
            return nil
        }
    }

    private func audioDetail(_ value: String, in devices: [AudioInputDevice]) -> String? {
        if value == "default" { return "system default device" }
        guard let d = devices.first(where: { $0.name == value }) else { return nil }
        var bits = [d.transport, "\(d.channels) ch"]
        if !d.manufacturer.isEmpty { bits.append(d.manufacturer) }
        if Self.isRig(d) { bits.append("likely rig") }
        return bits.joined(separator: " · ")
    }

    private static func isRig(_ d: AudioInputDevice) -> Bool {
        d.transport == "USB" && !d.manufacturer.lowercased().contains("apple")
    }

    // MARK: save

    func apply(to config: inout StationConfig) {
        if editing { commitEdit() }
        config.callsign = values[0].uppercased()
        config.grid = values[1].uppercased()

        let rig = values[2] == "none" ? "" : values[2]
        let serial = values[3] == "none" ? "" : values[3]
        let baud = values[4]
        if rig.isEmpty {
            config.rigSpec = nil
        } else if serial.isEmpty {
            config.rigSpec = rig
        } else {
            config.rigSpec = "\(rig),\(serial),\(baud)"
        }

        config.audioInput = values[5] == "default" ? nil : values[5]
        config.audioOutput = values[6] == "default" ? nil : values[6]
        config.proto = values[7]
        config.lotwEnabled = values[8] == "on"
        let loc = values[9].trimmingCharacters(in: .whitespaces)
        config.lotwLocation = (loc.isEmpty || loc == "none") ? nil : loc
        // Only persist a tqsl path when it's a real override; leaving it at the
        // auto-detected value keeps auto-resolution (survives a TQSL move/update).
        let tqsl = values[10].trimmingCharacters(in: .whitespaces)
        config.tqslPath = (tqsl.isEmpty || tqsl == autoTqslPath) ? nil : tqsl
    }

    static func splitRig(_ spec: String?) -> (rig: String, serial: String, baud: String) {
        guard let spec, !spec.isEmpty else { return ("", "", "") }
        let p = spec.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        return (p.first ?? "", p.count > 1 ? p[1] : "", p.count > 2 ? p[2] : "")
    }
}
