import Foundation

/// Accumulates a stream of audio chunks into UTC-aligned FT8 slots.
///
/// FT8 slots start on UTC second boundaries (…:00, :15, :30, :45). Callers push
/// converted 12 kHz mono chunks as they arrive, tagged with the wall-clock time
/// at which the chunk *ended*; whenever a slot boundary is crossed the completed
/// slot is returned. This is the pure, hardware-free heart of live capture, so
/// it can be unit-tested without an audio device.
///
/// Partial slots (shorter than `minFillFraction` of a full slot — e.g. the first
/// slot when capture starts mid-window) are dropped rather than emitted.
public struct SlotAccumulator {
    public let sampleRate: Int
    public let slotSeconds: Double
    public let minFillFraction: Double

    private var currentSlot: Int?
    private var buffer: [Float] = []

    public init(sampleRate: Int, slotSeconds: Double = 15.0, minFillFraction: Double = 0.9) {
        self.sampleRate = sampleRate
        self.slotSeconds = slotSeconds
        self.minFillFraction = minFillFraction
    }

    private var fullSlotSamples: Int { Int(Double(sampleRate) * slotSeconds) }

    /// Index of the UTC slot containing `time`.
    public func slotIndex(at time: Date) -> Int {
        Int((time.timeIntervalSince1970 / slotSeconds).rounded(.down))
    }

    /// Add samples captured ending at `time`. Returns the just-completed slot if
    /// this push crossed a boundary, else `nil`.
    public mutating func add(_ samples: [Float], at time: Date) -> AudioSlot? {
        let idx = slotIndex(at: time)
        var completed: AudioSlot?

        if let cur = currentSlot {
            if idx != cur {
                if buffer.count >= Int(minFillFraction * Double(fullSlotSamples)) {
                    completed = AudioSlot(
                        index: cur,
                        samples: buffer,
                        sampleRate: sampleRate,
                        startTime: Date(timeIntervalSince1970: Double(cur) * slotSeconds))
                }
                buffer.removeAll(keepingCapacity: true)
                currentSlot = idx
            }
        } else {
            currentSlot = idx
        }

        buffer.append(contentsOf: samples)
        return completed
    }
}
