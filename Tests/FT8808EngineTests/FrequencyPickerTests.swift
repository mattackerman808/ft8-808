import XCTest
@testable import FT8808Engine

final class FrequencyPickerTests: XCTestCase {
    private let band: ClosedRange<Float> = 200...3000
    private let cols = 80

    /// Map column index → its center frequency, matching the picker's math.
    private func freq(ofCol c: Int) -> Float {
        200 + (Float(c) + 0.5) / Float(cols) * 2800
    }
    private func col(ofFreq f: Float) -> Int {
        Int((f - 200) / 2800 * Float(cols))
    }

    func testPicksTheClearCentralNotch() {
        // Busy everywhere except a quiet notch right at band center (~1600 Hz).
        var map = [Float](repeating: 0.8, count: cols)
        for c in (col(ofFreq: 1500))...(col(ofFreq: 1700)) { map[c] = 0.0 }
        let hz = try? XCTUnwrap(FrequencyPicker.clearOffset(busyMap: map, passband: band))
        XCTAssertNotNil(hz)
        XCTAssertEqual(hz!, 1600, accuracy: 120)
    }

    func testIgnoresQuietRolloffEdge() {
        // The ONLY truly empty region is the far upper edge (past the usable
        // band) — everything usable is uniformly busier. Must NOT pick the edge.
        var map = [Float](repeating: 0.5, count: cols)
        for c in (col(ofFreq: 2750))..<cols { map[c] = 0.0 } // > usable hi (2700)
        let hz = FrequencyPicker.clearOffset(busyMap: map, passband: band)!
        XCTAssertLessThan(hz, 2700, "should stay out of the rolloff edge")
        XCTAssertGreaterThan(hz, 300)
    }

    func testFlatBandPicksCenter() {
        let map = [Float](repeating: 0.4, count: cols)
        let hz = FrequencyPicker.clearOffset(busyMap: map, passband: band)!
        // Usable center is (300 + 2700)/2 = 1500.
        XCTAssertEqual(hz, 1500, accuracy: 120)
    }

    func testPrefersCentralAmongEquallyQuiet() {
        // Two equally-empty notches: one central (~1500), one low-edge (~450).
        var map = [Float](repeating: 0.7, count: cols)
        for c in (col(ofFreq: 1450))...(col(ofFreq: 1550)) { map[c] = 0.0 }
        for c in (col(ofFreq: 400))...(col(ofFreq: 500)) { map[c] = 0.0 }
        let hz = FrequencyPicker.clearOffset(busyMap: map, passband: band)!
        XCTAssertEqual(hz, 1500, accuracy: 150, "should prefer the central clear slice")
    }

    func testTooSmallMapReturnsNil() {
        XCTAssertNil(FrequencyPicker.clearOffset(busyMap: [0, 0, 0], passband: band))
    }
}
