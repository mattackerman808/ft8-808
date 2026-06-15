import Foundation
import FT8Codec

/// Everything the UI needs to render after one slot is processed.
public struct SlotResult: Sendable {
    public let index: Int
    public let startTime: Date?
    public let messages: [FT8Message]
    /// Magnitude bars in `[0, 1]` across the FT8 passband, for the waterfall.
    public let spectrum: [Float]
    public let passband: ClosedRange<Float>
}

/// Orchestrates the receive path: pulls slots from an `AudioSource`, decodes
/// each with `FT8Codec`, computes a display spectrum, and emits `SlotResult`s.
///
/// Deliberately UI-agnostic — the TUI and (later) the macOS app both consume
/// the same `results(from:)` stream.
public struct DecodeEngine: Sendable {
    public var proto: FT8Protocol
    public var spectrumColumns: Int
    public var passband: ClosedRange<Float>

    public init(proto: FT8Protocol = .ft8,
                spectrumColumns: Int = 80,
                passband: ClosedRange<Float> = 200...3000) {
        self.proto = proto
        self.spectrumColumns = spectrumColumns
        self.passband = passband
    }

    public func results(from source: some AudioSource) -> AsyncStream<SlotResult> {
        AsyncStream { continuation in
            let task = Task {
                for await slot in source.slots() {
                    if Task.isCancelled { break }
                    let messages = (try? FT8Codec.decode(
                        samples: slot.samples,
                        sampleRate: slot.sampleRate,
                        protocol: proto)) ?? []
                    let bars = Spectrum.bars(
                        samples: slot.samples,
                        sampleRate: slot.sampleRate,
                        fMin: passband.lowerBound,
                        fMax: passband.upperBound,
                        columns: spectrumColumns)
                    continuation.yield(SlotResult(
                        index: slot.index,
                        startTime: slot.startTime,
                        messages: messages,
                        spectrum: bars,
                        passband: passband))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
