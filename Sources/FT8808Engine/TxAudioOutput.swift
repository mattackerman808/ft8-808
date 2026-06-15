import Foundation
@preconcurrency import AVFoundation
import CoreAudio

/// Plays a continuous tone to a selectable output device (the rig's USB codec),
/// for transmit-audio calibration ("tune"). Amplitude is adjustable live.
///
/// This is also the foundation of the FT8 transmit path: the same engine +
/// output-device selection will later play synthesized FT8 audio instead of a
/// steady tone.
public final class TxAudioOutput: @unchecked Sendable {
    public enum OutputError: Error, CustomStringConvertible {
        case deviceNotFound(String)
        case engineStartFailed(String)
        case formatUnavailable

        public var description: String {
            switch self {
            case let .deviceNotFound(q):    return "audio output device not found: \(q)"
            case let .engineStartFailed(m): return "audio engine failed to start: \(m)"
            case .formatUnavailable:        return "could not create the output audio format"
            }
        }
    }

    private let engine = AVAudioEngine()
    private let generator: ToneGenerator
    private let sampleRate: Double
    private let deviceQuery: String?
    private var sourceNode: AVAudioSourceNode?

    public init(frequencyHz: Float = 1500, sampleRate: Double = 48_000, device: String? = nil) {
        self.sampleRate = sampleRate
        self.deviceQuery = device
        self.generator = ToneGenerator(frequencyHz: frequencyHz, sampleRate: Float(sampleRate))
    }

    /// Output level in `[0, 1]`. Safe to change while playing.
    public var amplitude: Float {
        get { generator.amplitude }
        set { generator.amplitude = newValue }
    }

    public func start() throws {
        if let q = deviceQuery {
            guard let dev = AudioDevices.find(q, scope: .output) else {
                throw OutputError.deviceNotFound(q)
            }
            try setOutputDevice(dev.id)
        }

        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else {
            throw OutputError.formatUnavailable
        }

        let gen = generator
        let src = AVAudioSourceNode(format: format) { _, _, frameCount, ablPtr -> OSStatus in
            let abl = UnsafeMutableAudioBufferListPointer(ablPtr)
            guard let mData = abl.first?.mData else { return noErr }
            let ptr = mData.assumingMemoryBound(to: Float.self)
            gen.render(UnsafeMutableBufferPointer(start: ptr, count: Int(frameCount)))
            return noErr
        }
        sourceNode = src

        engine.attach(src)
        engine.connect(src, to: engine.mainMixerNode, format: format)
        engine.prepare()
        do {
            try engine.start()
        } catch {
            throw OutputError.engineStartFailed(error.localizedDescription)
        }
    }

    public func stop() {
        if engine.isRunning { engine.stop() }
        if let src = sourceNode {
            engine.detach(src)
            sourceNode = nil
        }
    }

    private func setOutputDevice(_ id: AudioDeviceID) throws {
        guard let unit = engine.outputNode.audioUnit else { return }
        var dev = id
        let st = AudioUnitSetProperty(unit,
                                      kAudioOutputUnitProperty_CurrentDevice,
                                      kAudioUnitScope_Global, 0,
                                      &dev, UInt32(MemoryLayout<AudioDeviceID>.size))
        if st != noErr {
            throw OutputError.engineStartFailed("could not select output device (OSStatus \(st))")
        }
    }
}
