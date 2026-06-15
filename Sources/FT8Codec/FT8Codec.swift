import CFT8
import Foundation

/// A single decoded FT8/FT4 transmission.
public struct FT8Message: Sendable, Equatable {
    /// Decoded message text, e.g. `"CQ K1ABC FN42"`.
    public let text: String
    /// Audio frequency offset within the passband, in Hz.
    public let frequencyHz: Float
    /// Time offset of the message start within the slot, in seconds.
    public let timeSeconds: Float
    /// Costas synchronisation score (higher means a stronger candidate).
    public let score: Int
    /// Approximate SNR in dB. NOTE: currently a crude `score * 0.5` placeholder
    /// inherited from ft8_lib; a proper power-based estimate is a TODO.
    public let snrDb: Float
}

public enum FT8Protocol: Sendable {
    case ft8
    case ft4

    fileprivate var cValue: ft8808_protocol_t {
        switch self {
        case .ft8: return FT8808_PROTOCOL_FT8
        case .ft4: return FT8808_PROTOCOL_FT4
        }
    }
}

public enum FT8CodecError: Error, Equatable {
    /// The WAV file could not be loaded.
    case wavLoadFailed(path: String)
    /// The decoder rejected its inputs (empty buffer, bad params).
    case invalidInput
}

/// Swift-native facade over the vendored ft8_lib decoder.
///
/// This is the Milestone 0 surface: feed it samples (or a WAV) and get back
/// decoded messages. Encoding/transmit and the live audio path come later.
public enum FT8Codec {

    /// Decode FT8/FT4 messages from a block of mono float PCM samples in `[-1, +1]`.
    ///
    /// - Parameters:
    ///   - samples: Mono audio, normally 12 kHz, covering ~one 15 s slot.
    ///   - sampleRate: Sample rate of `samples` in Hz.
    ///   - protocol: Which protocol to decode (default `.ft8`).
    ///   - maxMessages: Upper bound on returned messages.
    public static func decode(
        samples: [Float],
        sampleRate: Int,
        protocol proto: FT8Protocol = .ft8,
        maxMessages: Int = 64
    ) throws -> [FT8Message] {
        guard !samples.isEmpty, sampleRate > 0, maxMessages > 0 else {
            throw FT8CodecError.invalidInput
        }

        var out = [ft8808_decoded_t](repeating: ft8808_decoded_t(), count: maxMessages)
        let count = samples.withUnsafeBufferPointer { buf in
            out.withUnsafeMutableBufferPointer { outBuf in
                ft8808_decode_samples(
                    buf.baseAddress,
                    Int32(samples.count),
                    Int32(sampleRate),
                    proto.cValue,
                    outBuf.baseAddress,
                    Int32(maxMessages)
                )
            }
        }

        guard count >= 0 else { throw FT8CodecError.invalidInput }
        return (0..<Int(count)).map { FT8Message(out[$0]) }
    }

    /// Decode FT8/FT4 messages from a 16-bit PCM WAV file.
    public static func decode(
        wavPath: String,
        protocol proto: FT8Protocol = .ft8,
        maxMessages: Int = 64
    ) throws -> [FT8Message] {
        guard maxMessages > 0 else { throw FT8CodecError.invalidInput }

        var out = [ft8808_decoded_t](repeating: ft8808_decoded_t(), count: maxMessages)
        let count = wavPath.withCString { cPath in
            out.withUnsafeMutableBufferPointer { outBuf in
                ft8808_decode_wav(cPath, proto.cValue, outBuf.baseAddress, Int32(maxMessages))
            }
        }

        if count == -1 { throw FT8CodecError.wavLoadFailed(path: wavPath) }
        guard count >= 0 else { throw FT8CodecError.invalidInput }
        return (0..<Int(count)).map { FT8Message(out[$0]) }
    }
}

private extension FT8Message {
    init(_ c: ft8808_decoded_t) {
        var c = c
        let capacity = MemoryLayout.size(ofValue: c.text)
        let text = withUnsafePointer(to: &c.text) {
            $0.withMemoryRebound(to: CChar.self, capacity: capacity) {
                String(cString: $0)
            }
        }
        self.init(
            text: text,
            frequencyHz: c.freq_hz,
            timeSeconds: c.time_sec,
            score: Int(c.score),
            snrDb: c.snr_db
        )
    }
}
