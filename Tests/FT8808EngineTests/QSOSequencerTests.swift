import XCTest
@testable import FT8808Engine

final class QSOSequencerTests: XCTestCase {
    private func parse(_ s: String) -> QSOMessages.Parsed { QSOMessages.parse(s)! }

    func testAnswerFlowToCompletion() {
        // We answer K1ABC's CQ; we are N6ACK/CM97.
        var q = QSOSequencer(answer: "K1ABC", dxGrid: "FN42", heardSnr: -8,
                             myCall: "N6ACK", myGrid: "CM97")
        XCTAssertEqual(q.message(), "K1ABC N6ACK CM97")           // grid reply

        // They report us.
        XCTAssertTrue(q.receive(parse("N6ACK K1ABC -10"), snr: -5))
        XCTAssertEqual(q.reportReceived, -10)
        XCTAssertEqual(q.message(), "K1ABC N6ACK R-05")          // R + our report

        // They roger.
        XCTAssertTrue(q.receive(parse("N6ACK K1ABC RR73"), snr: -5))
        XCTAssertEqual(q.message(), "K1ABC N6ACK 73")
        XCTAssertFalse(q.isComplete)

        // Their 73 (or our send) finishes it.
        XCTAssertTrue(q.receive(parse("N6ACK K1ABC 73"), snr: -5))
        XCTAssertTrue(q.isComplete)
        XCTAssertNil(q.message())
    }

    func testCallCQFlowToCompletion() {
        var q = QSOSequencer(callCQ: "N6ACK", myGrid: "CM97")
        XCTAssertEqual(q.message(), "CQ N6ACK CM97")

        // K1ABC answers with a grid.
        XCTAssertTrue(q.receive(parse("N6ACK K1ABC FN42"), snr: -12))
        XCTAssertEqual(q.dxCall, "K1ABC")
        XCTAssertEqual(q.message(), "K1ABC N6ACK -12")          // we report them

        // They roger + report.
        XCTAssertTrue(q.receive(parse("N6ACK K1ABC R-09"), snr: -11))
        XCTAssertEqual(q.reportReceived, -9)
        XCTAssertEqual(q.message(), "K1ABC N6ACK RR73")

        // Their 73 closes it.
        XCTAssertTrue(q.receive(parse("N6ACK K1ABC 73"), snr: -11))
        XCTAssertTrue(q.isComplete)
    }

    func testIgnoresTrafficNotForUs() {
        var q = QSOSequencer(answer: "K1ABC", dxGrid: nil, heardSnr: -8,
                             myCall: "N6ACK", myGrid: "CM97")
        XCTAssertFalse(q.receive(parse("W1XYZ K1ABC -10"), snr: -5))  // to someone else
        XCTAssertFalse(q.receive(parse("N6ACK W9ZZZ -10"), snr: -5))  // from someone else
        XCTAssertEqual(q.phase, .reply)                               // unchanged
    }
}
