import Foundation

/// One time-slot's worth of mono audio, normalised to `[-1, +1]`.
///
/// For FT8 a slot is nominally 15 s. `startTime` is the UTC instant the slot
/// began when known (live capture); it is `nil` for offline/file sources where
/// wall-clock alignment is not meaningful.
public struct AudioSlot: Sendable {
    public let index: Int
    public let samples: [Float]
    public let sampleRate: Int
    public let startTime: Date?

    public init(index: Int, samples: [Float], sampleRate: Int, startTime: Date?) {
        self.index = index
        self.samples = samples
        self.sampleRate = sampleRate
        self.startTime = startTime
    }

    /// Slot duration in seconds.
    public var duration: Double {
        sampleRate > 0 ? Double(samples.count) / Double(sampleRate) : 0
    }
}
