import XCTest
@testable import FT8Codec

/// The transmit path is proven without any RF: encode a message, synthesize its
/// GFSK audio, then decode that audio with our own decoder and check it matches.
final class EncodeRoundTripTests: XCTestCase {

    private func roundTrip(_ message: String, freq: Float = 1500, line: UInt = #line) throws {
        let audio = try FT8Codec.transmitAudio(message, baseFrequencyHz: freq)
        XCTAssertEqual(audio.count, 12_000 * 15, "expected a full 15 s slot", line: line)

        let decoded = try FT8Codec.decode(samples: audio, sampleRate: 12_000)
        let texts = decoded.map(\.text)
        XCTAssertTrue(texts.contains(message),
                      "round-trip failed: sent \"\(message)\", decoded \(texts)", line: line)

        // The recovered audio offset should be close to what we synthesized.
        if let m = decoded.first(where: { $0.text == message }) {
            XCTAssertEqual(m.frequencyHz, freq, accuracy: 10, line: line)
        }
    }

    func testCQRoundTrips() throws {
        try roundTrip("CQ K1ABC FN42")
    }

    func testReportRoundTrips() throws {
        try roundTrip("K1ABC W9XYZ -15")
    }

    func testRR73RoundTrips() throws {
        try roundTrip("W9XYZ K1ABC RR73")
    }

    func testDifferentAudioOffset() throws {
        try roundTrip("CQ K1ABC FN42", freq: 800)
    }

    func testEncodeRejectsGarbage() {
        // Lower-case junk that can't be packed as a standard/free message field.
        XCTAssertThrowsError(try FT8Codec.encode("this is not @ valid !! message"))
    }

    func testTonesAreInRange() throws {
        let tones = try FT8Codec.encode("CQ K1ABC FN42")
        XCTAssertEqual(tones.count, 79)         // FT8
        XCTAssertTrue(tones.allSatisfy { $0 <= 7 }) // 8-FSK
    }
}
