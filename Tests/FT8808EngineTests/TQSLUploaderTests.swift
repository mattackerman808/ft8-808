import XCTest
@testable import FT8808Engine

final class TQSLUploaderTests: XCTestCase {
    // MARK: - Argument building

    func testUploadArgs() {
        let a = TQSLUploader.arguments(location: "Cypress", adifPath: "/tmp/log.adi")
        // Batch, no date dialog, dedup-compliant, upload, with location + file.
        XCTAssertEqual(a, ["-x", "-d", "-a", "compliant", "-l", "Cypress", "-u", "/tmp/log.adi"])
    }

    func testTestSignUsesZNotU() {
        let a = TQSLUploader.arguments(location: "Home", adifPath: "/tmp/log.adi", testSign: true)
        XCTAssertTrue(a.contains("-z"))
        XCTAssertFalse(a.contains("-u"))   // never contacts LoTW when test-signing
    }

    func testPasswordAndOutputArePassedThroughWhenSet() {
        let a = TQSLUploader.arguments(location: "Home", adifPath: "/tmp/log.adi",
                                       password: "secret", outputPath: "/tmp/out.tq8")
        XCTAssertTrue(a.contains("-p"))
        XCTAssertTrue(a.contains("secret"))
        XCTAssertTrue(a.contains("-o"))
        XCTAssertTrue(a.contains("/tmp/out.tq8"))
    }

    func testEmptyPasswordIsOmitted() {
        let a = TQSLUploader.arguments(location: "Home", adifPath: "/tmp/log.adi", password: "")
        XCTAssertFalse(a.contains("-p"))
    }

    // MARK: - Result interpretation

    func testInterpretSuccessWithRecordCount() {
        let out = """
        Signing using Callsign N6ACK
        /tmp/log.adi: wrote 1 records to /tmp/log.tq8
        Final Status: Success(0)
        """
        XCTAssertEqual(TQSLUploader.interpret(exitCode: 0, output: out), .uploaded(records: 1))
    }

    func testInterpretIgnoresDigitsInPath() {
        // The count is the integer before "records", not the "8808" in the path.
        let out = "/tmp/ft8808-it.adi: wrote 3 records to /tmp/ft8808-it.tq8\nFinal Status: Success(0)"
        XCTAssertEqual(TQSLUploader.interpret(exitCode: 0, output: out), .uploaded(records: 3))
    }

    func testInterpretZeroRecordsIsNothingNew() {
        let out = "wrote 0 records\nFinal Status: Success(0)"
        XCTAssertEqual(TQSLUploader.interpret(exitCode: 0, output: out), .nothingNew)
    }

    func testInterpretDuplicateExitCodeIsNothingNew() {
        // TQSL_EXIT_NO_QSOS — all QSOs already uploaded / out of range.
        XCTAssertEqual(TQSLUploader.interpret(exitCode: 8, output: ""), .nothingNew)
        XCTAssertEqual(TQSLUploader.interpret(exitCode: 9, output: ""), .nothingNew)
    }

    func testInterpretDuplicateTextIsNothingNew() {
        let out = "All QSOs are duplicates\nFinal Status: NoQSOs(8)"
        XCTAssertEqual(TQSLUploader.interpret(exitCode: 8, output: out), .nothingNew)
    }

    func testInterpretFailureSurfacesFinalStatus() {
        let out = "boom\nFinal Status: TQSL connection failed(11)"
        guard case .failure(let why) = TQSLUploader.interpret(exitCode: 11, output: out) else {
            return XCTFail("expected failure")
        }
        XCTAssertTrue(why.contains("connection failed"))
    }

    func testInterpretFailureFallsBackToLastLine() {
        let out = "something went wrong\n"
        guard case .failure(let why) = TQSLUploader.interpret(exitCode: 4, output: out) else {
            return XCTFail("expected failure")
        }
        XCTAssertEqual(why, "something went wrong")
    }

    // MARK: - Station-location parsing

    func testParseStationLocations() {
        let xml = """
        <StationDataFile>
          <StationData name="Cypress"><CALL>N6ACK</CALL></StationData>
          <StationData name="Field Day"><CALL>N6ACK/P</CALL></StationData>
        </StationDataFile>
        """
        XCTAssertEqual(TQSLUploader.parseStationLocations(from: xml), ["Cypress", "Field Day"])
    }

    func testParseStationLocationsEmptyAndDeduped() {
        XCTAssertEqual(TQSLUploader.parseStationLocations(from: "<StationDataFile/>"), [])
        let dup = #"<StationData name="Home"/><StationData name="Home"/>"#
        XCTAssertEqual(TQSLUploader.parseStationLocations(from: dup), ["Home"])
    }

    // MARK: - Binary resolution

    func testResolveBinaryHonorsValidOverride() {
        // /bin/sh is guaranteed executable on macOS; stands in for a real tqsl path.
        XCTAssertEqual(TQSLUploader.resolveBinary(override: "/bin/sh"), "/bin/sh")
    }

    func testResolveBinaryIgnoresBogusOverride() {
        // A non-existent override must not be returned (falls through to search).
        XCTAssertNotEqual(TQSLUploader.resolveBinary(override: "/no/such/tqsl"), "/no/such/tqsl")
    }
}
