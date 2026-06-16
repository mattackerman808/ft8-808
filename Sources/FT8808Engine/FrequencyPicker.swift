import Foundation

/// Chooses a clear audio offset to transmit on, from a normalized "busy map"
/// (FFT magnitudes in `[0, 1]` per bin) spanning the passband.
///
/// "Quietest bin" alone is wrong: the band edges read empty only because they're
/// past the SSB filter rolloff, where there's no usable response. So we restrict
/// to a usable sub-band and, among slices essentially as quiet as the quietest,
/// prefer the one nearest band center — where activity is expected and the audio
/// response is flat.
public enum FrequencyPicker {
    public static func clearOffset(
        busyMap spec: [Float],
        passband: ClosedRange<Float>,
        signalWidthHz: Float = 50,
        edgeMarginLowHz: Float = 100,
        edgeMarginHighHz: Float = 300,
        quietMargin: Float = 0.08
    ) -> Float? {
        let cols = spec.count
        guard cols > 4 else { return nil }
        let lo = passband.lowerBound, hi = passband.upperBound
        let span = hi - lo
        guard span > 0 else { return nil }

        let win = max(2, Int((signalWidthHz / span) * Float(cols)))
        guard win <= cols else { return nil }

        let usableLo = lo + edgeMarginLowHz
        let usableHi = hi - edgeMarginHighHz
        guard usableHi > usableLo else { return nil }
        let bandCenter = (usableLo + usableHi) / 2

        func centerHz(at start: Int) -> Float {
            lo + ((Float(start) + Float(win) / 2) / Float(cols)) * span
        }

        var prefix = [Float](repeating: 0, count: cols + 1)
        for i in 0..<cols { prefix[i + 1] = prefix[i] + spec[i] }

        var candidates: [(start: Int, energy: Float)] = []
        for start in 0...(cols - win) {
            let f = centerHz(at: start)
            guard f >= usableLo, f <= usableHi else { continue }
            candidates.append((start, (prefix[start + win] - prefix[start]) / Float(win)))
        }
        guard let minE = candidates.map(\.energy).min() else { return nil }

        let pick = candidates
            .filter { $0.energy <= minE + quietMargin }
            .min { abs(centerHz(at: $0.start) - bandCenter) < abs(centerHz(at: $1.start) - bandCenter) }
            ?? candidates.min { $0.energy < $1.energy }

        return pick.map { centerHz(at: $0.start) }
    }
}
