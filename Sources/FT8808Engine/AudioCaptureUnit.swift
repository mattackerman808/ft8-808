import Foundation
import AudioToolbox
import CoreAudio
@preconcurrency import AVFoundation

/// Raw CoreAudio AUHAL **input** capture — the reliable low-level path (what
/// PortAudio/ffmpeg use). It targets a specific device directly and lets the
/// unit's built-in converter deliver mono Float32 at a chosen rate, sidestepping
/// AVAudioEngine's non-default-device `inputNode` format bug (it reports a stale
/// downstream format and delivers zero buffers, or fails to start with -10868).
public final class AudioCaptureUnit: @unchecked Sendable {
    public enum CaptureError: Error, CustomStringConvertible {
        case unitUnavailable
        case configFailed(String, OSStatus)

        public var description: String {
            switch self {
            case .unitUnavailable:        return "HAL input audio unit unavailable"
            case let .configFailed(m, s): return "audio input \(m) failed (OSStatus \(s))"
            }
        }
    }

    fileprivate let deviceID: AudioDeviceID?
    fileprivate let targetRate: Double          // rate delivered to the handler
    fileprivate let handler: @Sendable ([Float]) -> Void
    private var unit: AudioUnit?

    // HAL input units don't resample, so capture at the device rate (mono) and
    // resample to `targetRate` in software. Built in start() once the hardware
    // rate is known; used only on the audio thread.
    fileprivate var hwRate: Double = 0
    fileprivate var converter: AVAudioConverter?
    fileprivate var inFormat: AVAudioFormat?
    fileprivate var outFormat: AVAudioFormat?

    // Reusable receive scratch (audio thread only) to avoid per-callback alloc.
    fileprivate var scratch = [Float](repeating: 0, count: 16384)

    /// - Parameters:
    ///   - deviceID: input device, or `nil` for the system default input.
    ///   - sampleRate: rate to deliver mono samples at (e.g. 12000 for FT8).
    ///   - handler: called on the audio thread with each block of mono samples.
    public init(deviceID: AudioDeviceID?, sampleRate: Double,
                handler: @escaping @Sendable ([Float]) -> Void) {
        self.deviceID = deviceID
        self.targetRate = sampleRate
        self.handler = handler
    }

    public func start() throws {
        var desc = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0, componentFlagsMask: 0)
        guard let comp = AudioComponentFindNext(nil, &desc) else { throw CaptureError.unitUnavailable }
        var au: AudioUnit?
        var st = AudioComponentInstanceNew(comp, &au)
        guard st == noErr, let unit = au else { throw CaptureError.configFailed("create", st) }

        func set(_ what: String, _ id: AudioUnitPropertyID, _ scope: AudioUnitScope,
                 _ element: AudioUnitElement, _ value: UnsafeRawPointer, _ size: UInt32) throws {
            let s = AudioUnitSetProperty(unit, id, scope, element, value, size)
            if s != noErr { AudioComponentInstanceDispose(unit); throw CaptureError.configFailed(what, s) }
        }

        // Enable input (bus 1), disable output (bus 0).
        var enable: UInt32 = 1
        try set("enable input", kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1,
                &enable, UInt32(MemoryLayout<UInt32>.size))
        var disable: UInt32 = 0
        try set("disable output", kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0,
                &disable, UInt32(MemoryLayout<UInt32>.size))

        // Target a specific device (else the system default input is used).
        if var dev = deviceID {
            try set("set device", kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                    &dev, UInt32(MemoryLayout<AudioDeviceID>.size))
        }

        // Read the device's hardware input rate (input scope, element 1). HAL
        // input units do channel mixing but NOT sample-rate conversion, so we
        // capture mono at the hardware rate and resample to targetRate ourselves.
        var hwAsbd = AudioStreamBasicDescription()
        var hwSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        _ = AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat,
                                 kAudioUnitScope_Input, 1, &hwAsbd, &hwSize)
        hwRate = hwAsbd.mSampleRate > 0 ? hwAsbd.mSampleRate : 48_000

        // What we want delivered: mono Float32 at the hardware rate (channel mix
        // only) on the OUTPUT scope of the input element.
        var asbd = AudioStreamBasicDescription(
            mSampleRate: hwRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
            mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
        try set("set format", kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1,
                &asbd, UInt32(MemoryLayout<AudioStreamBasicDescription>.size))

        // Software resampler: hwRate mono → targetRate mono.
        if hwRate != targetRate,
           let inF = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: hwRate,
                                   channels: 1, interleaved: false),
           let outF = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: targetRate,
                                    channels: 1, interleaved: false) {
            inFormat = inF; outFormat = outF
            converter = AVAudioConverter(from: inF, to: outF)
        }

        var cb = AURenderCallbackStruct(inputProc: captureRenderCallback,
                                        inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        try set("set input callback", kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0,
                &cb, UInt32(MemoryLayout<AURenderCallbackStruct>.size))

        st = AudioUnitInitialize(unit)
        guard st == noErr else { AudioComponentInstanceDispose(unit); throw CaptureError.configFailed("initialize", st) }
        st = AudioOutputUnitStart(unit)
        guard st == noErr else {
            AudioUnitUninitialize(unit); AudioComponentInstanceDispose(unit)
            throw CaptureError.configFailed("start", st)
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

    /// Pull `frames` of captured mono audio from the unit and hand them off.
    fileprivate func capture(_ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                             _ ts: UnsafePointer<AudioTimeStamp>, _ frames: UInt32) -> OSStatus {
        guard let unit, frames > 0 else { return noErr }
        let n = Int(frames)
        if scratch.count < n { scratch = [Float](repeating: 0, count: n) }
        return scratch.withUnsafeMutableBufferPointer { buf -> OSStatus in
            var abl = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(mNumberChannels: 1,
                                      mDataByteSize: UInt32(n * 4),
                                      mData: buf.baseAddress))
            let st = AudioUnitRender(unit, flags, ts, 1 /* input bus */, frames, &abl)
            if st != noErr { return st }
            let mono = Array(UnsafeBufferPointer(start: buf.baseAddress, count: n))
            handler(resample(mono))
            return noErr
        }
    }

    /// Resample hardware-rate mono → targetRate mono (no-op if rates match).
    private func resample(_ input: [Float]) -> [Float] {
        guard let converter, let inFormat, let outFormat, !input.isEmpty else { return input }
        guard let inBuf = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: AVAudioFrameCount(input.count)),
              let chan = inBuf.floatChannelData else { return input }
        inBuf.frameLength = AVAudioFrameCount(input.count)
        input.withUnsafeBufferPointer { src in
            chan[0].update(from: src.baseAddress!, count: input.count)
        }
        let outCap = AVAudioFrameCount(Double(input.count) * targetRate / hwRate) + 16
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: outCap) else { return input }

        final class Feed: @unchecked Sendable { var done = false }
        let feed = Feed()
        var err: NSError?
        _ = converter.convert(to: outBuf, error: &err) { _, status in
            if feed.done { status.pointee = .noDataNow; return nil }
            feed.done = true; status.pointee = .haveData; return inBuf
        }
        guard let out = outBuf.floatChannelData, outBuf.frameLength > 0 else { return [] }
        return Array(UnsafeBufferPointer(start: out[0], count: Int(outBuf.frameLength)))
    }
}

// Real-time input callback (C function pointer). ioData is NULL for an input
// callback — we render into our own buffer inside `capture`.
private func captureRenderCallback(inRefCon: UnsafeMutableRawPointer,
                                   ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                                   inTimeStamp: UnsafePointer<AudioTimeStamp>,
                                   inBusNumber: UInt32,
                                   inNumberFrames: UInt32,
                                   ioData: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus {
    let cap = Unmanaged<AudioCaptureUnit>.fromOpaque(inRefCon).takeUnretainedValue()
    return cap.capture(ioActionFlags, inTimeStamp, inNumberFrames)
}
