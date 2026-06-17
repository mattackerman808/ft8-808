import XCTest
@testable import FT8808Engine

final class SlotClockTests: XCTestCase {
    func testParityOfKnownBoundaries() {
        // Epoch 0 is slot 0 (even). 15 s → slot 1 (odd). 30 s → slot 2 (even).
        XCTAssertEqual(SlotClock.parity(at: Date(timeIntervalSince1970: 0)), .even)
        XCTAssertEqual(SlotClock.parity(at: Date(timeIntervalSince1970: 15)), .odd)
        XCTAssertEqual(SlotClock.parity(at: Date(timeIntervalSince1970: 30)), .even)
        XCTAssertEqual(SlotClock.parity(at: Date(timeIntervalSince1970: 44)), .even) // slot 2 = [30,45)
        XCTAssertEqual(SlotClock.parity(at: Date(timeIntervalSince1970: 50)), .odd)  // slot 3 = [45,60)
    }

    func testNextSlotStartHasRequestedParityAndIsInFuture() {
        let now = Date(timeIntervalSince1970: 1_000_000.4) // arbitrary
        for parity in SlotParity.allCases {
            let start = SlotClock.nextSlotStart(parity: parity, after: now)
            XCTAssertGreaterThan(start.timeIntervalSince(now), 0)
            XCTAssertEqual(SlotClock.parity(at: start), parity)
            // Lands exactly on a 15 s boundary.
            XCTAssertEqual(start.timeIntervalSince1970.truncatingRemainder(dividingBy: 15), 0, accuracy: 1e-6)
        }
    }

    func testSecondsUntilNextSlotWithinOnePeriod() {
        let now = Date(timeIntervalSince1970: 12_345.0)
        for parity in SlotParity.allCases {
            let s = SlotClock.secondsUntilNextSlot(parity: parity, after: now)
            XCTAssertGreaterThan(s, 0)
            XCTAssertLessThanOrEqual(s, 30) // a matching slot is at most one 30 s period away
        }
    }
}

final class QSOMessagesTests: XCTestCase {
    func testReportFormatting() {
        XCTAssertEqual(QSOMessages.formatReport(-10), "-10")
        XCTAssertEqual(QSOMessages.formatReport(5), "+05")
        XCTAssertEqual(QSOMessages.formatReport(0), "+00")
    }

    func testGenerators() {
        XCTAssertEqual(QSOMessages.cq(call: "n6ack", grid: "cm97"), "CQ N6ACK CM97")
        XCTAssertEqual(QSOMessages.cq(call: "N6ACK", grid: "CM97", directive: "dx"), "CQ DX N6ACK CM97")
        XCTAssertEqual(QSOMessages.reply(dx: "K1ABC", myCall: "N6ACK", myGrid: "CM97"), "K1ABC N6ACK CM97")
        XCTAssertEqual(QSOMessages.report(dx: "K1ABC", myCall: "N6ACK", snr: -7), "K1ABC N6ACK -07")
        XCTAssertEqual(QSOMessages.rogerReport(dx: "K1ABC", myCall: "N6ACK", snr: -7), "K1ABC N6ACK R-07")
        XCTAssertEqual(QSOMessages.roger(dx: "K1ABC", myCall: "N6ACK"), "K1ABC N6ACK RR73")
        XCTAssertEqual(QSOMessages.seventyThree(dx: "K1ABC", myCall: "N6ACK"), "K1ABC N6ACK 73")
    }

    func testParseCQ() {
        let p = QSOMessages.parse("CQ N6ACK CM97")
        XCTAssertEqual(p?.isCQ, true)
        XCTAssertEqual(p?.deCall, "N6ACK")
        XCTAssertEqual(p?.grid, "CM97")
    }

    func testParseCQFourCharCall() {
        // A 4-char callsign (with a digit) must not be mistaken for a directive.
        for (msg, call, grid) in [("CQ NI7C DM43", "NI7C", "DM43"),
                                  ("CQ NH6D BL02", "NH6D", "BL02")] {
            let p = QSOMessages.parse(msg)
            XCTAssertEqual(p?.isCQ, true, msg)
            XCTAssertNil(p?.directive, msg)
            XCTAssertEqual(p?.deCall, call, msg)
            XCTAssertEqual(p?.grid, grid, msg)
        }
    }

    func testParseCQDirective() {
        let p = QSOMessages.parse("CQ DX W1AW FN31")
        XCTAssertEqual(p?.directive, "DX")
        XCTAssertEqual(p?.deCall, "W1AW")
        XCTAssertEqual(p?.grid, "FN31")

        // Digit-free 4-char directives still work (POTA), call still parses.
        let q = QSOMessages.parse("CQ POTA K4SWL EM85")
        XCTAssertEqual(q?.directive, "POTA")
        XCTAssertEqual(q?.deCall, "K4SWL")
    }

    func testParseDirectedReportAndReply() {
        let rep = QSOMessages.parse("N6ACK K1ABC -12")
        XCTAssertEqual(rep?.toCall, "N6ACK")
        XCTAssertEqual(rep?.deCall, "K1ABC")
        XCTAssertEqual(rep?.report, -12)
        XCTAssertEqual(rep?.rogerReport, false)

        let r = QSOMessages.parse("N6ACK K1ABC R-12")
        XCTAssertEqual(r?.report, -12)
        XCTAssertEqual(r?.rogerReport, true)

        let reply = QSOMessages.parse("N6ACK K1ABC FN42")
        XCTAssertEqual(reply?.grid, "FN42")

        XCTAssertEqual(QSOMessages.parse("N6ACK K1ABC RR73")?.isRR73, true)
        XCTAssertEqual(QSOMessages.parse("N6ACK K1ABC 73")?.is73, true)
    }
}

final class WaveformPlayerTests: XCTestCase {
    func testPlaysThenSilenceAndFinishes() {
        let player = WaveformPlayer(samples: [1, 1, 1, 1], amplitude: 0.5)
        XCTAssertFalse(player.isFinished)

        var buf = [Float](repeating: -9, count: 3)
        buf.withUnsafeMutableBufferPointer { player.render($0) }
        XCTAssertEqual(buf, [0.5, 0.5, 0.5])
        XCTAssertFalse(player.isFinished)

        var buf2 = [Float](repeating: -9, count: 3)
        buf2.withUnsafeMutableBufferPointer { player.render($0) }
        XCTAssertEqual(buf2, [0.5, 0, 0]) // last sample, then silence
        XCTAssertTrue(player.isFinished)
    }
}
