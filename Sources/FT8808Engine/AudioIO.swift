import Foundation
@preconcurrency import AVFoundation
import CoreAudio

/// One AVAudioEngine that owns the rig's USB codec for BOTH directions:
///   • receive — input tap → resample to 12 kHz mono → UTC-aligned slots
///   • transmit — a tone/source node → the codec output (computer → rig)
///
/// A single engine on a single device avoids the dual-engine conflicts that
/// plagued the separate capture/output engines (no suspend/resume, no
/// device-reconfiguration crashes). RX↔TX is simply the tone amplitude
/// (0 = receive) plus PTT, which the caller controls.
///
/// `@unchecked Sendable`: the tap and the source-node render block run on
/// real-time audio threads; shared state is guarded by `lock` / the tone
/// generator's own lock, and slots are delivered through a thread-safe stream.
public final class AudioIO: AudioSource, @unchecked Sendable {
    public enum IOError: Error, CustomStringConvertible {
        case deviceNotFound(String)
        case micPermissionDenied
        case engineStartFailed(String)
        case formatUnavailable

        public var description: String {
            switch self {
            case let .deviceNotFound(q):    return "audio device not found: \(q)"
            case .micPermissionDenied:      return "microphone permission denied — System Settings ▸ Privacy & Security ▸ Microphone"
            case let .engineStartFailed(m): return "audio engine failed to start: \(m)"
            case .formatUnavailable:        return "could not create the audio format/converter"
            }
        }
    }

    private let targetRate: Double = 12_000
    private let toneRate: Double = 48_000
    private let slotSeconds: Double
    private let captureDevice: String?
    private let playbackDevice: String?

    private let engine = AVAudioEngine()
    private let toneGen: ToneGenerator
    private var sourceNode: AVAudioSourceNode?
    private var converter: AVAudioConverter?
    private var outFormat: AVAudioFormat!
    private let lock = NSLock()
    private var accumulator: SlotAccumulator
    private var yieldSlot: (@Sendable (AudioSlot) -> Void)?

    /// Set if `slots()` finishes early (e.g. permission denied) so callers can report why.
    public private(set) var lastError: Error?

    public init(captureDevice: String?, playbackDevice: String?,
                toneFrequencyHz: Float = 1500, slotSeconds: Double = 15.0) {
        self.captureDevice = captureDevice
        self.playbackDevice = playbackDevice ?? captureDevice
        self.slotSeconds = slotSeconds
        self.accumulator = SlotAccumulator(sampleRate: 12_000, slotSeconds: slotSeconds)
        self.toneGen = ToneGenerator(frequencyHz: toneFrequencyHz, sampleRate: Float(toneRate))
    }

    // MARK: - Transmit tone control (0 amplitude = receive / silent)

    public var toneAmplitude: Float {
        get { toneGen.amplitude }
        set { toneGen.amplitude = newValue }
    }

    public func setToneFrequency(_ hz: Float) { toneGen.setFrequency(hz) }

    // MARK: - AudioSource (receive)

    public func slots() -> AsyncStream<AudioSlot> {
        AsyncStream { continuation in
            Task {
                do {
                    try await self.requestMicPermission()
                    try self.start { continuation.yield($0) }
                } catch {
                    self.lastError = error
                    continuation.finish()
                    return
                }
                continuation.onTermination = { [weak self] _ in self?.stop() }
            }
        }
    }

    private func start(yield: @escaping @Sendable (AudioSlot) -> Void) throws {
        yieldSlot = yield

        // Point both input and output at the rig's codec — one device for I/O.
        if let q = captureDevice, let dev = AudioDevices.find(q, scope: .input) {
            try setDevice(dev.id, unit: engine.inputNode.audioUnit)
        }
        if let q = playbackDevice, let dev = AudioDevices.find(q, scope: .output) {
            try setDevice(dev.id, unit: engine.outputNode.audioUnit)
        }

        // Receive path: input tap → 12 kHz mono converter.
        let input = engine.inputNode
        let hwFormat = input.outputFormat(forBus: 0)
        guard hwFormat.sampleRate > 0 else {
            throw IOError.engineStartFailed("input device reported no format (permissions / device?)")
        }
        guard let outFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: targetRate, channels: 1, interleaved: false),
              let conv = AVAudioConverter(from: hwFormat, to: outFmt) else {
            throw IOError.formatUnavailable
        }
        outFormat = outFmt
        converter = conv
        input.installTap(onBus: 0, bufferSize: 4096, format: hwFormat) { [weak self] buffer, _ in
            self?.process(buffer, yield: yield)
        }

        // Transmit path: tone source node → mixer → output (silent until keyed).
        guard let toneFormat = AVAudioFormat(standardFormatWithSampleRate: toneRate, channels: 1) else {
            throw IOError.formatUnavailable
        }
        let gen = toneGen
        let src = AVAudioSourceNode(format: toneFormat) { _, _, frameCount, ablPtr -> OSStatus in
            let abl = UnsafeMutableAudioBufferListPointer(ablPtr)
            guard let mData = abl.first?.mData else { return noErr }
            gen.render(UnsafeMutableBufferPointer(start: mData.assumingMemoryBound(to: Float.self),
                                                  count: Int(frameCount)))
            return noErr
        }
        sourceNode = src
        engine.attach(src)
        engine.connect(src, to: engine.mainMixerNode, format: toneFormat)

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw IOError.engineStartFailed(error.localizedDescription)
        }
    }

    private func stop() {
        toneGen.amplitude = 0
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning { engine.stop() }
        if let src = sourceNode { engine.detach(src); sourceNode = nil }
        yieldSlot = nil
    }

    // MARK: - RX processing

    private func process(_ inBuffer: AVAudioPCMBuffer, yield: @Sendable (AudioSlot) -> Void) {
        guard let samples = convert(inBuffer) else { return }
        lock.lock()
        let completed = accumulator.add(samples, at: Date())
        lock.unlock()
        if let completed { yield(completed) }
    }

    private func convert(_ inBuffer: AVAudioPCMBuffer) -> [Float]? {
        guard let converter, let outFormat else { return nil }
        let ratio = targetRate / inBuffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(inBuffer.frameLength) * ratio) + 64
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { return nil }

        final class Feed: @unchecked Sendable { var done = false }
        let feed = Feed()
        var convError: NSError?
        let status = converter.convert(to: outBuffer, error: &convError) { _, outStatus in
            if feed.done { outStatus.pointee = .noDataNow; return nil }
            feed.done = true
            outStatus.pointee = .haveData
            return inBuffer
        }
        guard status != .error, outBuffer.frameLength > 0, let chan = outBuffer.floatChannelData else { return nil }
        return Array(UnsafeBufferPointer(start: chan[0], count: Int(outBuffer.frameLength)))
    }

    // MARK: - macOS device selection

    private func setDevice(_ deviceID: AudioDeviceID, unit: AudioUnit?) throws {
        guard let unit else { return }
        var dev = deviceID
        let st = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                      kAudioUnitScope_Global, 0,
                                      &dev, UInt32(MemoryLayout<AudioDeviceID>.size))
        if st != noErr {
            throw IOError.engineStartFailed("could not select audio device (OSStatus \(st))")
        }
    }

    // MARK: - Permission

    private func requestMicPermission() async throws {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return
        case .denied, .restricted:
            throw IOError.micPermissionDenied
        case .notDetermined:
            if !(await AVCaptureDevice.requestAccess(for: .audio)) { throw IOError.micPermissionDenied }
        @unknown default:
            return
        }
    }
}
