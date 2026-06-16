import Foundation
import AudioToolbox
import CoreAudio

/// Transmit-audio output via a raw CoreAudio AUHAL output unit (the same low-
/// level path Qt/PortAudio use — and what WSJT-X relies on). This targets a
/// specific device directly with a single render callback, avoiding the
/// AVAudioEngine graph (source→mixer→output) whose multi-stage format
/// negotiation silently fails on some picky rig USB codecs.
public final class TxAudioOutput: @unchecked Sendable {
    public enum OutputError: Error, CustomStringConvertible {
        case deviceNotFound(String)
        case unitUnavailable
        case configFailed(String, OSStatus)

        public var description: String {
            switch self {
            case let .deviceNotFound(q):    return "audio output device not found: \(q)"
            case .unitUnavailable:          return "HAL output audio unit unavailable"
            case let .configFailed(m, s):   return "audio output \(m) failed (OSStatus \(s))"
            }
        }
    }

    fileprivate let source: AudioRenderSource
    private let toneGen: ToneGenerator?   // non-nil only for the tune-tone path
    private let sampleRate: Double
    private let deviceQuery: String?
    private var unit: AudioUnit?

    /// Tune-tone output: a continuous sine whose amplitude/frequency are
    /// adjustable live (drive calibration).
    public init(frequencyHz: Float = 1500, sampleRate: Double = 48_000, device: String? = nil) {
        self.sampleRate = sampleRate
        self.deviceQuery = device
        let tone = ToneGenerator(frequencyHz: frequencyHz, sampleRate: Float(sampleRate))
        self.toneGen = tone
        self.source = tone
    }

    /// Message output: stream a pre-synthesized waveform (a full FT8 slot) once.
    public init(player: WaveformPlayer, sampleRate: Double = 48_000, device: String? = nil) {
        self.sampleRate = sampleRate
        self.deviceQuery = device
        self.toneGen = nil
        self.source = player
    }

    /// True once a finite source (message waveform) has finished playing.
    public var isFinished: Bool { source.isFinished }

    public var amplitude: Float {
        get { toneGen?.amplitude ?? 0 }
        set { toneGen?.amplitude = newValue }
    }

    public func setFrequency(_ hz: Float) { toneGen?.setFrequency(hz) }

    public func start() throws {
        // Resolve the target device (nil = system default output).
        var deviceID: AudioDeviceID?
        if let q = deviceQuery {
            guard let dev = AudioDevices.find(q, scope: .output) else { throw OutputError.deviceNotFound(q) }
            deviceID = dev.id
        }

        var desc = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0, componentFlagsMask: 0)
        guard let comp = AudioComponentFindNext(nil, &desc) else { throw OutputError.unitUnavailable }
        var au: AudioUnit?
        var st = AudioComponentInstanceNew(comp, &au)
        guard st == noErr, let unit = au else { throw OutputError.configFailed("create", st) }

        func set(_ what: String, _ id: AudioUnitPropertyID, _ scope: AudioUnitScope,
                 _ element: AudioUnitElement, _ value: UnsafeRawPointer, _ size: UInt32) throws {
            let s = AudioUnitSetProperty(unit, id, scope, element, value, size)
            if s != noErr { AudioComponentInstanceDispose(unit); throw OutputError.configFailed(what, s) }
        }

        // Enable output (bus 0), disable input (bus 1).
        var enable: UInt32 = 1
        try set("enable output", kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0,
                &enable, UInt32(MemoryLayout<UInt32>.size))
        var disable: UInt32 = 0
        _ = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1,
                                 &disable, UInt32(MemoryLayout<UInt32>.size))

        // Target a specific device.
        if var dev = deviceID {
            try set("set device", kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                    &dev, UInt32(MemoryLayout<AudioDeviceID>.size))
        }

        // The format WE provide: mono Float32 @ sampleRate. The AUHAL's built-in
        // converter handles mono→device-channels and float→device-sample-type.
        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
            mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
        try set("set format", kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0,
                &asbd, UInt32(MemoryLayout<AudioStreamBasicDescription>.size))

        var cb = AURenderCallbackStruct(inputProc: txRenderCallback,
                                        inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        try set("set callback", kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0,
                &cb, UInt32(MemoryLayout<AURenderCallbackStruct>.size))

        st = AudioUnitInitialize(unit)
        guard st == noErr else { AudioComponentInstanceDispose(unit); throw OutputError.configFailed("initialize", st) }
        st = AudioOutputUnitStart(unit)
        guard st == noErr else {
            AudioUnitUninitialize(unit); AudioComponentInstanceDispose(unit)
            throw OutputError.configFailed("start", st)
        }
        self.unit = unit
    }

    public func stop() {
        guard let unit else { return }
        AudioOutputUnitStop(unit)
        AudioUnitUninitialize(unit)
        AudioComponentInstanceDispose(unit)
        self.unit = nil
    }

    fileprivate func render(into ioData: UnsafeMutablePointer<AudioBufferList>, frames: UInt32) {
        let abl = UnsafeMutableAudioBufferListPointer(ioData)
        for buffer in abl {
            guard let mData = buffer.mData else { continue }
            let ptr = mData.assumingMemoryBound(to: Float.self)
            source.render(UnsafeMutableBufferPointer(start: ptr, count: Int(frames)))
        }
    }
}

// Real-time render callback (C function pointer). Pulls the tone from the
// TxAudioOutput passed via the refcon.
private func txRenderCallback(inRefCon: UnsafeMutableRawPointer,
                              ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                              inTimeStamp: UnsafePointer<AudioTimeStamp>,
                              inBusNumber: UInt32,
                              inNumberFrames: UInt32,
                              ioData: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus {
    guard let ioData else { return noErr }
    let txo = Unmanaged<TxAudioOutput>.fromOpaque(inRefCon).takeUnretainedValue()
    txo.render(into: ioData, frames: inNumberFrames)
    return noErr
}
