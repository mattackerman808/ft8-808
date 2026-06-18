import Foundation
import CoreAudio

/// Live receive that drives BOTH the decoder and a real-time waterfall off a
/// **single** capture unit. The rig exposes one RX codec device; opening two
/// capture units on it can wedge the driver (see CLAUDE.md), so the decode-slot
/// path (`slots()` → `DecodeEngine`) and the spectrum path (`frames()` →
/// waterfall) share one `AudioCaptureUnit` here.
///
/// Capture starts lazily and idempotently when the first of `slots()`/`frames()`
/// is consumed; each block of mono samples is fed to both a `SlotAccumulator`
/// (15 s slots) and a `StreamingSpectrum` (continuous FFT frames).
///
/// `@unchecked Sendable`: the capture callback runs on the audio thread; shared
/// state is guarded by `lock`, and both streams are thread-safe `AsyncStream`s.
public final class LiveRadioSource: AudioSource, @unchecked Sendable {
    public enum LiveError: Error, CustomStringConvertible {
        case deviceNotFound(String)
        case captureFailed(String)
        var msg: String {
            switch self {
            case let .deviceNotFound(q): return "audio input device not found: \(q)"
            case let .captureFailed(m):  return "audio capture failed to start: \(m)"
            }
        }
        public var description: String { msg }
    }

    private let targetRate: Double = 12_000
    private let deviceQuery: String?

    private let lock = NSLock()
    private var capture: AudioCaptureUnit?
    private var resolvedDeviceID: AudioDeviceID?
    private var accumulator: SlotAccumulator
    private let spectrum: StreamingSpectrum
    private var slotSink: (@Sendable (AudioSlot) -> Void)?
    private var frameSink: (@Sendable (SpectrumFrame) -> Void)?
    private var started = false

    /// Set if a stream finishes early so callers can report why.
    public private(set) var lastError: Error?

    public var binCount: Int { spectrum.binCount }
    public var binHz: Float { spectrum.binHz }
    public var fMin: Float { spectrum.fMin }
    public var fMax: Float { spectrum.fMax }
    /// Exact spectrum-frame rate (deterministic: sampleRate / hop).
    public var framesPerSecond: Double { targetRate / Double(spectrum.hop) }

    /// - Parameters:
    ///   - device: input device UID or name substring; `nil` = system default.
    ///   - fftSize / hop / fMin / fMax: forwarded to `StreamingSpectrum`.
    public init(device: String? = nil, slotSeconds: Double = 15.0,
                fftSize: Int = 2048, hop: Int = 256, fMin: Float = 200, fMax: Float = 3000) {
        self.deviceQuery = device
        self.accumulator = SlotAccumulator(sampleRate: 12_000, slotSeconds: slotSeconds)
        self.spectrum = StreamingSpectrum(sampleRate: 12_000, fftSize: fftSize, hop: hop,
                                          fMin: fMin, fMax: fMax)
    }

    public func slots() -> AsyncStream<AudioSlot> {
        // Generous bound (slots are 15 s apart) so a stalled decoder can't grow
        // the buffer without limit overnight.
        AsyncStream(AudioSlot.self, bufferingPolicy: .bufferingNewest(8)) { continuation in
            Task {
                self.lock.withLock { self.slotSink = { continuation.yield($0) } }
                do { try await self.ensureStarted() }
                catch { self.lastError = error; continuation.finish(); return }
                continuation.onTermination = { [weak self] _ in
                    self?.lock.withLock { self?.slotSink = nil }
                }
            }
        }
    }

    public func frames() -> AsyncStream<SpectrumFrame> {
        // Bound the buffer and drop stale frames: a real-time waterfall only ever
        // wants the newest. Unbounded buffering let frames pile up without limit
        // whenever the consumer fell behind, growing memory + latency over time.
        AsyncStream(SpectrumFrame.self, bufferingPolicy: .bufferingNewest(2)) { continuation in
            Task {
                self.lock.withLock { self.frameSink = { continuation.yield($0) } }
                do { try await self.ensureStarted() }
                catch { self.lastError = error; continuation.finish(); return }
                continuation.onTermination = { [weak self] _ in
                    self?.lock.withLock { self?.frameSink = nil }
                }
            }
        }
    }

    public func stop() {
        lock.withLock {
            capture?.stop()
            capture = nil
            slotSink = nil
            frameSink = nil
            started = false
        }
    }

    private func ensureStarted() async throws {
        if lock.withLock({ started }) { return }
        try await MicPermission.request()

        var deviceID: AudioDeviceID?
        if let q = deviceQuery {
            guard let dev = AudioDevices.find(q, scope: .input) else { throw LiveError.deviceNotFound(q) }
            deviceID = dev.id
        }

        // Build + start under the lock with a double-check so concurrent
        // slots()/frames() callers open exactly one capture unit.
        try lock.withLock {
            if started { return }
            resolvedDeviceID = deviceID
            let cap = AudioCaptureUnit(deviceID: deviceID, sampleRate: targetRate) { [weak self] samples in
                self?.process(samples)
            }
            do { try cap.start() } catch { throw LiveError.captureFailed("\(error)") }
            capture = cap
            started = true
        }
    }

    /// Release the input device (e.g. before keying for tune). Streams stay open;
    /// `resume()` reopens capture. Per CLAUDE.md, do this only for tune, not for
    /// every message-TX.
    public func suspend() {
        lock.withLock { capture?.stop(); capture = nil }
    }

    @discardableResult
    public func resume() -> Bool {
        lock.withLock {
            guard started, capture == nil else { return started }
            let cap = AudioCaptureUnit(deviceID: resolvedDeviceID, sampleRate: targetRate) { [weak self] samples in
                self?.process(samples)
            }
            do { try cap.start(); capture = cap; return true }
            catch { lastError = error; return false }
        }
    }

    /// Audio thread. Feed both consumers; deliver to whichever stream is live.
    private func process(_ samples: [Float]) {
        let now = Date()
        let (slotEmit, frameEmit, slot, frames): (
            (@Sendable (AudioSlot) -> Void)?, (@Sendable (SpectrumFrame) -> Void)?,
            AudioSlot?, [SpectrumFrame]
        ) = lock.withLock {
            let completed = accumulator.add(samples, at: now)
            var out: [SpectrumFrame] = []
            spectrum.push(samples, at: now) { out.append($0) }
            return (slotSink, frameSink, completed, out)
        }
        if let slotEmit, let slot { slotEmit(slot) }
        if let frameEmit { for f in frames { frameEmit(f) } }
    }
}
