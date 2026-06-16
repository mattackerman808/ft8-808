import Foundation

/// Chooses a clear audio offset to transmit on, from a normalized "busy map"
/// (FFT magnitudes in `[0, 1]` per bin) spanning the passband.
///
/// "Quietest bin" alone is wrong on two counts: the band edges read empty only
/// because they're past the SSB filter rolloff (no usable response there), and
/// operators expect calls near band center. So we restrict to a `usable`
/// sub-band and score each slice by `energy + centerWeight · distanceFromCenter`,
/// taking the minimum — i.e. sit as central as possible, moving off only to
/// avoid an actual signal.
public enum FrequencyPicker {
    public static func clearOffset(
        busyMap spec: [Float],
        passband: ClosedRange<Float>,
        usable: ClosedRange<Float>,
        signalWidthHz: Float = 50,
        centerWeight: Float = 0.6
    ) -> Float? {
        let cols = spec.count
        guard cols > 4 else { return nil }
        let lo = passband.lowerBound, hi = passband.upperBound
        let span = hi - lo
        guard span > 0 else { return nil }

        let win = max(2, Int((signalWidthHz / span) * Float(cols)))
        guard win <= cols else { return nil }

        let usableLo = max(lo, usable.lowerBound)
        let usableHi = min(hi, usable.upperBound)
        guard usableHi > usableLo else { return nil }
        let bandCenter = (usableLo + usableHi) / 2
        let halfWidth = max(1, (usableHi - usableLo) / 2)

        func centerHz(at start: Int) -> Float {
            lo + ((Float(start) + Float(win) / 2) / Float(cols)) * span
        }

        var prefix = [Float](repeating: 0, count: cols + 1)
        for i in 0..<cols { prefix[i + 1] = prefix[i] + spec[i] }

        var bestStart = -1
        var bestScore = Float.greatestFiniteMagnitude
        for start in 0...(cols - win) {
            let f = centerHz(at: start)
            guard f >= usableLo, f <= usableHi else { continue }
            let energy = (prefix[start + win] - prefix[start]) / Float(win)
            let score = energy + centerWeight * (abs(f - bandCenter) / halfWidth)
            if score < bestScore { bestScore = score; bestStart = start }
        }
        return bestStart >= 0 ? centerHz(at: bestStart) : nil
    }
}
