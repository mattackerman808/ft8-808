import Foundation
@preconcurrency import AVFoundation

/// Live real-time spectrum for a waterfall display. Owns a single raw-AUHAL
/// `AudioCaptureUnit` (12 kHz mono) and runs a `StreamingSpectrum` over it,
/// emitting `SpectrumFrame`s as fast as the configured hop allows.
///
/// This is the **display** path and is independent of decoding. Use only one
/// capture per input device at a time — running this alongside the decoder's
/// `LiveAudioSource` on the same device would open a second capture unit and
/// can wedge the codec (see CLAUDE.md). For the standalone waterfall that's a
/// non-issue; full-station integration will share one capture instead.
///
/// `@unchecked Sendable`: the capture callback runs on a real-time audio thread;
/// the `StreamingSpectrum` is touched only there, capture lifecycle is guarded
/// by `lock`, and frames are funneled through a thread-safe `AsyncStream`.
public final class LiveSpectrumSource: @unchecked Sendable {
    public enum LiveError: Error, CustomStringConvertible {
        case deviceNotFound(String)
        case micPermissionDenied
        case captureFailed(String)

        public var description: String {
            switch self {
            case let .deviceNotFound(q):  return "audio input device not found: \(q)"
            case .micPermissionDenied:    return "microphone permission denied — grant it in System Settings ▸ Privacy & Security ▸ Microphone"
            case let .captureFailed(m):   return "audio capture failed to start: \(m)"
            }
        }
    }

    private let targetRate: Double = 12_000
    private let deviceQuery: String?
    private let spectrum: StreamingSpectrum

    private let lock = NSLock()
    private var capture: AudioCaptureUnit?
    private var sink: (@Sendable (SpectrumFrame) -> Void)?

    /// Set if `frames()` finishes early so callers can report why.
    public private(set) var lastError: Error?

    public var binCount: Int { spectrum.binCount }
    public var binHz: Float { spectrum.binHz }
    public var fMin: Float { spectrum.fMin }
    public var fMax: Float { spectrum.fMax }

    /// - Parameters:
    ///   - device: input device UID or name substring; `nil` = system default.
    ///   - fftSize / hop / fMin / fMax: forwarded to `StreamingSpectrum`.
    public init(device: String? = nil, fftSize: Int = 2048, hop: Int = 256,
                fMin: Float = 200, fMax: Float = 3000) {
        self.deviceQuery = device
        self.spectrum = StreamingSpectrum(sampleRate: 12_000, fftSize: fftSize, hop: hop,
                                          fMin: fMin, fMax: fMax)
    }

    public func frames() -> AsyncStream<SpectrumFrame> {
        AsyncStream { continuation in
            Task {
                do {
                    try await self.start { continuation.yield($0) }
                    continuation.onTermination = { [weak self] _ in self?.stop() }
                } catch {
                    self.lastError = error
                    continuation.finish()
                }
            }
        }
    }

    public func stop() {
        lock.withLock {
            capture?.stop()
            capture = nil
            sink = nil
        }
    }

    private func start(yield: @escaping @Sendable (SpectrumFrame) -> Void) async throws {
        try await Self.requestMicPermission()
        lock.withLock { sink = yield }

        var deviceID: AudioDeviceID?
        if let q = deviceQuery {
            guard let dev = AudioDevices.find(q, scope: .input) else { throw LiveError.deviceNotFound(q) }
            deviceID = dev.id
        }

        let cap = AudioCaptureUnit(deviceID: deviceID, sampleRate: targetRate) { [weak self] samples in
            self?.process(samples)
        }
        do { try cap.start() } catch { throw LiveError.captureFailed("\(error)") }
        lock.withLock { capture = cap }
    }

    private func process(_ samples: [Float]) {
        // Collect under the lock (StreamingSpectrum is single-threaded), then
        // emit after unlocking so the continuation never runs under the lock.
        let (emit, frames): ((@Sendable (SpectrumFrame) -> Void)?, [SpectrumFrame]) = lock.withLock {
            guard let sink else { return (nil, []) }
            var out: [SpectrumFrame] = []
            spectrum.push(samples, at: Date()) { out.append($0) }
            return (sink, out)
        }
        if let emit { for f in frames { emit(f) } }
    }

    // MARK: - Permission

    private static func requestMicPermission() async throws {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return
        case .denied, .restricted:
            throw LiveError.micPermissionDenied
        case .notDetermined:
            if await AVCaptureDevice.requestAccess(for: .audio) { return }
            throw LiveError.micPermissionDenied
        @unknown default:
            return
        }
    }
}
