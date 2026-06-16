import Foundation
import os

/// A real-time audio source the `TxAudioOutput` render callback pulls from.
/// Implementations must be safe to call on the audio thread (no allocation,
/// no locks held across the UI thread beyond a brief unfair lock).
public protocol AudioRenderSource: AnyObject, Sendable {
    /// Fill `out` with the next block of samples.
    func render(_ out: UnsafeMutableBufferPointer<Float>)
    /// True once the source has nothing left to play (a finite clip is done).
    /// Continuous sources (e.g. the tune tone) always return `false`.
    var isFinished: Bool { get }
}

/// Plays a pre-synthesized sample buffer exactly once (scaled by `amplitude`),
/// then emits silence and reports `isFinished`. Used to transmit a full FT8
/// slot: the GFSK waveform is rendered up front, then streamed to the rig's
/// codec by the AUHAL output. Device-free and unit-testable.
public final class WaveformPlayer: AudioRenderSource, @unchecked Sendable {
    private let samples: [Float]
    private let amplitude: Float
    private let pos = OSAllocatedUnfairLock(initialState: 0)

    public init(samples: [Float], amplitude: Float = 1) {
        self.samples = samples
        self.amplitude = max(0, min(1, amplitude))
    }

    public var isFinished: Bool { pos.withLock { $0 >= samples.count } }

    /// Fraction played so far, 0…1 (for a progress display).
    public var progress: Float {
        guard !samples.isEmpty else { return 1 }
        return pos.withLock { Float($0) } / Float(samples.count)
    }

    public func render(_ out: UnsafeMutableBufferPointer<Float>) {
        // Snapshot the cursor under the lock, fill outside it (the AUHAL calls
        // render serially on one thread), then publish the advanced cursor.
        let a = amplitude
        var p = pos.withLock { $0 }
        for i in out.indices {
            if p < samples.count { out[i] = samples[p] * a; p += 1 }
            else { out[i] = 0 }
        }
        let advanced = p
        pos.withLock { $0 = advanced }
    }
}
