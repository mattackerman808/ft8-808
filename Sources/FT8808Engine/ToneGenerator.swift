import Foundation
import os

/// A continuous sine-tone generator with a live-adjustable amplitude.
///
/// Pure and device-free (the AVAudioEngine output node just calls `render`),
/// so the waveform is unit-testable without any audio hardware. Amplitude is
/// guarded by an unfair lock because it's read on the real-time audio thread
/// and written from the UI thread.
public final class ToneGenerator: @unchecked Sendable {
    private let phaseIncrement: Float
    private var phase: Float = 0
    private let amp = OSAllocatedUnfairLock(initialState: Float(0))

    public init(frequencyHz: Float, sampleRate: Float) {
        phaseIncrement = 2 * .pi * frequencyHz / sampleRate
    }

    /// Output amplitude, clamped to `[0, 1]`. 0 = silence.
    public var amplitude: Float {
        get { amp.withLock { $0 } }
        set { amp.withLock { $0 = max(0, min(1, newValue)) } }
    }

    /// Fill `out` with the next block of samples, advancing the phase.
    public func render(_ out: UnsafeMutableBufferPointer<Float>) {
        let a = amplitude
        var p = phase
        let twoPi = 2 * Float.pi
        for i in out.indices {
            out[i] = sinf(p) * a
            p += phaseIncrement
            if p >= twoPi { p -= twoPi }
        }
        phase = p
    }

    /// Convenience for tests: return `count` freshly rendered samples.
    public func renderBlock(count: Int) -> [Float] {
        var buf = [Float](repeating: 0, count: count)
        buf.withUnsafeMutableBufferPointer { render($0) }
        return buf
    }
}
