import XCTest
import FT8Codec
@testable import FT8808Engine

final class StandardMessagesTests: XCTestCase {

    func testStandardSet() {
        let m = StandardMessages(myCall: "N6ACK", myGrid: "CM97", dxCall: "W9BRT", reportSent: -15)
        XCTAssertEqual(m.replyGrid, "W9BRT N6ACK CM97")
        XCTAssertEqual(m.report,    "W9BRT N6ACK -15")
        XCTAssertEqual(m.rReport,   "W9BRT N6ACK R-15")
        XCTAssertEqual(m.rr73,      "W9BRT N6ACK RR73")
        XCTAssertEqual(m.seven3,    "W9BRT N6ACK 73")
        XCTAssertEqual(m.cq,        "CQ N6ACK CM97")
        XCTAssertEqual(m.all.count, 6)
    }

    func testReportFormatting() {
        XCTAssertEqual(StandardMessages.formatReport(-15), "-15")
        XCTAssertEqual(StandardMessages.formatReport(3), "+03")
        XCTAssertEqual(StandardMessages.formatReport(-5), "-05")
        XCTAssertEqual(StandardMessages.formatReport(0), "+00")
    }

    func testCQDirectiveAndCaseNormalization() {
        let m = StandardMessages(myCall: "n6ack", myGrid: "cm97nx", dxCall: "w9brt",
                                 reportSent: 0, cqDirective: "pota")
        XCTAssertEqual(m.cq, "CQ POTA N6ACK CM97")        // 4-char grid, upper-cased
        XCTAssertEqual(m.replyGrid, "W9BRT N6ACK CM97")
    }

    /// Every generated macro must be a valid, encodable FT8 message.
    func testGeneratedMessagesEncode() throws {
        let m = StandardMessages(myCall: "N6ACK", myGrid: "CM97", dxCall: "W9BRT", reportSent: -7)
        for text in m.all {
            let tones = try FT8Codec.encode(text)
            XCTAssertEqual(tones.count, 79, "‘\(text)’ should encode to 79 FT8 tones")
        }
    }
}

final class StationConfigTests: XCTestCase {

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ft8808-test-\(UUID().uuidString)/config.json")
    }

    func testRoundTrip() throws {
        let url = tempURL()
        var cfg = StationConfig(callsign: "N6ACK", grid: "CM97")
        cfg.rigSpec = "ftdx101d,/dev/cu.usbserial-0,38400"
        cfg.audioInput = "USB AUDIO"
        cfg.txDriveDb = -28
        cfg.txOffsetHz = 1400

        try ConfigStore.save(cfg, to: url)
        let loaded = ConfigStore.load(from: url)
        XCTAssertEqual(loaded, cfg)
        XCTAssertTrue(loaded.isStationSet)
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    func testMissingFileReturnsDefault() {
        let cfg = ConfigStore.load(from: tempURL())
        XCTAssertEqual(cfg, StationConfig())
        XCTAssertFalse(cfg.isStationSet)
    }

    /// A config.json written before the LoTW fields existed must still load
    /// (with LoTW defaulting off) — not fail to decode, which would silently
    /// wipe the saved station.
    func testLegacyConfigWithoutLoTWFieldsDecodes() throws {
        let url = tempURL()
        let legacy = """
        { "callsign": "N6ACK", "grid": "CM97AH", "txOffsetHz": 1500,
          "txDriveDb": -30, "proto": "ft8" }
        """
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try legacy.write(to: url, atomically: true, encoding: .utf8)
        let cfg = ConfigStore.load(from: url)
        XCTAssertEqual(cfg.callsign, "N6ACK")     // station survived
        XCTAssertEqual(cfg.grid, "CM97AH")
        XCTAssertFalse(cfg.lotwEnabled)           // new field defaulted, didn't throw
        XCTAssertNil(cfg.lotwLocation)
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    func testLoTWFieldsRoundTrip() throws {
        let url = tempURL()
        var cfg = StationConfig(callsign: "N6ACK", grid: "CM97AH")
        cfg.lotwEnabled = true
        cfg.lotwLocation = "Cypress"
        cfg.tqslPath = "/Applications/TrustedQSL/tqsl.app/Contents/MacOS/tqsl"
        try ConfigStore.save(cfg, to: url)
        XCTAssertEqual(ConfigStore.load(from: url), cfg)
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }
}
