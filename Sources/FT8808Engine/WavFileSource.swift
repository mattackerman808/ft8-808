import Foundation

/// Streams a 16-bit PCM WAV file as a sequence of FT8 slots.
///
/// Used for offline decode and for driving the TUI without live audio. Reads
/// the file's native sample rate (FT8 recordings are usually 12 kHz mono) and
/// chunks it into `slotSeconds`-long slots. If `channels > 1`, channel 0 is used.
public struct WavFileSource: AudioSource {
    public let url: URL
    public let slotSeconds: Double

    public enum WavError: Error, Equatable {
        case unreadable
        case notPCM16
        case malformed
    }

    public init(url: URL, slotSeconds: Double = 15.0) {
        self.url = url
        self.slotSeconds = slotSeconds
    }

    public func slots() -> AsyncStream<AudioSlot> {
        AsyncStream { continuation in
            guard let (samples, sampleRate) = try? Self.readPCM16(url: url) else {
                continuation.finish()
                return
            }
            let perSlot = max(1, Int(slotSeconds * Double(sampleRate)))
            var index = 0
            var pos = 0
            while pos < samples.count {
                let end = min(pos + perSlot, samples.count)
                let chunk = Array(samples[pos..<end])
                continuation.yield(AudioSlot(index: index, samples: chunk,
                                             sampleRate: sampleRate, startTime: nil))
                index += 1
                pos = end
            }
            continuation.finish()
        }
    }

    /// Minimal RIFF/WAVE reader for 16-bit integer PCM. Returns mono float samples.
    static func readPCM16(url: URL) throws -> (samples: [Float], sampleRate: Int) {
        guard let data = try? Data(contentsOf: url) else { throw WavError.unreadable }
        guard data.count > 44 else { throw WavError.malformed }

        func u32(_ o: Int) -> UInt32 {
            UInt32(data[o]) | UInt32(data[o+1]) << 8 | UInt32(data[o+2]) << 16 | UInt32(data[o+3]) << 24
        }
        func u16(_ o: Int) -> UInt16 { UInt16(data[o]) | UInt16(data[o+1]) << 8 }

        guard data[0] == 0x52, data[1] == 0x49, data[2] == 0x46, data[3] == 0x46, // "RIFF"
              data[8] == 0x57, data[9] == 0x41, data[10] == 0x56, data[11] == 0x45 // "WAVE"
        else { throw WavError.malformed }

        var channels = 1, sampleRate = 12000, bitsPerSample = 16
        var dataOffset = -1, dataLength = 0
        var o = 12
        while o + 8 <= data.count {
            let id0 = data[o], id1 = data[o+1], id2 = data[o+2], id3 = data[o+3]
            let size = Int(u32(o + 4))
            let body = o + 8
            if id0 == 0x66, id1 == 0x6D, id2 == 0x74, id3 == 0x20 { // "fmt "
                guard body + 16 <= data.count else { throw WavError.malformed }
                let format = u16(body)
                channels = Int(u16(body + 2))
                sampleRate = Int(u32(body + 4))
                bitsPerSample = Int(u16(body + 14))
                guard format == 1, bitsPerSample == 16 else { throw WavError.notPCM16 }
            } else if id0 == 0x64, id1 == 0x61, id2 == 0x74, id3 == 0x61 { // "data"
                dataOffset = body
                dataLength = min(size, data.count - body)
            }
            o = body + size + (size & 1) // chunks are word-aligned
        }

        guard dataOffset >= 0, channels >= 1 else { throw WavError.malformed }

        let bytesPerFrame = 2 * channels
        let frameCount = dataLength / bytesPerFrame
        var out = [Float](repeating: 0, count: frameCount)
        let scale: Float = 1.0 / 32768.0
        data.withUnsafeBytes { raw in
            let base = raw.baseAddress!.advanced(by: dataOffset)
            for i in 0..<frameCount {
                // Channel 0 only.
                let s = base.load(fromByteOffset: i * bytesPerFrame, as: Int16.self)
                out[i] = Float(Int16(littleEndian: s)) * scale
            }
        }
        return (out, sampleRate)
    }
}
