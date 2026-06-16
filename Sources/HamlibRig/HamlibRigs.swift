import CHamlib
import Foundation

/// A Hamlib-supported rig model, for the rig picker.
public struct HamlibRigModel: Sendable, Identifiable, Equatable {
    public let model: Int
    public let manufacturer: String
    public let name: String
    public let status: String   // "Stable", "Beta", …

    public var id: Int { model }
    public var displayName: String {
        manufacturer.isEmpty ? name : "\(manufacturer) \(name)"
    }
}

public enum HamlibRigs {
    /// All rigs Hamlib supports, sorted by manufacturer then model name.
    /// Excludes the internal dummy/placeholder backends.
    public static func all() -> [HamlibRigModel] {
        var buf = [ft8808_rig_model](repeating: ft8808_rig_model(), count: 2048)
        let count = buf.withUnsafeMutableBufferPointer {
            ft8808_list_rigs($0.baseAddress, Int32($0.count))
        }
        let rigs = (0..<Int(count)).map { i -> HamlibRigModel in
            HamlibRigModel(
                model: Int(buf[i].model),
                manufacturer: Self.string(&buf[i].mfg),
                name: Self.string(&buf[i].name),
                status: Self.statusName(buf[i].status))
        }
        return rigs
            .filter { $0.model > 4 }   // drop dummy/netrigctl placeholders
            .sorted { ($0.manufacturer, $0.name) < ($1.manufacturer, $1.name) }
    }

    private static func statusName(_ s: Int32) -> String {
        switch s {
        case 0: return "Alpha"
        case 1: return "Untested"
        case 2: return "Beta"
        case 3: return "Stable"
        case 4: return "Buggy"
        default: return "?"
        }
    }

    private static func string<T>(_ tuple: inout T) -> String {
        let capacity = MemoryLayout<T>.size
        return withUnsafePointer(to: &tuple) {
            $0.withMemoryRebound(to: CChar.self, capacity: capacity) { String(cString: $0) }
        }
    }
}
