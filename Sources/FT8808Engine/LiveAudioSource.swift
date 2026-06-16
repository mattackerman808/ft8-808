import Foundation
@preconcurrency import AVFoundation
import CoreAudio

/// Live FT8 receive: captures from an input device, resamples to 12 kHz mono,
/// and emits UTC-aligned 15 s slots via `SlotAccumulator`.
///
/// `@unchecked Sendable`: the AVAudioEngine tap runs on a single real-time audio
/// thread; shared state is guarded by `lock`, and slot delivery is funneled
/// through a thread-safe `AsyncStream` continuation.
public final class LiveAudioSource: AudioSource, @unchecked Sendable {
    public enum LiveError: Error, CustomStringConvertible {
        case deviceNotFound(String)
        case micPermissionDenied
        case engineStartFailed(String)
        case converterUnavailable

        public var description: String {
            switch self {
            case let .deviceNotFound(q):    return "audio input device not found: \(q)"
            case .micPermissionDenied:      return "microphone permission denied — grant it in System Settings ▸ Privacy & Security ▸ Microphone"
            case let .engineStartFailed(m): return "audio engine failed to start: \(m)"
            case .converterUnavailable:     return "could not create the 12 kHz audio converter"
            }
        }
    }

    private let targetRate: Double = 12_000
    private let slotSeconds: Double
    private let deviceQuery: String?

    private var engine = AVAudioEngine()   // rebuilt on resume (see resume())
    private let lock = NSLock()
    private var converter: AVAudioConverter?
    private var accumulator: SlotAccumulator
    private var outputFormat: AVAudioFormat!

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

        if let q = deviceQuery {
            guard let dev = AudioDevices.find(q) else { throw LiveError.deviceNotFound(q) }
            try setInputDevice(dev.id)
        }
        yieldSlot = yield
        try configureAndStart()
    }

    /// (Re)read the device format, build the converter, install the tap, and run.
    /// Reusable so capture can be resumed after a transmit suspend.
    private func configureAndStart() throws {
        let input = engine.inputNode
        let hwFormat = input.outputFormat(forBus: 0)
        guard hwFormat.sampleRate > 0 else {
            throw LiveError.engineStartFailed("input device reported no format (check permissions / device)")
        }

        guard let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                            sampleRate: targetRate, channels: 1, interleaved: false),
              let conv = AVAudioConverter(from: hwFormat, to: outFormat) else {
            throw LiveError.converterUnavailable
        }
        outputFormat = outFormat
        converter = conv

        let yield = yieldSlot
        input.installTap(onBus: 0, bufferSize: 4096, format: hwFormat) { [weak self] buffer, _ in
            guard let yield else { return }
            self?.process(buffer, yield: yield)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw LiveError.engineStartFailed(error.localizedDescription)
        }
    }

    /// Stop capturing and release the input device — call before transmitting so
    /// the TX output engine and capture don't fight over the rig's USB codec.
    public func suspend() {
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning { engine.stop() }
    }

    /// Resume capturing after `suspend()`. Rebuilds the engine from scratch — the
    /// TX engine reconfigured the shared codec, leaving the old engine in a state
    /// that asserts (an AVFoundation trap that `try?` can't catch). The slot
    /// accumulator continues; a straddling partial slot is dropped automatically.
    public func resume() {
        guard yieldSlot != nil, !engine.isRunning else { return }
        engine = AVAudioEngine()
        if let q = deviceQuery, let dev = AudioDevices.find(q) {
            try? setInputDevice(dev.id)
        }
        try? configureAndStart()
    }

    private func stop() {
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning { engine.stop() }
        yieldSlot = nil
    }

    private func process(_ inBuffer: AVAudioPCMBuffer, yield: @Sendable (AudioSlot) -> Void) {
        guard let samples = convert(inBuffer) else { return }
        lock.lock()
        let completed = accumulator.add(samples, at: Date())
        lock.unlock()
        if let completed { yield(completed) }
    }

    /// Resample one hardware buffer to 12 kHz mono `[Float]`.
    private func convert(_ inBuffer: AVAudioPCMBuffer) -> [Float]? {
        guard let converter, let outputFormat else { return nil }

        let ratio = targetRate / inBuffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(inBuffer.frameLength) * ratio) + 64
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return nil }

        // Feed the single input buffer exactly once. A reference box avoids the
        // "mutation of captured var in concurrent code" warning on the block.
        final class Feed: @unchecked Sendable { var done = false }
        let feed = Feed()
        var convError: NSError?
        let status = converter.convert(to: outBuffer, error: &convError) { _, outStatus in
            if feed.done {
                outStatus.pointee = .noDataNow
                return nil
            }
            feed.done = true
            outStatus.pointee = .haveData
            return inBuffer
        }

        guard status != .error, outBuffer.frameLength > 0,
              let chan = outBuffer.floatChannelData else { return nil }
        return Array(UnsafeBufferPointer(start: chan[0], count: Int(outBuffer.frameLength)))
    }

    // MARK: - macOS input-device selection

    private func setInputDevice(_ deviceID: AudioDeviceID) throws {
        guard let unit = engine.inputNode.audioUnit else { return }
        var dev = deviceID
        let st = AudioUnitSetProperty(unit,
                                      kAudioOutputUnitProperty_CurrentDevice,
                                      kAudioUnitScope_Global, 0,
                                      &dev, UInt32(MemoryLayout<AudioDeviceID>.size))
        if st != noErr {
            throw LiveError.engineStartFailed("could not select input device (OSStatus \(st))")
        }
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
