import XCTest
@testable import FT8808Engine

final class FT8808EngineTests: XCTestCase {

    private func wavURL(_ name: String) throws -> URL {
        try XCTUnwrap(
            Bundle.module.url(forResource: name, withExtension: "wav", subdirectory: "Resources"),
            "missing resource \(name).wav"
        )
    }

    func testWavReaderParsesFormat() throws {
        let url = try wavURL("websdr_test14_12k")
        let (samples, rate) = try WavFileSource.readPCM16(url: url)
        XCTAssertEqual(rate, 12000)
        XCTAssertGreaterThan(samples.count, 12000 * 10) // at least 10 s of audio
        XCTAssertLessThanOrEqual(samples.map(abs).max() ?? 0, 1.0)
    }

    func testSpectrumIsNormalised() throws {
        let url = try wavURL("websdr_test14_12k")
        let (samples, rate) = try WavFileSource.readPCM16(url: url)
        let bars = Spectrum.bars(samples: samples, sampleRate: rate, columns: 64)
        XCTAssertEqual(bars.count, 64)
        XCTAssertTrue(bars.allSatisfy { $0 >= 0 && $0 <= 1 })
        XCTAssertGreaterThan(bars.max() ?? 0, 0.5) // a real signal has peaks
    }

    func testEngineDecodesSlots() async throws {
        let url = try wavURL("websdr_test14_12k")
        let engine = DecodeEngine()
        let source = WavFileSource(url: url)

        var total = 0
        var sawCQ = false
        for await result in engine.results(from: source) {
            total += result.messages.count
            if result.messages.contains(where: { $0.text.hasPrefix("CQ ") }) { sawCQ = true }
            XCTAssertEqual(result.spectrum.count, 80) // default columns
        }
        XCTAssertGreaterThanOrEqual(total, 10, "expected many decodes from the test recording")
        XCTAssertTrue(sawCQ)
    }
}
