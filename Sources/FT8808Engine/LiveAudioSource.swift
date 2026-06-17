import Foundation
@preconcurrency import AVFoundation
import CoreAudio

/// Live FT8 receive: captures from an input device via a raw CoreAudio AUHAL
/// unit (`AudioCaptureUnit`), which delivers 12 kHz mono, and emits UTC-aligned
/// 15 s slots via `SlotAccumulator`.
///
/// Capture deliberately uses the low-level AUHAL path rather than AVAudioEngine:
/// AVAudioEngine's `inputNode` mis-binds non-default devices (it reports a stale
/// downstream format and delivers zero buffers, or fails to start with -10868),
/// which silently broke receive on the rig's USB codec.
///
/// `@unchecked Sendable`: the capture callback runs on a real-time audio thread;
/// shared slot state is guarded by `lock`, and slot delivery is funneled through
/// a thread-safe `AsyncStream` continuation.
public final class LiveAudioSource: AudioSource, @unchecked Sendable {
    public enum LiveError: Error, CustomStringConvertible {
        case deviceNotFound(String)
        case micPermissionDenied
        case engineStartFailed(String)

        public var description: String {
            switch self {
            case let .deviceNotFound(q):    return "audio input device not found: \(q)"
            case .micPermissionDenied:      return "microphone permission denied — grant it in System Settings ▸ Privacy & Security ▸ Microphone"
            case let .engineStartFailed(m): return "audio capture failed to start: \(m)"
            }
        }
    }

    private let targetRate: Double = 12_000
    private let slotSeconds: Double
    private let deviceQuery: String?

    private let lock = NSLock()
    private var accumulator: SlotAccumulator
    private var capture: AudioCaptureUnit?

    /// - Parameter device: input device UID or name substring; `nil` = system default.
    public init(device: String? = nil, slotSeconds: Double = 15.0) {
        self.deviceQuery = device
        self.slotSeconds = slotSeconds
        self.accumulator = SlotAccumulator(sampleRate: 12_000, slotSeconds: slotSeconds)
    }

    public func slots() -> AsyncStream<AudioSlot> {
        AsyncStream { continuation in
            Task {
                do {
                    try await self.start { slot in continuation.yield(slot) }
                } catch {
                    self.lastError = error
                    continuation.finish()
                    return
                }
                continuation.onTermination = { [weak self] _ in self?.stop() }
            }
        }
    }

    /// Set after `slots()` finishes early so callers can report why.
    public private(set) var lastError: Error?

    private var yieldSlot: (@Sendable (AudioSlot) -> Void)?

    private func start(yield: @escaping @Sendable (AudioSlot) -> Void) async throws {
        try await requestMicPermission()
        yieldSlot = yield
        try startCapture(deviceID: resolveDeviceID())
    }

    /// Resolve the configured input device to a CoreAudio ID (nil = default).
    private func resolveDeviceID() throws -> AudioDeviceID? {
        guard let q = deviceQuery else { return nil }
        guard let dev = AudioDevices.find(q, scope: .input) else { throw LiveError.deviceNotFound(q) }
        return dev.id
    }

    private func startCapture(deviceID: AudioDeviceID?) throws {
        let cap = AudioCaptureUnit(deviceID: deviceID, sampleRate: targetRate) { [weak self] samples in
            self?.process(samples)
        }
        do { try cap.start() } catch { throw LiveError.engineStartFailed("\(error)") }
        capture = cap
    }

    private func process(_ samples: [Float]) {
        guard let yield = yieldSlot else { return }
        lock.lock()
        let completed = accumulator.add(samples, at: Date())
        lock.unlock()
        if let completed { yield(completed) }
    }

    /// Stop capturing and release the input device — call before tune so the TX
    /// output unit and capture don't fight over the codec. (Message-TX keeps
    /// capture running; the rig's RX and TX codec halves are separate devices.)
    public func suspend() {
        capture?.stop()
        capture = nil
    }

    /// Resume capturing after `suspend()`. `true` once running (or already was).
    @discardableResult
    public func resume() -> Bool {
        guard yieldSlot != nil else { return false }
        if capture != nil { return true }
        do {
            try startCapture(deviceID: try resolveDeviceID())
            return true
        } catch {
            lastError = error
            return false
        }
    }

    private func stop() {
        capture?.stop()
        capture = nil
        yieldSlot = nil
    }

    // MARK: - Permission

    private func requestMicPermission() async throws {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return
        case .denied, .restricted:
            throw LiveError.micPermissionDenied
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            if !granted { throw LiveError.micPermissionDenied }
        @unknown default:
            return
        }
    }
}
