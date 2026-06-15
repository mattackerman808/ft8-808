import Foundation

/// Parses a rig spec string shared by the CLIs: `name-or-model[,device[,baud]]`.
///
///   dummy
///   ftdx101d,/dev/cu.usbserial-00943F8D0,38400
///   1040,/dev/cu.usbserial-00943F8D0,38400
public enum RigSpec {
    /// Friendly names → Hamlib model numbers. Add rigs here as they're tested.
    public static let aliases: [String: Int] = [
        "dummy": HamlibModel.dummy,
        "netrigctl": HamlibModel.netRigctl,
        "ftdx101d": 1040,
        "ftdx101mp": 1044,
    ]

    public struct Parsed {
        public let model: Int
        public let device: String?
        public let baud: Int
    }

    public enum SpecError: Error, CustomStringConvertible {
        case unknownModel(String)
        public var description: String {
            switch self {
            case let .unknownModel(s):
                return "unknown rig '\(s)' — use a Hamlib model number or one of: "
                    + RigSpec.aliases.keys.sorted().joined(separator: ", ")
            }
        }
    }

    public static func parse(_ spec: String) throws -> Parsed {
        let parts = spec.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        let key = parts[0].lowercased()
        let model: Int
        if let m = aliases[key] { model = m }
        else if let m = Int(parts[0]) { model = m }
        else { throw SpecError.unknownModel(parts[0]) }
        let device = parts.count > 1 && !parts[1].isEmpty ? parts[1] : nil
        let baud = parts.count > 2 ? (Int(parts[2]) ?? 0) : 0
        return Parsed(model: model, device: device, baud: baud)
    }

    /// Build (but do not open) a controller from a spec.
    public static func controller(_ spec: String) throws -> HamlibRigController {
        let p = try parse(spec)
        return HamlibRigController(model: p.model, device: p.device, serialSpeed: p.baud)
    }
}
