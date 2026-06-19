import XCTest
@testable import FT8808Engine

final class FrequencyPickerTests: XCTestCase {
    private let band: ClosedRange<Float> = 200...3000
    private let usable: ClosedRange<Float> = 800...2000   // center = 1400
    private let cols = 80

    private func col(ofFreq f: Float) -> Int {
        Int((f - 200) / 2800 * Float(cols))
    }
    private func pick(_ map: [Float]) -> Float {
        FrequencyPicker.clearOffset(busyMap: map, passband: band, usable: usable)!
    }

    func testFlatBandPicksCenter() {
        let map = [Float](repeating: 0.4, count: cols)
        XCTAssertEqual(pick(map), 1400, accuracy: 120)
    }

    func testPicksCentralClearNotch() {
        // Busy everywhere except a clear notch right at center.
        var map = [Float](repeating: 0.8, count: cols)
        for c in col(ofFreq: 1350)...col(ofFreq: 1450) { map[c] = 0.0 }
        XCTAssertEqual(pick(map), 1400, accuracy: 130)
    }

    func testAvoidsSignalAtCenter() {
        // Clear band with a strong signal sitting on center — must step aside,
        // but stay close to center (not run to the edge).
        var map = [Float](repeating: 0.1, count: cols)
        for c in col(ofFreq: 1370)...col(ofFreq: 1430) { map[c] = 0.95 }
        let hz = pick(map)
        XCTAssertGreaterThan(abs(hz - 1400), 35, "should not transmit on the signal")
        XCTAssertLessThan(abs(hz - 1400), 300, "should stay near center")
    }

    func testStaysInUsableBand() {
        // Truly empty regions only OUTSIDE 800–2000; inside is uniformly busy.
        var map = [Float](repeating: 0.5, count: cols)
        for c in 0..<col(ofFreq: 800) { map[c] = 0.0 }
        for c in col(ofFreq: 2000)..<cols { map[c] = 0.0 }
        let hz = pick(map)
        XCTAssertGreaterThanOrEqual(hz, 800)
        XCTAssertLessThanOrEqual(hz, 2000)
        XCTAssertEqual(hz, 1400, accuracy: 150)
    }

    func testPrefersCentralAmongEqualNotches() {
        // Two equally clear notches: one central (~1400), one low (~950).
        var map = [Float](repeating: 0.7, count: cols)
        for c in col(ofFreq: 1350)...col(ofFreq: 1450) { map[c] = 0.0 }
        for c in col(ofFreq: 900)...col(ofFreq: 1000) { map[c] = 0.0 }
        XCTAssertEqual(pick(map), 1400, accuracy: 150)
    }

    func testPicksClearHighSpectrumOverBusyCenter() {
        // The screenshot case: low-mid band is busy, a clear stretch sits up high.
        // Centrality is only a tiebreaker, so we must move to the clear spectrum.
        let wide: ClosedRange<Float> = 500...2500
        var map = [Float](repeating: 0.6, count: cols)
        for c in col(ofFreq: 1900)...col(ofFreq: 2300) { map[c] = 0.05 }
        let hz = FrequencyPicker.clearOffset(busyMap: map, passband: band, usable: wide)!
        XCTAssertGreaterThan(hz, 1800, "should pick the clear high spectrum, not the busy center")
        XCTAssertLessThan(hz, 2400)
    }

    func testTooSmallMapReturnsNil() {
        XCTAssertNil(FrequencyPicker.clearOffset(busyMap: [0, 0, 0], passband: band, usable: usable))
    }
}
