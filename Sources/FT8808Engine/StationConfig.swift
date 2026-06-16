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

    public init(callsign: String = "",
                grid: String = "",
                rigSpec: String? = nil,
                audioInput: String? = nil,
                audioOutput: String? = nil,
                txOffsetHz: Float = 1500,
                txDriveDb: Float = -30,
                proto: String = "ft8",
                cqDirective: String? = nil) {
        self.callsign = callsign
        self.grid = grid
        self.rigSpec = rigSpec
        self.audioInput = audioInput
        self.audioOutput = audioOutput
        self.txOffsetHz = txOffsetHz
        self.txDriveDb = txDriveDb
        self.proto = proto
        self.cqDirective = cqDirective
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
