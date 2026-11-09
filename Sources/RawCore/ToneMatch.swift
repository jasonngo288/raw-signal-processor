import Foundation

/// Matching our render's tones to the camera's own HEIC from the same shutter press (cameraMatch plugin).
/// Pure Swift: works on luminance histograms of display-encoded Display P3 (as `Renderer.lumaHistogram` makes them),
/// so no pixel alignment between the RAW render and the HEIC is needed.
///
/// Two stages (prototype on the first device pair, WORK_LOG 2026-11-08):
/// 1. `exposureOffsetEV`: a global exposure difference on mid-tones, applied in the CIRAWFilter decode, so highlights
///    that are in the RAW but clip in our SDR decode come back (a curve after the decode cannot recover them).
/// 2. `curve` + `lut`: the remaining tone difference as a monotone luminance curve (quantile matching), applied as a
///    hue-preserving 3D LUT.
public enum ToneMatch {
    /// Encoded value below which `q` of the pixels lie (linear interpolation inside a bin). `hist` sums to ~1.
    public static func quantile(_ hist: [Double], _ q: Double) -> Double {
        let n = hist.count
        guard n > 0 else { return q }
        let total = hist.reduce(0, +)
        guard total > 0 else { return q }
        let target = min(max(q, 0), 1) * total
        var acc = 0.0
        for (i, h) in hist.enumerated() {
            if acc + h >= target, h > 0 {
                let f = (target - acc) / h
                return (Double(i) + f) / Double(n)
            }
            acc += h
        }
        return 1
    }

    /// Stops to add to our exposure so our mid-tones (quantiles 30–70 %) sit where the reference's do. Median of
    /// the per-quantile linear ratios, so a few lamps or a dark corner do not drive it. Bounded to `range`.
    public static func exposureOffsetEV(candidate: [Double], reference: [Double], range: ClosedRange<Double> = -1.0...0.5) -> Double {
        var d: [Double] = []
        for q in stride(from: 0.30, through: 0.701, by: 0.05) {
            let c = ColorMath.decodeTransfer(quantile(candidate, q)), r = ColorMath.decodeTransfer(quantile(reference, q))
            if c > 1e-4, r > 1e-4 { d.append(log2(r / c)) }
        }
        guard !d.isEmpty else { return 0 }
        d.sort()
        let m = d.count % 2 == 1 ? d[d.count / 2] : (d[d.count / 2 - 1] + d[d.count / 2]) / 2
        return min(max(m, range.lowerBound), range.upperBound)
    }

    /// Stops our deep shadows (quantiles 1–5 %) sit above the reference's once `exposureOffsetEV` is applied to ours.
    /// Positive = ours brighter. Median of the per-quantile linear ratios; 0 when the shadows are empty.
    public static func shadowGapEV(candidate: [Double], reference: [Double], exposureOffsetEV: Double) -> Double {
        var d: [Double] = []
        for q in [0.01, 0.02, 0.03, 0.05] {
            let c = ColorMath.decodeTransfer(quantile(candidate, q)) * pow(2, exposureOffsetEV), r = ColorMath.decodeTransfer(quantile(reference, q))
            if c > 1e-5, r > 1e-5 { d.append(log2(c / r)) }
        }
        guard !d.isEmpty else { return 0 }
        d.sort()
        return d.count % 2 == 1 ? d[d.count / 2] : (d[d.count / 2 - 1] + d[d.count / 2]) / 2
    }

    /// Apple's shadow boost scaled down by the shadow gap: kept below `+0.5` EV, zero at `+1.5` EV and beyond, linear
    /// between. Never raised (a darker-than-HEIC shadow is left to the curve).
    public static func shadowBoost(default d: Double, gapEV: Double) -> Double {
        let t = min(max((gapEV - 0.5) / 1.0, 0), 1)
        return d * (1 - t)
    }

    /// Monotone curve (encoded luma in → encoded luma out) taking candidate quantiles to reference quantiles.
    /// Each point's linear gain is limited to ±`maxStops`. Black stays at 0. The top is sampled densely (98.5, 99.5,
    /// 99.9 %) and the curve continues to x = 1 with slope ≤ 1: forcing (1,1) after a compressed last point stretched
    /// the top tones 2.3× and blew the wall's hotspot into a hard-edged white oval (CI 42491918370).
    public static func curve(candidate: [Double], reference: [Double], points: Int = 32, maxStops: Double = 1.5) -> [SIMD2<Double>] {
        var out: [SIMD2<Double>] = [SIMD2(0, 0)]
        let gMax = pow(2, maxStops)
        let qs = [0.005, 0.01, 0.02] + (1..<points).map { Double($0) / Double(points) } + [0.985, 0.995, 0.999]
        for q in qs {
            let x = quantile(candidate, q)
            guard x > out.last!.x + 1e-3, x < 0.999 else { continue }
            let lx = ColorMath.decodeTransfer(x), lr = ColorMath.decodeTransfer(quantile(reference, q))
            let g = lx > 1e-6 ? min(max(lr / lx, 1 / gMax), gMax) : 1
            // Slope ≤ 2 per segment: where our top quantiles bunch up (clipped area) the reference spreads them, and
            // a steep segment would posterise the highlight into a hard-edged patch.
            let y = min(max(ColorMath.encodeTransfer(lx * g), out.last!.y), out.last!.y + 2 * (x - out.last!.x), 0.999)
            out.append(SIMD2(x, y))
        }
        let last = out.last!
        out.append(SIMD2(1, min(1, last.y + (1 - last.x))))
        return out
    }

    /// How far the curve is from identity (max |y − x|): small values mean there is nothing to correct.
    public static func deviation(_ c: [SIMD2<Double>]) -> Double { c.map { abs($0.y - $0.x) }.max() ?? 0 }

    static func evaluate(_ c: [SIMD2<Double>], _ x: Double) -> Double {
        guard let hi = c.firstIndex(where: { $0.x >= x }) else { return c.last?.y ?? x }
        if hi == 0 { return c[0].y }
        let a = c[hi - 1], b = c[hi]
        return a.y + (b.y - a.y) * (x - a.x) / max(b.x - a.x, 1e-9)
    }

    /// The curve as a LUT: applied to luminance, colour scaled by the same ratio (hue kept), out-of-gamut colour
    /// pulled toward luma instead of clipped.
    public static func lut(_ c: [SIMD2<Double>], size: Int = 33) -> CubeLUT {
        let w = SIMD3<Float>(Float(ColorMath.p3LuminanceWeights.r), Float(ColorMath.p3LuminanceWeights.g), Float(ColorMath.p3LuminanceWeights.b))
        return CubeLUT.generate(size: size, title: "cameraMatch") { e in
            let y = max((e * w).sum(), 0)
            let yt = Float(evaluate(c, Double(y)))
            let r: Float = y > 1e-4 ? min(yt / y, 4) : 1
            let base = e * r + SIMD3(repeating: max(yt - y * r, 0))
            let yo = (base * w).sum()
            var chroma = base - SIMD3(repeating: yo)
            var t: Float = 1
            for i in 0..<3 {
                let v = chroma[i]
                if v > 0, yo + v > 1 { t = min(t, max(1 - yo, 0) / v) }
                if v < 0, yo + v < 0 { t = min(t, -yo / v) }
            }
            chroma *= max(t, 0)
            return SIMD3(repeating: yo) + chroma
        }
    }
}
