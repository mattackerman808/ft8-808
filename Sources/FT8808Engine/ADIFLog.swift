import Foundation

/// One logged QSO, ready to serialize to ADIF.
public struct ADIFRecord: Sendable {
    public var call: String
    public var dateUTC: Date
    public var freqMHz: Double
    public var mode: String          // e.g. "FT8"
    public var submode: String?      // e.g. "FT4" (with mode "MFSK")
    public var rstSent: String
    public var rstRcvd: String
    public var grid: String?
    public var myCall: String
    public var myGrid: String

    public init(call: String, dateUTC: Date, freqMHz: Double, mode: String,
                submode: String? = nil, rstSent: String, rstRcvd: String,
                grid: String? = nil, myCall: String, myGrid: String) {
        self.call = call; self.dateUTC = dateUTC; self.freqMHz = freqMHz
        self.mode = mode; self.submode = submode
        self.rstSent = rstSent; self.rstRcvd = rstRcvd; self.grid = grid
        self.myCall = myCall; self.myGrid = myGrid
    }
}

/// Append-only ADIF logger. Writes a header once, then one `<...> <EOR>` record
/// per QSO — importable into LoTW, QRZ, Club Log, etc.
public enum ADIFLog {
    public static func defaultURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/ft8-808/ft8-808.adi")
    }

    /// ADIF band name for a frequency in MHz ("" if outside the ham bands).
    public static func band(forMHz mhz: Double) -> String {
        switch mhz {
        case 1.8..<2.0:        return "160m"
        case 3.5..<4.0:        return "80m"
        case 5.0..<5.5:        return "60m"
        case 7.0..<7.3:        return "40m"
        case 10.1..<10.15:     return "30m"
        case 14.0..<14.35:     return "20m"
        case 18.068..<18.168:  return "17m"
        case 21.0..<21.45:     return "15m"
        case 24.89..<24.99:    return "12m"
        case 28.0..<29.7:      return "10m"
        case 50.0..<54.0:      return "6m"
        default:               return ""
        }
    }

    /// The set of callsigns already worked, read from an ADIF file's CALL
    /// fields (case-insensitive field name; values upper-cased). Empty if the
    /// file is missing — used to flag "worked before" decodes.
    public static func workedCalls(from url: URL = defaultURL()) -> Set<String> {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        var result = Set<String>()
        var idx = text.startIndex
        while let r = text.range(of: "<call:", options: .caseInsensitive, range: idx..<text.endIndex) {
            var i = r.upperBound
            var lenStr = ""
            while i < text.endIndex, text[i].isNumber { lenStr.append(text[i]); i = text.index(after: i) }
            while i < text.endIndex, text[i] != ">" { i = text.index(after: i) }   // skip optional :TYPE
            guard i < text.endIndex, let len = Int(lenStr) else { idx = r.upperBound; continue }
            let valStart = text.index(after: i)                                    // after '>'
            guard let valEnd = text.index(valStart, offsetBy: len, limitedBy: text.endIndex) else {
                idx = r.upperBound; continue
            }
            result.insert(String(text[valStart..<valEnd]).uppercased())
            idx = valEnd
        }
        return result
    }

    public static func header() -> String {
        "FT8-808 ADIF export\n<ADIF_VER:5>3.1.4\n<PROGRAMID:7>FT8-808\n<EOH>\n"
    }

    private static func field(_ name: String, _ value: String) -> String {
        value.isEmpty ? "" : "<\(name):\(value.utf8.count)>\(value) "
    }

    private static func utcStamp(_ date: Date) -> (date: String, time: String) {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return (String(format: "%04d%02d%02d", c.year!, c.month!, c.day!),
                String(format: "%02d%02d%02d", c.hour!, c.minute!, c.second!))
    }

    /// One ADIF record line (with trailing newline).
    public static func record(_ r: ADIFRecord) -> String {
        let (d, t) = utcStamp(r.dateUTC)
        var s = ""
        s += field("CALL", r.call.uppercased())
        s += field("QSO_DATE", d)
        s += field("TIME_ON", t)
        s += field("BAND", band(forMHz: r.freqMHz))
        s += field("FREQ", String(format: "%.6f", r.freqMHz))
        s += field("MODE", r.mode)
        if let sm = r.submode { s += field("SUBMODE", sm) }
        s += field("RST_SENT", r.rstSent)
        s += field("RST_RCVD", r.rstRcvd)
        if let g = r.grid { s += field("GRIDSQUARE", g) }
        s += field("STATION_CALLSIGN", r.myCall.uppercased())
        s += field("MY_GRIDSQUARE", r.myGrid.uppercased())
        s += "<EOR>\n"
        return s
    }

    /// Append `r` to the ADIF file, creating it (with a header) if needed.
    @discardableResult
    public static func append(_ r: ADIFRecord, to url: URL = defaultURL()) throws -> URL {
        let rec = record(r)
        if FileManager.default.fileExists(atPath: url.path) {
            let h = try FileHandle(forWritingTo: url)
            defer { try? h.close() }
            try h.seekToEnd()
            if let data = rec.data(using: .utf8) { h.write(data) }
        } else {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try (header() + rec).write(to: url, atomically: true, encoding: .utf8)
        }
        return url
    }
}
