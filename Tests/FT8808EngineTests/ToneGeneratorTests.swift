import XCTest
@testable import FT8808Engine

final class ToneGeneratorTests: XCTestCase {

    func testAmplitudeIsClamped() {
        let g = ToneGenerator(frequencyHz: 1000, sampleRate: 48_000)
        g.amplitude = 2.0
        XCTAssertEqual(g.amplitude, 1.0)
        g.amplitude = -0.5
        XCTAssertEqual(g.amplitude, 0.0)
    }

    func testZeroAmplitudeIsSilent() {
        let g = ToneGenerator(frequencyHz: 1000, sampleRate: 48_000)
        g.amplitude = 0
        let block = g.renderBlock(count: 2_000)
        XCTAssertEqual(block.map(abs).max() ?? 0, 0, accuracy: 1e-6)
    }

    func testPeakMatchesAmplitude() {
        let g = ToneGenerator(frequencyHz: 1000, sampleRate: 48_000)
        g.amplitude = 0.5
        let block = g.renderBlock(count: 48_000) // 1 s, many cycles
        XCTAssertEqual(block.max() ?? 0, 0.5, accuracy: 0.01)
        XCTAssertEqual(block.min() ?? 0, -0.5, accuracy: 0.01)
    }

    func testFrequencyFromZeroCrossings() {
        let freq: Float = 1000, sr: Float = 48_000
        let g = ToneGenerator(frequencyHz: freq, sampleRate: sr)
        g.amplitude = 1
        let block = g.renderBlock(count: Int(sr)) // exactly 1 s

        var upward = 0
        for i in 1..<block.count where block[i - 1] <= 0 && block[i] > 0 { upward += 1 }
        XCTAssertEqual(Float(upward), freq, accuracy: 5) // ~1000 cycles/s
    }

    func testPhaseIsContinuousAcrossBlocks() {
        // Rendering in two halves must equal rendering all at once.
        let a = ToneGenerator(frequencyHz: 1234, sampleRate: 48_000); a.amplitude = 1
        let b = ToneGenerator(frequencyHz: 1234, sampleRate: 48_000); b.amplitude = 1
        let whole = a.renderBlock(count: 4_000)
        let first = b.renderBlock(count: 1_500)
        let second = b.renderBlock(count: 2_500)
        XCTAssertEqual(whole, first + second)
    }
}
