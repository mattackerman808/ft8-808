import Foundation

/// Persisted station configuration — what a future Settings panel edits, and
/// what lets the app remember rig/audio/call/drive across launches.
public struct StationConfig: Codable, Sendable, Equatable {
    public var callsign: String
    public var grid: String

    /// Rig spec string (`name-or-model[,device[,baud]]`), e.g. `ftdx101d,/dev/cu...,38400`.
    public var rigSpec: String?
    public var audioInput: String?   // capture device name/UID (rig codec)
    public var audioOutput: String?  // transmit device name/UID

    public var txOffsetHz: Float     // last TX audio offset
    public var txDriveDb: Float      // calibrated TX drive (dBFS)
    public var proto: String         // "ft8" or "ft4"
    public var cqDirective: String?  // e.g. "DX", "POTA"

    /// LoTW (Logbook of The World) auto-upload via TrustedQSL. Opt-in.
    public var lotwEnabled: Bool     // sign + upload each logged QSO as it completes
    public var lotwLocation: String? // TQSL "Station Location" name (e.g. "Cypress")
    public var tqslPath: String?     // override path to the `tqsl` binary (else auto-detect)

    public init(callsign: String = "",
                grid: String = "",
                rigSpec: String? = nil,
                audioInput: String? = nil,
                audioOutput: String? = nil,
                txOffsetHz: Float = 1500,
                txDriveDb: Float = -30,
                proto: String = "ft8",
                cqDirective: String? = nil,
                lotwEnabled: Bool = false,
                lotwLocation: String? = nil,
                tqslPath: String? = nil) {
        self.callsign = callsign
        self.grid = grid
        self.rigSpec = rigSpec
        self.audioInput = audioInput
        self.audioOutput = audioOutput
        self.txOffsetHz = txOffsetHz
        self.txDriveDb = txDriveDb
        self.proto = proto
        self.cqDirective = cqDirective
        self.lotwEnabled = lotwEnabled
        self.lotwLocation = lotwLocation
        self.tqslPath = tqslPath
    }

    // Tolerant decoder: missing keys fall back to the defaults above, so adding
    // a new field never makes an older config.json fail to decode (which would
    // otherwise wipe the saved station — ConfigStore.load returns a blank config
    // on any decode error).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func opt<T: Decodable>(_ k: CodingKeys, _ d: T) throws -> T {
            try c.decodeIfPresent(T.self, forKey: k) ?? d
        }
        callsign     = try opt(.callsign, "")
        grid         = try opt(.grid, "")
        rigSpec      = try c.decodeIfPresent(String.self, forKey: .rigSpec)
        audioInput   = try c.decodeIfPresent(String.self, forKey: .audioInput)
        audioOutput  = try c.decodeIfPresent(String.self, forKey: .audioOutput)
        txOffsetHz   = try opt(.txOffsetHz, 1500)
        txDriveDb    = try opt(.txDriveDb, -30)
        proto        = try opt(.proto, "ft8")
        cqDirective  = try c.decodeIfPresent(String.self, forKey: .cqDirective)
        lotwEnabled  = try opt(.lotwEnabled, false)
        lotwLocation = try c.decodeIfPresent(String.self, forKey: .lotwLocation)
        tqslPath     = try c.decodeIfPresent(String.self, forKey: .tqslPath)
    }

    public var isStationSet: Bool { !callsign.isEmpty && !grid.isEmpty }
}

/// Loads/saves `StationConfig` as JSON. Default location is
/// `~/.config/ft8-808/config.json` (works fine over SSH).
public enum ConfigStore {
    public static func defaultURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/ft8-808/config.json")
    }

    /// Returns the saved config, or a default if none/unreadable.
    public static func load(from url: URL = defaultURL()) -> StationConfig {
        guard let data = try? Data(contentsOf: url),
              let cfg = try? JSONDecoder().decode(StationConfig.self, from: data) else {
            return StationConfig()
        }
        return cfg
    }

    public static func save(_ config: StationConfig, to url: URL = defaultURL()) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(config).write(to: url, options: .atomic)
    }
}
