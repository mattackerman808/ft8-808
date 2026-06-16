import Foundation

/// Generates and parses the standard FT8 QSO message set. Pure string logic —
/// no encoding here (that's `FT8Codec.encode`); this just produces the text a
/// QSO step needs and reads incoming text back into structured fields.
///
/// Standard exchange (we answer THEM, or they answer our CQ):
///   CQ      "CQ [DIR] MYCALL MYGRID"
///   reply   "DXCALL MYCALL MYGRID"
///   report  "DXCALL MYCALL -10"
///   R+rpt   "DXCALL MYCALL R-10"
///   roger   "DXCALL MYCALL RR73"   (or RRR)
///   73      "DXCALL MYCALL 73"
public enum QSOMessages {

    /// Two-digit signed report, e.g. -10 → "-10", 5 → "+05".
    public static func formatReport(_ snr: Int) -> String {
        let clamped = max(-30, min(49, snr))
        return String(format: "%+03d", clamped)
    }

    public static func cq(call: String, grid: String, directive: String? = nil) -> String {
        let c = call.uppercased(), g = grid.uppercased()
        if let d = directive, !d.isEmpty {
            return "CQ \(d.uppercased()) \(c) \(g)"
        }
        return "CQ \(c) \(g)"
    }

    public static func reply(dx: String, myCall: String, myGrid: String) -> String {
        "\(dx.uppercased()) \(myCall.uppercased()) \(myGrid.uppercased())"
    }

    public static func report(dx: String, myCall: String, snr: Int) -> String {
        "\(dx.uppercased()) \(myCall.uppercased()) \(formatReport(snr))"
    }

    public static func rogerReport(dx: String, myCall: String, snr: Int) -> String {
        "\(dx.uppercased()) \(myCall.uppercased()) R\(formatReport(snr))"
    }

    public static func roger(dx: String, myCall: String, rr73: Bool = true) -> String {
        "\(dx.uppercased()) \(myCall.uppercased()) \(rr73 ? "RR73" : "RRR")"
    }

    public static func seventyThree(dx: String, myCall: String) -> String {
        "\(dx.uppercased()) \(myCall.uppercased()) 73"
    }

    // MARK: - Parsing

    /// A received FT8 message broken into its meaningful parts.
    public struct Parsed: Sendable, Equatable {
        public var isCQ: Bool
        public var directive: String?     // CQ directive, e.g. "DX", "POTA"
        public var toCall: String?        // addressee (first token of a directed msg)
        public var deCall: String?        // sender (second token)
        public var grid: String?          // 4-char Maidenhead, if present
        public var report: Int?           // numeric report, if present
        public var rogerReport: Bool      // "R-10" style
        public var isRR73: Bool           // RR73 / RRR
        public var is73: Bool
    }

    private static func isGrid(_ s: String) -> Bool {
        guard s.count == 4 else { return false }
        let c = Array(s.uppercased())
        return c[0].isLetter && c[1].isLetter && c[2].isNumber && c[3].isNumber
    }

    private static func parseReport(_ s: String) -> (value: Int, roger: Bool)? {
        var t = s.uppercased()
        var roger = false
        if t.hasPrefix("R") && t.count > 1 && (t[t.index(after: t.startIndex)] == "+" || t[t.index(after: t.startIndex)] == "-") {
            roger = true
            t.removeFirst()
        }
        guard t.first == "+" || t.first == "-", let v = Int(t) else { return nil }
        return (v, roger)
    }

    /// Parse a decoded message into fields. Returns `nil` for unrecognized/free text.
    public static func parse(_ text: String) -> Parsed? {
        let toks = text.uppercased().split(separator: " ").map(String.init)
        guard !toks.isEmpty else { return nil }

        if toks[0] == "CQ" {
            // CQ [DIR] CALL [GRID]
            var idx = 1
            var directive: String?
            if toks.count > 1, toks[1].count <= 4, !toks[1].contains("/"),
               Int(toks[1]) == nil, !isGrid(toks[1]), toks.count > 2 {
                // A short non-grid token after CQ that isn't the callsign's grid
                // is a directive (DX/POTA/…). Heuristic but matches common usage.
                if toks.count >= 3 { directive = toks[1]; idx = 2 }
            }
            let deCall = idx < toks.count ? toks[idx] : nil
            let grid = (idx + 1 < toks.count && isGrid(toks[idx + 1])) ? toks[idx + 1] : nil
            return Parsed(isCQ: true, directive: directive, toCall: nil, deCall: deCall,
                          grid: grid, report: nil, rogerReport: false, isRR73: false, is73: false)
        }

        guard toks.count >= 2 else { return nil }
        let toCall = toks[0]
        let deCall = toks[1]
        var grid: String?
        var report: Int?
        var roger = false
        var rr73 = false
        var is73 = false
        if toks.count >= 3 {
            // Order matters: "RR73" matches the 2-letter+2-digit grid shape, so
            // the literal roger/73/report tokens must be tested before isGrid().
            let third = toks[2]
            if third == "RR73" || third == "RRR" { rr73 = true }
            else if third == "73" { is73 = true }
            else if let r = parseReport(third) { report = r.value; roger = r.roger }
            else if isGrid(third) { grid = third }
        }
        return Parsed(isCQ: false, directive: nil, toCall: toCall, deCall: deCall,
                      grid: grid, report: report, rogerReport: roger, isRR73: rr73, is73: is73)
    }
}
