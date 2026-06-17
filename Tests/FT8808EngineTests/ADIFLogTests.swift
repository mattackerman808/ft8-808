import XCTest
@testable import FT8808Engine

final class ADIFLogTests: XCTestCase {
    func testBandMapping() {
        XCTAssertEqual(ADIFLog.band(forMHz: 14.074), "20m")
        XCTAssertEqual(ADIFLog.band(forMHz: 7.074), "40m")
        XCTAssertEqual(ADIFLog.band(forMHz: 28.074), "10m")
        XCTAssertEqual(ADIFLog.band(forMHz: 100.0), "")
    }

    func testRecordFields() {
        // 2026-06-17 01:15:30 UTC
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let date = cal.date(from: DateComponents(year: 2026, month: 6, day: 17,
                                                 hour: 1, minute: 15, second: 30))!
        let r = ADIFRecord(call: "v31dl", dateUTC: date, freqMHz: 14.074, mode: "FT8",
                           rstSent: "-10", rstRcvd: "-05", grid: "EK57",
                           myCall: "n6ack", myGrid: "cm97ah")
        let s = ADIFLog.record(r)
        XCTAssertTrue(s.contains("<CALL:5>V31DL "))
        XCTAssertTrue(s.contains("<QSO_DATE:8>20260617 "))
        XCTAssertTrue(s.contains("<TIME_ON:6>011530 "))
        XCTAssertTrue(s.contains("<BAND:3>20m "))
        XCTAssertTrue(s.contains("<RST_SENT:3>-10 "))
        XCTAssertTrue(s.contains("<RST_RCVD:3>-05 "))
        XCTAssertTrue(s.contains("<GRIDSQUARE:4>EK57 "))
        XCTAssertTrue(s.contains("<STATION_CALLSIGN:5>N6ACK "))
        XCTAssertTrue(s.contains("<MY_GRIDSQUARE:6>CM97AH "))
        XCTAssertTrue(s.hasSuffix("<EOR>\n"))
    }

    func testWorkedCallsRoundTrip() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ft8worked-\(UUID().uuidString).adi")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let date = Date(timeIntervalSince1970: 1_780_000_000)
        for call in ["V31DL", "k1abc"] {
            try ADIFLog.append(ADIFRecord(call: call, dateUTC: date, freqMHz: 14.074,
                                          mode: "FT8", rstSent: "-10", rstRcvd: "-05",
                                          myCall: "N6ACK", myGrid: "CM97"), to: tmp)
        }
        let worked = ADIFLog.workedCalls(from: tmp)
        XCTAssertTrue(worked.contains("V31DL"))
        XCTAssertTrue(worked.contains("K1ABC"))   // upper-cased
        XCTAssertFalse(worked.contains("W9XYZ"))
    }

    func testWorkedCallsEmptyWhenMissing() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("nope-\(UUID().uuidString).adi")
        XCTAssertTrue(ADIFLog.workedCalls(from: missing).isEmpty)
    }

    func testAppendCreatesHeaderThenAppends() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ft8test-\(UUID().uuidString).adi")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let date = Date(timeIntervalSince1970: 1_780_000_000)
        let r = ADIFRecord(call: "K1ABC", dateUTC: date, freqMHz: 14.074, mode: "FT8",
                           rstSent: "+00", rstRcvd: "-01", myCall: "N6ACK", myGrid: "CM97")
        try ADIFLog.append(r, to: tmp)
        try ADIFLog.append(r, to: tmp)
        let text = try String(contentsOf: tmp, encoding: .utf8)
        XCTAssertTrue(text.contains("<EOH>"))                      // header once
        XCTAssertEqual(text.components(separatedBy: "<EOH>").count, 2)
        XCTAssertEqual(text.components(separatedBy: "<EOR>").count, 3) // two records
    }
}
