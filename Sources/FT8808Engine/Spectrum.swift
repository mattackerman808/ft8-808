import Foundation
import Accelerate

/// Computes a magnitude spectrum over an FT8 passband for waterfall display.
///
/// This is display-only and entirely separate from decoding (ft8_lib does its
/// own internal STFT). We average several Hann-windowed FFT frames across the
/// slot for a stable spectrum, then pool it down to `columns` bars normalised
/// to `[0, 1]`.
public enum Spectrum {

    /// - Parameters:
    ///   - samples: Mono audio for the slot.
    ///   - sampleRate: Hz.
    ///   - fMin/fMax: Passband to display (Hz).
    ///   - columns: Number of output bars (terminal width).
    /// - Returns: `columns` magnitudes in `[0, 1]`; empty if input is too short.
    public static func bars(samples: [Float], sampleRate: Int,
                            fMin: Float = 200, fMax: Float = 3000,
                            columns: Int = 80) -> [Float] {
        let fftSize = 4096
        guard samples.count >= fftSize, columns > 0, sampleRate > 0 else { return [] }

        let log2n = vDSP_Length(log2(Float(fftSize)))
        guard let fft = vDSP.FFT(log2n: log2n, radix: .radix2, ofType: DSPSplitComplex.self) else {
            return []
        }
        let half = fftSize / 2

        // Hann window, reused across frames.
        var window = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))

        // Average magnitudes over overlapping frames spanning the slot.
        let hop = fftSize / 2
        var accum = [Float](repeating: 0, count: half)
        var frames = 0

        var windowed = [Float](repeating: 0, count: fftSize)
        var realIn = [Float](repeating: 0, count: half)
        var imagIn = [Float](repeating: 0, count: half)
        var realOut = [Float](repeating: 0, count: half)
        var imagOut = [Float](repeating: 0, count: half)
        var mags = [Float](repeating: 0, count: half)

        var start = 0
        while start + fftSize <= samples.count {
            vDSP_vmul(Array(samples[start..<start + fftSize]), 1, window, 1, &windowed, 1, vDSP_Length(fftSize))

            // Pack real signal into split-complex (even -> real, odd -> imag).
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
                            vDSP_zvmags(&output, 1, &mags, 1, vDSP_Length(half))
                        }
                    }
                }
            }
            vDSP_vadd(accum, 1, mags, 1, &accum, 1, vDSP_Length(half))
            frames += 1
            start += hop
        }
        guard frames > 0 else { return [] }
        var inv = 1.0 / Float(frames)
        vDSP_vsmul(accum, 1, &inv, &accum, 1, vDSP_Length(half))

        // Convert to dB for perceptually useful scaling.
        var db = [Float](repeating: 0, count: half)
        var one: Float = 1e-12
        vDSP_vsadd(accum, 1, &one, &accum, 1, vDSP_Length(half))
        var ref: Float = 1
        vDSP_vdbcon(accum, 1, &ref, &db, 1, vDSP_Length(half), 0) // 0 => power

        // Pool the passband bins down to `columns` bars (max within each bucket).
        let binHz = Float(sampleRate) / Float(fftSize)
        let loBin = max(0, Int(fMin / binHz))
        let hiBin = min(half - 1, Int(fMax / binHz))
        guard hiBin > loBin else { return [] }

        var bars = [Float](repeating: 0, count: columns)
        for c in 0..<columns {
            let b0 = loBin + (hiBin - loBin) * c / columns
            let b1 = loBin + (hiBin - loBin) * (c + 1) / columns
            var peak = -Float.greatestFiniteMagnitude
            for b in b0...max(b0, min(b1, hiBin)) { peak = max(peak, db[b]) }
            bars[c] = peak
        }

        // Map to [0,1] so the noise floor reads dark and real signals light up
        // (green→yellow→red), the way a waterfall should. We use PERCENTILES of
        // the bars rather than min/max: a plain min→max stretch let the rig's
        // out-of-passband rolloff drag the bottom far down, which bunched the
        // in-band noise near the top and painted everything red.
        //
        //   floor = low percentile  → robust noise-floor estimate (maps to dark)
        //   peak  = high percentile → strong signals (map to the hot end)
        //
        // The top is adaptive so contrast fits the band automatically instead of
        // a fixed dB span (which left weak-but-present signals stuck in the
        // blue). `minSpanDB` keeps a dead-quiet band's bare noise from being
        // amplified into colour.
        let sorted = bars.sorted()
        let floorDB = sorted[sorted.count / 4]                       // 25th percentile
        let peakDB  = sorted[min(sorted.count - 1, sorted.count * 9 / 10)] // 90th percentile
        let minSpanDB: Float = 12
        let span = max(minSpanDB, peakDB - floorDB)
        return bars.map { max(0, min(1, ($0 - floorDB) / span)) }
    }
}
