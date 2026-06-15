import XCTest
@testable import FT8808Engine

final class SlotAccumulatorTests: XCTestCase {

    private let rate = 12_000
    private let slot = 15.0

    /// A chunk that stays within one slot produces no completed slot.
    func testNoEmitWithinSlot() {
        var acc = SlotAccumulator(sampleRate: rate, slotSeconds: slot)
        let base = Date(timeIntervalSince1970: 1_000_000 * slot) // exact boundary
        let chunk = [Float](repeating: 0, count: rate) // 1 s
        XCTAssertNil(acc.add(chunk, at: base.addingTimeInterval(1)))
        XCTAssertNil(acc.add(chunk, at: base.addingTimeInterval(2)))
    }

    /// Crossing a boundary emits the completed slot with the right metadata.
    func testEmitsOnBoundaryCross() {
        var acc = SlotAccumulator(sampleRate: rate, slotSeconds: slot, minFillFraction: 0.5)
        let slotN = 1_000_000
        let base = Date(timeIntervalSince1970: Double(slotN) * slot)

        // Fill most of slot N (14 s of audio across 14 one-second chunks).
        var produced: AudioSlot?
        for s in 1...14 {
            let chunk = [Float](repeating: 0.1, count: rate)
            if let out = acc.add(chunk, at: base.addingTimeInterval(Double(s))) { produced = out }
        }
        XCTAssertNil(produced, "should not emit before the boundary")

        // Next chunk lands in slot N+1 → slot N completes.
        let crossing = acc.add([Float](repeating: 0.1, count: rate),
                               at: base.addingTimeInterval(slot + 0.1))
        let done = try? XCTUnwrap(crossing)
        XCTAssertEqual(done?.index, slotN)
        XCTAssertEqual(done?.sampleRate, rate)
        XCTAssertEqual(done?.startTime?.timeIntervalSince1970, Double(slotN) * slot)
        // ~14 s of audio accumulated before the boundary.
        XCTAssertEqual(Double(done?.samples.count ?? 0), 14 * Double(rate), accuracy: Double(rate))
    }

    /// A too-short (partial) slot is dropped, not emitted.
    func testDropsPartialSlot() {
        var acc = SlotAccumulator(sampleRate: rate, slotSeconds: slot, minFillFraction: 0.9)
        let slotN = 2_000_000
        let base = Date(timeIntervalSince1970: Double(slotN) * slot)
        // Only 3 s of audio, then cross the boundary.
        _ = acc.add([Float](repeating: 0, count: rate * 3), at: base.addingTimeInterval(3))
        let crossing = acc.add([Float](repeating: 0, count: rate),
                               at: base.addingTimeInterval(slot + 0.1))
        XCTAssertNil(crossing, "partial slot should be dropped")
    }
}
