import Foundation
import Accelerate

/// One short-time FFT frame of the live passband, for a real-time waterfall.
///
/// Unlike `Spectrum.bars` (one averaged, self-normalised array per 15 s slot),
/// these stream continuously — one frame every `hop` samples — and carry **raw
/// power dB** so the renderer can apply its own slowly-adapting floor/span and
/// avoid per-frame flicker. `magnitudesDB[0]` is the lowest passband bin.
public struct SpectrumFrame: Sendable {
    public let magnitudesDB: [Float]   // power dB per bin, low → high frequency
    public let fMin: Float             // Hz of magnitudesDB[0]'s bin center-ish
    public let fMax: Float
    public let binHz: Float            // Hz per bin
    public let time: Date?             // wall-clock when this window ended

    public var binCount: Int { magnitudesDB.count }
}

/// Sliding-window short-time Fourier transform that emits a `SpectrumFrame`
/// every `hop` input samples. The data rate is `sampleRate / hop` frames/sec
/// (e.g. 12 kHz / 256 ≈ 47 fps); the display can redraw faster and interpolate.
///
/// Not thread-safe by itself — `push` is meant to be called from a single
/// producer (the audio capture thread). FFT work is a few thousand flops per
/// frame, comfortably real-time.
public final class StreamingSpectrum {
    public let sampleRate: Int
    public let fftSize: Int
    public let hop: Int
    public let fMin: Float
    public let fMax: Float
    public let binHz: Float

    private let loBin: Int
    private let hiBin: Int
    private let half: Int
    private let fft: vDSP.FFT<DSPSplitComplex>
    private var window: [Float]

    // Pending samples not yet consumed by a full window.
    private var pending: [Float] = []

    // Reusable scratch (single-threaded use).
    private var windowed: [Float]
    private var realIn: [Float]
    private var imagIn: [Float]
    private var realOut: [Float]
    private var imagOut: [Float]
    private var power: [Float]

    /// - Parameters:
    ///   - sampleRate: input rate (12 kHz for the FT8 capture path).
    ///   - fftSize: power-of-two window length. 2048 @ 12 kHz ≈ 5.9 Hz bins,
    ///     resolving FT8's 6.25 Hz tone spacing; window spans ≈ 171 ms.
    ///   - hop: samples advanced per frame. Smaller = more frames/sec (more
    ///     overlap). 256 ≈ 47 fps; 128 ≈ 94 fps.
    public init(sampleRate: Int = 12_000, fftSize: Int = 2048, hop: Int = 256,
                fMin: Float = 200, fMax: Float = 3000) {
        precondition(fftSize > 0 && (fftSize & (fftSize - 1)) == 0, "fftSize must be a power of two")
        self.sampleRate = sampleRate
        self.fftSize = fftSize
        self.hop = max(1, hop)
        self.fMin = fMin
        self.fMax = fMax
        self.half = fftSize / 2
        self.binHz = Float(sampleRate) / Float(fftSize)

        self.loBin = max(0, Int(fMin / binHz))
        self.hiBin = min(half - 1, Int(fMax / binHz))

        let log2n = vDSP_Length(log2(Float(fftSize)))
        self.fft = vDSP.FFT(log2n: log2n, radix: .radix2, ofType: DSPSplitComplex.self)!

        self.window = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))

        self.windowed = [Float](repeating: 0, count: fftSize)
        self.realIn = [Float](repeating: 0, count: half)
        self.imagIn = [Float](repeating: 0, count: half)
        self.realOut = [Float](repeating: 0, count: half)
        self.imagOut = [Float](repeating: 0, count: half)
        self.power = [Float](repeating: 0, count: half)
    }

    /// Number of bins each emitted frame carries.
    public var binCount: Int { max(0, hiBin - loBin + 1) }

    /// Feed captured mono samples; `emit` is called once per completed window.
    /// `time` is the wall-clock at the end of this sample block; per-frame times
    /// are back-dated by the samples still trailing the window.
    public func push(_ samples: [Float], at time: Date?, emit: (SpectrumFrame) -> Void) {
        guard binCount > 0 else { return }
        pending.append(contentsOf: samples)

        var start = 0
        while start + fftSize <= pending.count {
            transform(from: start)
            // Back-date this frame from `time`: samples after this window's end
            // still sit in `pending`.
            let trailing = pending.count - (start + fftSize)
            let frameTime = time.map { $0.addingTimeInterval(-Double(trailing) / Double(sampleRate)) }
            emit(makeFrame(time: frameTime))
            start += hop
        }
        if start > 0 { pending.removeFirst(start) }

        // Bound memory if a consumer ever stalls (shouldn't on the audio thread).
        if pending.count > fftSize * 8 {
            pending.removeFirst(pending.count - fftSize)
        }
    }

    private func transform(from start: Int) {
        pending.withUnsafeBufferPointer { buf in
            vDSP_vmul(buf.baseAddress! + start, 1, window, 1, &windowed, 1, vDSP_Length(fftSize))
        }
        windowed.withUnsafeBytes { raw in
            let cmplx = raw.bindMemory(to: DSPComplex.self).baseAddress!
            var split = DSPSplitComplex(realp: &realIn, imagp: &imagIn)
            vDSP_ctoz(cmplx, 2, &split, 1, vDSP_Length(half))
        }
        realOut.withUnsafeMutableBufferPointer { rOut in
            imagOut.withUnsafeMutableBufferPointer { iOut in
                realIn.withUnsafeMutableBufferPointer { rIn in
                    imagIn.withUnsafeMutableBufferPointer { iIn in
                        let input = DSPSplitComplex(realp: rIn.baseAddress!, imagp: iIn.baseAddress!)
                        var output = DSPSplitComplex(realp: rOut.baseAddress!, imagp: iOut.baseAddress!)
                        fft.forward(input: input, output: &output)
                        vDSP_zvmags(&output, 1, &power, 1, vDSP_Length(half)) // |X|^2
                    }
                }
            }
        }
    }

    private func makeFrame(time: Date?) -> SpectrumFrame {
        let n = binCount
        var db = [Float](repeating: 0, count: n)
        var floorPow: Float = 1e-12
        var ref: Float = 1
        // Add a tiny floor, then 10*log10(power) over the passband bins only.
        power.withUnsafeMutableBufferPointer { p in
            let base = p.baseAddress! + loBin
            vDSP_vsadd(base, 1, &floorPow, base, 1, vDSP_Length(n))
            vDSP_vdbcon(base, 1, &ref, &db, 1, vDSP_Length(n), 0) // 0 => power dB
        }
        return SpectrumFrame(magnitudesDB: db,
                             fMin: Float(loBin) * binHz,
                             fMax: Float(hiBin) * binHz,
                             binHz: binHz,
                             time: time)
    }
}
