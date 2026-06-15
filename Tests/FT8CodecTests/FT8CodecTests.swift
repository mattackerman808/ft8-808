import XCTest
@testable import FT8Codec

final class FT8CodecTests: XCTestCase {

    private func resourceURL(_ name: String) throws -> String {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: name, withExtension: "wav", subdirectory: "Resources"),
            "Missing test resource \(name).wav"
        )
        return url.path
    }

    /// A real on-air FT8 recording should decode to several messages.
    func testDecodesKnownRecording() throws {
        let path = try resourceURL("191111_110130")
        let messages = try FT8Codec.decode(wavPath: path)

        XCTAssertFalse(messages.isEmpty, "expected to decode at least one message")

        // Every message should have non-empty text and a plausible audio offset.
        for m in messages {
            XCTAssertFalse(m.text.isEmpty)
            XCTAssertGreaterThan(m.frequencyHz, 100)
            XCTAssertLessThan(m.frequencyHz, 3500)
        }

        // Sanity: many of these public recordings contain CQ calls.
        let hasCQ = messages.contains { $0.text.hasPrefix("CQ ") }
        XCTAssertTrue(hasCQ, "expected at least one CQ in: \(messages.map(\.text))")
    }

    func testInvalidInputThrows() {
        XCTAssertThrowsError(try FT8Codec.decode(samples: [], sampleRate: 12000))
    }

    func testMissingWavThrows() {
        XCTAssertThrowsError(try FT8Codec.decode(wavPath: "/nonexistent/file.wav")) { error in
            guard case FT8CodecError.wavLoadFailed = error else {
                return XCTFail("expected wavLoadFailed, got \(error)")
            }
        }
    }
}
