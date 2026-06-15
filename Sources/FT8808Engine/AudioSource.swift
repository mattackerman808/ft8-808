import Foundation

/// A source of audio slots feeding the decode engine.
///
/// This is the seam that lets the same engine run from a recorded WAV (offline,
/// testable, SSH-friendly), a directory of slot files, or live `AVAudioEngine`
/// capture — without the engine knowing which. Live sources align slots to UTC
/// 15 s boundaries; offline sources simply chunk their input.
public protocol AudioSource: Sendable {
    /// Emits slots until the source is exhausted (offline) or cancelled (live).
    func slots() -> AsyncStream<AudioSlot>
}
