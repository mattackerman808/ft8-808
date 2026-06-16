import Foundation
import FT8808Engine
import HamlibRig

/// Editable model for the in-app Settings panel. Decomposes `StationConfig`
/// (notably the `rigSpec` string) into individual fields and recomposes on save.
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

    init(config: StationConfig, serialPorts: [String], inputDevices: [String], outputDevices: [String]) {
        fields = [
            Field(label: "Call",      kind: .text),
            Field(label: "Grid",      kind: .text),
            Field(label: "Rig",       kind: .choice(["none"] + RigSpec.aliases.keys.sorted())),
            Field(label: "Serial",    kind: .choice(["none"] + serialPorts)),
            Field(label: "Baud",      kind: .choice(["4800", "9600", "19200", "38400", "57600", "115200"])),
            Field(label: "Audio in",  kind: .choice(["default"] + inputDevices)),
            Field(label: "Audio out", kind: .choice(["default"] + outputDevices)),
            Field(label: "Proto",     kind: .choice(["ft8", "ft4"])),
        ]
        let (rig, serial, baud) = Self.splitRig(config.rigSpec)
        values = [
            config.callsign,
            config.grid,
            rig.isEmpty ? "none" : rig,
            serial.isEmpty ? "none" : serial,
            baud.isEmpty ? "38400" : baud,
            config.audioInput ?? "default",
            config.audioOutput ?? "default",
            config.proto,
        ]
    }

    func moveSelection(_ delta: Int) {
        guard !editing else { return }
        selected = max(0, min(fields.count - 1, selected + delta))
    }

    /// Cycle a choice field's value (±1).
    func cycle(_ dir: Int) {
        guard !editing, case let .choice(options) = fields[selected].kind, !options.isEmpty else { return }
        let cur = options.firstIndex(of: values[selected]) ?? 0
        let next = ((cur + dir) % options.count + options.count) % options.count
        values[selected] = options[next]
    }

    /// Enter: begin editing a text field, or cycle a choice field forward.
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

    /// Fold the edited values back into a `StationConfig`.
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
    }

    /// Split "model,device,baud" into its parts.
    static func splitRig(_ spec: String?) -> (rig: String, serial: String, baud: String) {
        guard let spec, !spec.isEmpty else { return ("", "", "") }
        let p = spec.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        return (p.first ?? "", p.count > 1 ? p[1] : "", p.count > 2 ? p[2] : "")
    }
}
