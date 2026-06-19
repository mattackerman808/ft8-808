import Foundation

/// Drives one FT8 QSO through the standard message sequence, picking what to
/// transmit next and advancing as messages from the DX arrive. Pure and
/// testable — the UI feeds it decoded messages and asks for the current TX text.
///
/// Two entry points / roles:
///   callCQ : CQ → (they answer w/ grid) → report → (R-report) → RR73 → done
///   answer : reply(grid) → (their report) → R-report → (RR73) → 73 → done
/// The report we send is always the SNR we last decoded the DX at.
public struct QSOSequencer: Sendable, Equatable {
    public enum Phase: String, Sendable, Equatable {
        case cq, reply, report, rReport, rr73, seventyThree, done
    }

    public let myCall: String
    public let myGrid: String
    public private(set) var dxCall: String
    public private(set) var dxGrid: String?
    public private(set) var phase: Phase
    public private(set) var reportToSend: Int       // SNR we last heard the DX at
    public private(set) var reportReceived: Int?
    private let directive: String?

    public var isComplete: Bool { phase == .done }

    /// Answer a station we heard (we send our grid first).
    public init(answer dxCall: String, dxGrid: String?, heardSnr: Int,
                myCall: String, myGrid: String) {
        self.myCall = myCall.uppercased()
        self.myGrid = myGrid.uppercased()
        self.dxCall = dxCall.uppercased()
        self.dxGrid = dxGrid?.uppercased()
        self.reportToSend = heardSnr
        self.reportReceived = nil
        self.phase = .reply
        self.directive = nil
    }

    /// Resume an exchange from a message a station just sent *us* — e.g. after we
    /// called CQ and several stations came back, click one that's already
    /// answering (grid / report / R-report) and pick up at the correct reply
    /// instead of Tx1. The phase is set to what WE send next; `dxGrid` supplies a
    /// grid heard in an earlier decode when this message carries none.
    public init(resuming p: QSOMessages.Parsed, dxGrid: String?, heardSnr: Int,
                myCall: String, myGrid: String) {
        self.myCall = myCall.uppercased()
        self.myGrid = myGrid.uppercased()
        self.dxCall = (p.deCall ?? "").uppercased()
        self.dxGrid = (dxGrid ?? p.grid)?.uppercased()
        self.reportToSend = heardSnr
        self.directive = nil
        if p.is73 || p.isRR73 {
            self.reportReceived = nil;       self.phase = .seventyThree  // closing → 73
        } else if p.rogerReport {
            self.reportReceived = p.report;  self.phase = .rr73          // R-report → RR73
        } else if p.report != nil {
            self.reportReceived = p.report;  self.phase = .rReport       // report → R-report
        } else {
            self.reportReceived = nil;       self.phase = .report        // grid/bare → report
        }
    }

    /// Call CQ; adopts whoever answers and continues the exchange.
    public init(callCQ myCall: String, myGrid: String, directive: String? = nil) {
        self.myCall = myCall.uppercased()
        self.myGrid = myGrid.uppercased()
        self.dxCall = ""
        self.dxGrid = nil
        self.reportToSend = 0
        self.reportReceived = nil
        self.phase = .cq
        self.directive = directive
    }

    /// The message to transmit right now (nil once the QSO is done).
    public func message() -> String? {
        switch phase {
        case .cq:           return QSOMessages.cq(call: myCall, grid: myGrid, directive: directive)
        case .reply:        return QSOMessages.reply(dx: dxCall, myCall: myCall, myGrid: myGrid)
        case .report:       return QSOMessages.report(dx: dxCall, myCall: myCall, snr: reportToSend)
        case .rReport:      return QSOMessages.rogerReport(dx: dxCall, myCall: myCall, snr: reportToSend)
        case .rr73:         return QSOMessages.roger(dx: dxCall, myCall: myCall, rr73: true)
        case .seventyThree: return QSOMessages.seventyThree(dx: dxCall, myCall: myCall)
        case .done:         return nil
        }
    }

    /// Feed a decoded message and its SNR; returns true if it advanced the QSO.
    /// Only messages addressed to us (and, once locked on, from our DX) count.
    public mutating func receive(_ p: QSOMessages.Parsed, snr: Int) -> Bool {
        guard !p.isCQ, p.toCall == myCall, let from = p.deCall else { return false }

        // While calling CQ, adopt the first station that answers us.
        if phase == .cq {
            dxCall = from
            dxGrid = p.grid
            reportToSend = snr
            if p.report != nil { reportReceived = p.report; phase = .rReport }
            else { phase = .report }
            return true
        }

        guard from == dxCall else { return false }
        reportToSend = snr                       // keep our outgoing report current

        switch phase {
        case .reply:
            guard let r = p.report else { return false }
            reportReceived = r; phase = .rReport; return true
        case .report:
            guard p.report != nil || p.rogerReport else { return false }
            reportReceived = p.report ?? reportReceived; phase = .rr73; return true
        case .rReport:
            if p.isRR73 || p.is73 { phase = .seventyThree; return true }
            return p.report != nil          // consume a repeat, no phase change
        case .rr73:
            if p.is73 || p.isRR73 { phase = .done; return true }
            return false
        case .seventyThree:
            phase = .done; return true
        case .cq, .done:
            return false
        }
    }
}
