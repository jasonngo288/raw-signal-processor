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
    public var candidate: ImageMetrics
    public var reference: ImageMetrics

    public static func compare(candidate: LinearImage, reference: LinearImage) throws -> ComparisonMetrics {
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
        let sorted = de.sorted()
        var uSum = 0.0, uN = 0
        for i in 0..<n where max(reference.pixels[i * 3], reference.pixels[i * 3 + 1], reference.pixels[i * 3 + 2]) < 0.98 {
            uSum += de[i]; uN += 1
        }
        return ComparisonMetrics(
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
            candidate: ImageMetrics.measure(candidate),
            reference: ImageMetrics.measure(reference))
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
