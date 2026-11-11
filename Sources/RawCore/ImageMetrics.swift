import Foundation

/// Reference-free image quality metrics. Defined on display-linear Display P3 at a fixed analysis
/// resolution so numbers are comparable across cameras and decoders (see docs/METRICS.md).
public struct ImageMetrics: Codable, Equatable, Sendable {
    /// 1st / 5th percentile of display luminance: how deep the blacks are (haze shows up here).
    public var blackP1: Double
    public var blackP5: Double
    /// Mean display luminance (overall brightness).
    public var meanY: Double
    /// Median display luminance.
    public var medianY: Double
    /// Fraction of pixels with any channel >= 0.98 (clipped / blown).
    public var clippedFraction: Double
    /// Std-dev of log2(Y) high-pass (sigma 2 px): perceived sharpness / local contrast.
    public var localContrast: Double
    /// Mean display luminance in a 5..40 px ring around clipped areas (halo / glow), nil if no clipping.
    public var highlightRingMeanY: Double?
    /// Mean chroma (CIELAB C*) as a saturation proxy.
    public var meanChroma: Double

    public static func measure(_ image: LinearImage) -> ImageMetrics {
        let n = image.pixelCount
        let y = image.displayLuminance()
        let sorted = y.sorted()
        func pct(_ p: Double) -> Double { Double(sorted[min(n - 1, Int((p / 100) * Double(n - 1)))]) }

        var sum = 0.0
        for v in y { sum += Double(v) }

        var clipped = [Bool](repeating: false, count: n)
        var clippedCount = 0
        var chromaSum = 0.0
        for i in 0..<n {
            let r = image.pixels[i * 3], g = image.pixels[i * 3 + 1], b = image.pixels[i * 3 + 2]
            if max(r, max(g, b)) >= 0.98 { clipped[i] = true; clippedCount += 1 }
            let lab = ColorMath.lab(r: Double(min(max(r, 0), 1)), g: Double(min(max(g, 0), 1)), b: Double(min(max(b, 0), 1)))
            chromaSum += hypot(lab.a, lab.b)
        }

        // Local contrast: log2 luminance minus its Gaussian blur.
        let logY = y.map { Float(log2(Double(max($0, 1e-4)))) }
        let blurred = gaussianBlur(logY, width: image.width, height: image.height, sigma: 2)
        var hpSum = 0.0, hpSq = 0.0
        for i in 0..<n {
            let d = Double(logY[i] - blurred[i])
            hpSum += d; hpSq += d * d
        }
        let hpMean = hpSum / Double(n)
        let localContrast = sqrt(max(0, hpSq / Double(n) - hpMean * hpMean))

        let ring = clippedCount > 0 ? ringMeanY(y, clipped: clipped, width: image.width, height: image.height) : nil

        return ImageMetrics(
            blackP1: pct(1), blackP5: pct(5), meanY: sum / Double(n), medianY: pct(50),
            clippedFraction: Double(clippedCount) / Double(n), localContrast: localContrast,
            highlightRingMeanY: ring, meanChroma: chromaSum / Double(n))
    }

    /// log2(Y) minus its Gaussian blur (sigma 2 px): the high-pass behind `localContrast`.
    static func highPassLog(_ y: [Float], width: Int, height: Int) -> [Float] {
        let logY = y.map { Float(log2(Double(max($0, 1e-4)))) }
        let b = gaussianBlur(logY, width: width, height: height, sigma: 2)
        return zip(logY, b).map { $0 - $1 }
    }

    /// Mean luminance in the 5..40 px ring (square) around `clipped` pixels; nil if the ring is empty.
    static func ringMeanY(_ y: [Float], clipped: [Bool], width: Int, height: Int) -> Double? {
        let mask = clipped.map { $0 ? Float(1) : 0 }
        let near = dilate(mask, width: width, height: height, radius: 5)
        let far = dilate(mask, width: width, height: height, radius: 40)
        var s = 0.0, c = 0
        for i in 0..<y.count where far[i] && !near[i] { s += Double(y[i]); c += 1 }
        return c > 0 ? s / Double(c) : nil
    }

    static func clippedMask(_ image: LinearImage) -> [Bool] {
        (0..<image.pixelCount).map { max(image.pixels[$0 * 3], image.pixels[$0 * 3 + 1], image.pixels[$0 * 3 + 2]) >= 0.98 }
    }

    /// Binary dilation with a square of the given radius, via separable running maxima.
    static func dilate(_ mask: [Float], width: Int, height: Int, radius: Int) -> [Bool] {
        var tmp = [Float](repeating: 0, count: mask.count)
        for y in 0..<height {
            for x in 0..<width {
                var m: Float = 0
                for xx in max(0, x - radius)...min(width - 1, x + radius) where mask[y * width + xx] > m { m = mask[y * width + xx] }
                tmp[y * width + x] = m
            }
        }
        var out = [Bool](repeating: false, count: mask.count)
        for y in 0..<height {
            for x in 0..<width {
                var m: Float = 0
                for yy in max(0, y - radius)...min(height - 1, y + radius) where tmp[yy * width + x] > m { m = tmp[yy * width + x] }
                out[y * width + x] = m > 0
            }
        }
        return out
    }
}

/// Pixel-aligned comparison against a reference render of the SAME raw file.
public struct ComparisonMetrics: Codable, Equatable, Sendable {
    public var deltaE00Mean: Double
    public var deltaE00Median: Double
    public var deltaE00P95: Double
    /// Mean ΔE00 over pixels the reference did NOT clip (any channel < 0.98): changes Apple got right.
    public var deltaE00MeanUnclipped: Double
    public var referenceUnclippedFraction: Double
    /// Halo ring of the candidate measured around the REFERENCE's clipped pixels, so both rings cover the
    /// same pixels. (The candidate's own ring moves when it recovers highlights; comparing those is meaningless.)
    public var candidateRingOnReferenceMask: Double?
    /// "Bright region" = pixels whose reference luminance is >= 0.6 (whites, sky, lit walls; clipped ones included).
    /// Mean luminance there (grey, flat whites read lower) and local contrast there (flat whites read lower).
    public var brightFraction: Double
    public var brightMeanYCandidate: Double?
    public var brightMeanYReference: Double?
    public var brightLocalContrastCandidate: Double?
    public var brightLocalContrastReference: Double?
    public var candidate: ImageMetrics
    public var reference: ImageMetrics

    /// Mean ΔE00 inside / outside `mask` (when a mask was given).
    public var deltaE00MeanMasked: Double? = nil
    public var deltaE00MeanOutsideMask: Double? = nil

    public static func compare(candidate: LinearImage, reference: LinearImage, mask: [Bool]? = nil) throws -> ComparisonMetrics {
        guard candidate.width == reference.width, candidate.height == reference.height else {
            throw RawCoreError.sizeMismatch(candidate: (candidate.width, candidate.height), reference: (reference.width, reference.height))
        }
        let n = candidate.pixelCount
        var de = [Double](repeating: 0, count: n)
        func clamp(_ v: Float) -> Double { Double(min(max(v, 0), 1)) }
        for i in 0..<n {
            let c = ColorMath.lab(r: clamp(candidate.pixels[i * 3]), g: clamp(candidate.pixels[i * 3 + 1]), b: clamp(candidate.pixels[i * 3 + 2]))
            let r = ColorMath.lab(r: clamp(reference.pixels[i * 3]), g: clamp(reference.pixels[i * 3 + 1]), b: clamp(reference.pixels[i * 3 + 2]))
            de[i] = ColorMath.deltaE2000(c.l, c.a, c.b, r.l, r.a, r.b)
        }
        if let mask, mask.count != n { throw RawCoreError.invalidSettings("mask has \(mask.count) entries, image \(n) pixels") }
        let sorted = de.sorted()
        var uSum = 0.0, uN = 0
        for i in 0..<n where max(reference.pixels[i * 3], reference.pixels[i * 3 + 1], reference.pixels[i * 3 + 2]) < 0.98 {
            uSum += de[i]; uN += 1
        }
        let yRef = reference.displayLuminance(), yCand = candidate.displayLuminance()
        let bright = yRef.map { $0 >= 0.6 }
        let nBright = bright.filter { $0 }.count
        func meanY(_ y: [Float]) -> Double? {
            guard nBright > 0 else { return nil }
            var s = 0.0; for i in 0..<n where bright[i] { s += Double(y[i]) }; return s / Double(nBright)
        }
        func lc(_ y: [Float]) -> Double? {
            guard nBright > 1 else { return nil }
            let hp = ImageMetrics.highPassLog(y, width: reference.width, height: reference.height)
            var s = 0.0, q = 0.0
            for i in 0..<n where bright[i] { s += Double(hp[i]); q += Double(hp[i] * hp[i]) }
            let m = s / Double(nBright)
            return sqrt(max(0, q / Double(nBright) - m * m))
        }
        var result = ComparisonMetrics(
            deltaE00Mean: de.reduce(0, +) / Double(n),
            deltaE00Median: sorted[n / 2],
            deltaE00P95: sorted[min(n - 1, Int(0.95 * Double(n - 1)))],
            deltaE00MeanUnclipped: uN > 0 ? uSum / Double(uN) : 0,
            referenceUnclippedFraction: Double(uN) / Double(n),
            candidateRingOnReferenceMask: {
                let mask = ImageMetrics.clippedMask(reference)
                return mask.contains(true) ? ImageMetrics.ringMeanY(candidate.displayLuminance(), clipped: mask,
                                                                     width: candidate.width, height: candidate.height) : nil
            }(),
            brightFraction: Double(nBright) / Double(n),
            brightMeanYCandidate: meanY(yCand), brightMeanYReference: meanY(yRef),
            brightLocalContrastCandidate: lc(yCand), brightLocalContrastReference: lc(yRef),
            candidate: ImageMetrics.measure(candidate),
            reference: ImageMetrics.measure(reference))
        if let mask {
            var a = 0.0, an = 0, b = 0.0, bn = 0
            for i in 0..<n { if mask[i] { a += de[i]; an += 1 } else { b += de[i]; bn += 1 } }
            result.deltaE00MeanMasked = an > 0 ? a / Double(an) : nil
            result.deltaE00MeanOutsideMask = bn > 0 ? b / Double(bn) : nil
        }
        return result
    }
}

/// Native-pixel sharpness metrics (docs/METRICS.md). Meant for full-resolution crops (scaleFactor 1): at a
/// 1024 px long edge a 12 MP file is downscaled ~4x and the sharpening Apple applies at native scale disappears.
/// Edge sites and the flat-area mask are taken from `reference` when given (the appleDefault crop), so the
/// candidate is measured on exactly the same pixels.
public struct SharpnessMetrics: Codable, Equatable, Sendable {
    /// Median over the strongest edges of (peak - plateau) / step, in percent; profile +-6 px along the gradient normal on log2 Y.
    /// Positive = halo / overshoot (sharpening); ~0 = soft edge. nil if the crop has no usable edge.
    public var edgeOvershootPercent: Double?
    public var edgeCount: Int
    /// Variance of log2 Y in the DoG band sigma 0.7-2 px.
    public var fineBandEnergy: Double
    /// Variance of log2 Y in the DoG band sigma 2-6 px.
    public var coarseBandEnergy: Double
    /// fine / coarse band energy: scale-free detail measure. Compare to the reference with `SharpnessComparison.hfRatio`.
    public var hfEnergy: Double { coarseBandEnergy > 0 ? fineBandEnergy / coarseBandEnergy : 0 }
    /// Std-dev of the log2 Y high-pass (sigma 2 px) over flat pixels (low gradient, Y 0.02...0.9): the waxy detector.
    /// nil if there are fewer than 1000 flat pixels.
    public var flatTexture: Double?
    public var flatPixelFraction: Double

    static let edgeMargin = 8
    static let profileRadius = 6

    static func logLuma(_ image: LinearImage) -> [Float] {
        image.displayLuminance().map { Float(log2(Double(max($0, 1e-4)))) }
    }

    struct EdgeSite { var x: Int; var y: Int; var nx: Float; var ny: Float }

    /// Strongest 1 % of the gradient magnitude (log2 Y blurred sigma 1), thinned to local maxima along the normal.
    static func edgeSites(_ logY: [Float], width: Int, height: Int) -> [EdgeSite] {
        let m = edgeMargin
        guard width > 2 * m + 2, height > 2 * m + 2 else { return [] }
        let b = gaussianBlur(logY, width: width, height: height, sigma: 1)
        var gx = [Float](repeating: 0, count: logY.count), gy = gx, mag = gx
        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                let i = y * width + x
                gx[i] = (b[i + 1] - b[i - 1]) / 2; gy[i] = (b[i + width] - b[i - width]) / 2
                mag[i] = (gx[i] * gx[i] + gy[i] * gy[i]).squareRoot()
            }
        }
        var inner: [Float] = []
        inner.reserveCapacity((width - 2 * m) * (height - 2 * m))
        for y in m..<(height - m) { for x in m..<(width - m) { inner.append(mag[y * width + x]) } }
        inner.sort()
        let thr = max(inner[min(inner.count - 1, Int(0.99 * Double(inner.count - 1)))], 0.05)
        var sites: [EdgeSite] = []
        for y in m..<(height - m) {
            for x in m..<(width - m) {
                let i = y * width + x
                let g = mag[i]
                guard g >= thr else { continue }
                let nx = gx[i] / g, ny = gy[i] / g
                let dx = Int((nx).rounded()), dy = Int((ny).rounded())
                if g >= mag[(y + dy) * width + x + dx], g > mag[(y - dy) * width + x - dx] { sites.append(EdgeSite(x: x, y: y, nx: nx, ny: ny)) }
            }
        }
        return sites
    }

    static func sample(_ p: [Float], width: Int, height: Int, x: Float, y: Float) -> Float {
        let x0 = min(max(Int(x.rounded(.down)), 0), width - 2), y0 = min(max(Int(y.rounded(.down)), 0), height - 2)
        let fx = x - Float(x0), fy = y - Float(y0)
        let a = p[y0 * width + x0], b = p[y0 * width + x0 + 1], c = p[(y0 + 1) * width + x0], d = p[(y0 + 1) * width + x0 + 1]
        return (a * (1 - fx) + b * fx) * (1 - fy) + (c * (1 - fx) + d * fx) * fy
    }

    /// (peak - plateau) / step for one site; nil if the step is under 0.25 log2 (0.25 EV).
    static func overshoot(_ logY: [Float], width: Int, height: Int, site: EdgeSite) -> Double? {
        let r = profileRadius
        var prof: [Float] = []   // t = -r...r along the normal (low side -> high side after the flip below)
        for t in -r...r {
            prof.append(sample(logY, width: width, height: height, x: Float(site.x) + Float(t) * site.nx, y: Float(site.y) + Float(t) * site.ny))
        }
        // The gradient points from dark to bright, so t > 0 is the bright side.
        let hi = (prof[r + 4] + prof[r + 5] + prof[r + 6]) / 3, lo = (prof[0] + prof[1] + prof[2]) / 3
        let step = hi - lo
        guard step >= 0.25 else { return nil }
        let peak = prof[r...].max() ?? hi, trough = prof[...r].min() ?? lo
        let over = max(0, peak - hi), under = max(0, lo - trough)
        return Double((over + under) / 2 / step)
    }

    static func flatMask(_ image: LinearImage, logY: [Float]) -> [Bool] {
        let w = image.width, h = image.height
        let b = gaussianBlur(logY, width: w, height: h, sigma: 2)
        let y = image.displayLuminance()
        var mask = [Bool](repeating: false, count: w * h)
        guard w > 2, h > 2 else { return mask }
        for yy in 1..<(h - 1) {
            for xx in 1..<(w - 1) {
                let i = yy * w + xx
                let gx = (b[i + 1] - b[i - 1]) / 2, gy = (b[i + w] - b[i - w]) / 2
                mask[i] = (gx * gx + gy * gy).squareRoot() < 0.02 && y[i] > 0.02 && y[i] < 0.9
            }
        }
        return mask
    }

    /// Measures `image`; edge sites and the flat mask come from `reference` (same size) when given, else from `image`.
    public static func measure(_ image: LinearImage, reference: LinearImage? = nil) -> SharpnessMetrics {
        let w = image.width, h = image.height
        let logY = logLuma(image)
        let refLog = reference.map(logLuma) ?? logY
        let refImage = reference ?? image

        let sites = edgeSites(refLog, width: w, height: h)
        let ov = sites.compactMap { overshoot(logY, width: w, height: h, site: $0) }.sorted()
        let overshootPct = ov.isEmpty ? nil : ov[ov.count / 2] * 100

        let g07 = gaussianBlur(logY, width: w, height: h, sigma: 0.7)
        let g2 = gaussianBlur(logY, width: w, height: h, sigma: 2)
        let g6 = gaussianBlur(logY, width: w, height: h, sigma: 6)
        var fine = 0.0, coarse = 0.0
        for i in 0..<logY.count {
            let f = Double(g07[i] - g2[i]), c = Double(g2[i] - g6[i])
            fine += f * f; coarse += c * c
        }
        let n = Double(logY.count)

        let mask = flatMask(refImage, logY: refLog)
        var s = 0.0, q = 0.0, cnt = 0
        for i in 0..<logY.count where mask[i] {
            let d = Double(logY[i] - g2[i]); s += d; q += d * d; cnt += 1
        }
        let flat: Double? = cnt >= 1000 ? sqrt(max(0, q / Double(cnt) - (s / Double(cnt)) * (s / Double(cnt)))) : nil
        return SharpnessMetrics(edgeOvershootPercent: overshootPct, edgeCount: ov.count, fineBandEnergy: fine / n, coarseBandEnergy: coarse / n,
                                flatTexture: flat, flatPixelFraction: Double(cnt) / n)
    }
}

/// Candidate vs the appleDefault crop of the same file.
public struct SharpnessComparison: Codable, Equatable, Sendable {
    public var candidate: SharpnessMetrics
    public var reference: SharpnessMetrics

    public init(candidate: SharpnessMetrics, reference: SharpnessMetrics) { self.candidate = candidate; self.reference = reference }

    public static func compare(candidate: LinearImage, reference: LinearImage) throws -> SharpnessComparison {
        guard candidate.width == reference.width, candidate.height == reference.height else {
            throw RawCoreError.sizeMismatch(candidate: (candidate.width, candidate.height), reference: (reference.width, reference.height))
        }
        return SharpnessComparison(candidate: .measure(candidate, reference: reference), reference: .measure(reference))
    }

    /// Candidate overshoot relative to the reference, in percent (-30 = 30 % less overshoot).
    public var overshootChangePercent: Double? {
        guard let c = candidate.edgeOvershootPercent, let r = reference.edgeOvershootPercent, r > 0 else { return nil }
        return (c / r - 1) * 100
    }
    /// hfEnergy(candidate) / hfEnergy(reference). 1 = same detail; 0.6-0.85 = calmer; < 0.5 = mush.
    public var hfRatio: Double? { reference.hfEnergy > 0 ? candidate.hfEnergy / reference.hfEnergy : nil }
    /// flatTexture(candidate) / flatTexture(reference), both on the reference's flat pixels.
    public var flatTextureRatio: Double? {
        guard let c = candidate.flatTexture, let r = reference.flatTexture, r > 0 else { return nil }
        return c / r
    }
}

/// Mean of several crops' comparisons (centre + 4 tiles): one row per variant in summary.md / summary.json.
public struct SharpnessSummary: Codable, Equatable, Sendable {
    public var crops: Int
    public var overshootPercent: Double?
    public var referenceOvershootPercent: Double?
    public var overshootChangePercent: Double?
    public var hfEnergy: Double
    public var hfRatio: Double?
    public var flatTexture: Double?
    public var flatTextureRatio: Double?

    public init(_ cs: [SharpnessComparison]) {
        func mean(_ v: [Double]) -> Double? { v.isEmpty ? nil : v.reduce(0, +) / Double(v.count) }
        crops = cs.count
        overshootPercent = mean(cs.compactMap(\.candidate.edgeOvershootPercent))
        referenceOvershootPercent = mean(cs.compactMap(\.reference.edgeOvershootPercent))
        overshootChangePercent = mean(cs.compactMap(\.overshootChangePercent))
        hfEnergy = mean(cs.map(\.candidate.hfEnergy)) ?? 0
        hfRatio = mean(cs.compactMap(\.hfRatio))
        flatTexture = mean(cs.compactMap(\.candidate.flatTexture))
        flatTextureRatio = mean(cs.compactMap(\.flatTextureRatio))
    }
}

public enum RawCoreError: Error, CustomStringConvertible {
    case sizeMismatch(candidate: (Int, Int), reference: (Int, Int))
    case unsupportedRaw(String)
    case unsupportedDecoderVersion(requested: String, supported: [String])
    case invalidSettings(String)
    case invalidLUT(String)
    case renderFailed(String)

    public var description: String {
        switch self {
        case let .sizeMismatch(c, r): return "Image size mismatch: candidate \(c.0)x\(c.1), reference \(r.0)x\(r.1)"
        case let .unsupportedRaw(p): return "Core Image cannot open RAW file: \(p)"
        case let .unsupportedDecoderVersion(v, s): return "Decoder version \(v) not supported for this file; supported: \(s.joined(separator: ", "))"
        case let .invalidSettings(m): return "Invalid settings: \(m)"
        case let .invalidLUT(m): return "Invalid LUT: \(m)"
        case let .renderFailed(m): return "Render failed: \(m)"
        }
    }
}
