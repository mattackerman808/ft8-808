import FT8Codec
import Foundation

// Milestone 0 spike: decode an FT8 (or FT4) WAV from the command line.
//
//   swift run ft8decode path/to/slot.wav [--ft4]
//
// Output mimics WSJT-X's band-activity line: freq, time offset, ~SNR, text.

let args = CommandLine.arguments
guard args.count >= 2 else {
    FileHandle.standardError.write(Data("usage: ft8decode <file.wav> [--ft4]\n".utf8))
    exit(2)
}

let path = args[1]
let proto: FT8Protocol = args.contains("--ft4") ? .ft4 : .ft8

do {
    let messages = try FT8Codec.decode(wavPath: path, protocol: proto)
    if messages.isEmpty {
        print("No messages decoded.")
    } else {
        // Strongest first.
        for m in messages.sorted(by: { $0.score > $1.score }) {
            let snr = String(format: "%+5.1f", m.snrDb)
            let dt = String(format: "%+4.1f", m.timeSeconds)
            let freq = String(format: "%4.0f", m.frequencyHz)
            print("\(snr) dB  \(dt)s  \(freq) Hz  ~  \(m.text)")
        }
        print("\nDecoded \(messages.count) message(s).")
    }
} catch FT8CodecError.wavLoadFailed(let p) {
    FileHandle.standardError.write(Data("error: could not load WAV: \(p)\n".utf8))
    exit(1)
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}
