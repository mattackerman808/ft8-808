import Foundation

/// The standard FT8 QSO message set (WSJT-X "Tx 1–6"), generated from your
/// station, the DX station, and the signal report you're sending.
///
/// For my call `N6ACK`, grid `CM97`, DX `W9BRT`, report `-15`:
///   Tx1 replyGrid  "W9BRT N6ACK CM97"   reply to a CQ with your grid
///   Tx2 report     "W9BRT N6ACK -15"    send signal report
///   Tx3 rReport    "W9BRT N6ACK R-15"   roger + report
///   Tx4 rr73       "W9BRT N6ACK RR73"   roger-roger 73
///   Tx5 seven3     "W9BRT N6ACK 73"     73
///   Tx6 cq         "CQ N6ACK CM97"      call CQ
public struct StandardMessages: Sendable, Equatable {
    public let replyGrid: String
    public let report: String
    public let rReport: String
    public let rr73: String
    public let seven3: String
    public let cq: String

    public init(myCall: String, myGrid: String, dxCall: String,
                reportSent: Int, cqDirective: String? = nil) {
        let me = myCall.uppercased()
        let dx = dxCall.uppercased()
        let grid = String(myGrid.prefix(4)).uppercased()
        let rpt = Self.formatReport(reportSent)

        replyGrid = "\(dx) \(me) \(grid)"
        report    = "\(dx) \(me) \(rpt)"
        rReport   = "\(dx) \(me) R\(rpt)"
        rr73      = "\(dx) \(me) RR73"
        seven3    = "\(dx) \(me) 73"
        if let d = cqDirective?.trimmingCharacters(in: .whitespaces), !d.isEmpty {
            cq = "CQ \(d.uppercased()) \(me) \(grid)"
        } else {
            cq = "CQ \(me) \(grid)"
        }
    }

    /// Tx1…Tx6 in order.
    public var all: [String] { [replyGrid, report, rReport, rr73, seven3, cq] }

    /// FT8 report: signed, two digits (e.g. `-15`, `+03`), clamped to range.
    public static func formatReport(_ db: Int) -> String {
        String(format: "%+03d", max(-30, min(49, db)))
    }
}
