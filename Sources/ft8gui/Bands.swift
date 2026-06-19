import Foundation

/// A standard FT8 dial (USB) frequency for an amateur band.
struct FT8Band: Identifiable, Hashable {
    let name: String
    let dialHz: Int
    var id: String { name }
    var dialMHz: String { String(format: "%.3f", Double(dialHz) / 1_000_000) }
}

enum FT8Bands {
    /// Conventional FT8 watering-hole dial frequencies (USB), low band to high.
    static let all: [FT8Band] = [
        FT8Band(name: "160m", dialHz: 1_840_000),
        FT8Band(name: "80m",  dialHz: 3_573_000),
        FT8Band(name: "60m",  dialHz: 5_357_000),
        FT8Band(name: "40m",  dialHz: 7_074_000),
        FT8Band(name: "30m",  dialHz: 10_136_000),
        FT8Band(name: "20m",  dialHz: 14_074_000),
        FT8Band(name: "17m",  dialHz: 18_100_000),
        FT8Band(name: "15m",  dialHz: 21_074_000),
        FT8Band(name: "12m",  dialHz: 24_915_000),
        FT8Band(name: "10m",  dialHz: 28_074_000),
        FT8Band(name: "6m",   dialHz: 50_313_000),
        FT8Band(name: "2m",   dialHz: 144_174_000),
    ]

    /// The band whose dial matches `hz` exactly, if any.
    static func matching(_ hz: Int) -> FT8Band? { all.first { $0.dialHz == hz } }
}
