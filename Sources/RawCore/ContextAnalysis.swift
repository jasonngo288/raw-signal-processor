import Foundation

/// What the scene looks like, measured on a scene-linear thumbnail (pure Swift) plus optional
/// Vision results. Inputs for `DecisionEngine`.
public struct SceneContext: Codable, Equatable, Sendable {
    /// Log2 luminance percentiles of the scene-linear render (stops; 0 = diffuse white).
    public var logP1: Double
    public var logP50: Double
    public var logP99: Double
    /// p99 - p1 in stops.
    public var dynamicRangeStops: Double
    /// Fraction of pixels with any channel >= 0.98 in scene-linear (sensor clipping proxy).
    public var clippedFraction: Double
    public var iso: Double?
    public var faceCount: Int?
    /// Top Vision classification labels with confidence >= 0.3.
    public var labels: [String: Double]?

    public static func measure(sceneLinear img: LinearImage, iso: Double?) -> SceneContext {
        let y = img.pixelsLuminanceUnclamped()
        let logs = y.map { log2(Double(max($0, 1e-5))) }.sorted()
        func pct(_ p: Double) -> Double { logs[min(logs.count - 1, Int(p / 100 * Double(logs.count - 1)))] }
        var clipped = 0
        for i in 0..<img.pixelCount where max(img.pixels[i * 3], img.pixels[i * 3 + 1], img.pixels[i * 3 + 2]) >= 0.98 { clipped += 1 }
        return SceneContext(logP1: pct(1), logP50: pct(50), logP99: pct(99), dynamicRangeStops: pct(99) - pct(1),
                            clippedFraction: Double(clipped) / Double(img.pixelCount), iso: iso, faceCount: nil, labels: nil)
    }
}

extension LinearImage {
    func pixelsLuminanceUnclamped() -> [Float] {
        (0..<pixelCount).map { ColorMath.luminance(r: max(pixels[$0 * 3], 0), g: max(pixels[$0 * 3 + 1], 0), b: max(pixels[$0 * 3 + 2], 0)) }
    }
}

/// Maps a `SceneContext` to small, bounded adjustments of Apple's per-file defaults.
/// Conservative by design: Apple's default render is the quality floor; every change is logged.
public enum DecisionEngine {
    public struct Decision: Codable, Equatable, Sendable {
        public var settings: RenderSettings
        public var reasons: [String]
    }

    public static func decide(context c: SceneContext, defaults d: DecodeParameters, support s: DecoderSupport,
                              base: RenderSettings = .explicit) -> Decision {
        var st = base
        st.mode = .explicit
        var why: [String] = []

        // High dynamic range: a bit more local tone mapping (bounded) to hold highlights and open shadows.
        if s.localToneMap, c.dynamicRangeStops > 9 {
            let extra = Float(min(0.25, (c.dynamicRangeStops - 9) * 0.05))
            st.localToneMapAmount = min(1, d.localToneMapAmount + extra)
            why.append(String(format: "DR %.1f stops > 9 -> localToneMap %.2f -> %.2f", c.dynamicRangeStops, d.localToneMapAmount, st.localToneMapAmount!))
        }
        // Clipped highlights: pull exposure slightly so the shoulder has room (never more than -0.3 EV).
        if c.clippedFraction > 0.02 {
            let ev = Float(-min(0.3, c.clippedFraction * 3))
            st.exposure = d.exposure + ev
            why.append(String(format: "clipped %.1f%% -> exposure %+.2f EV", c.clippedFraction * 100, ev))
        }
        // High ISO: more luminance NR, less sharpening.
        if let iso = c.iso, iso >= 800 {
            if s.luminanceNoiseReduction {
                st.luminanceNoiseReductionAmount = min(1, d.luminanceNoiseReductionAmount + 0.1)
                why.append("ISO \(Int(iso)) >= 800 -> luminanceNR +0.10")
            }
            if s.sharpness {
                st.sharpnessAmount = max(0, d.sharpnessAmount - 0.1)
                why.append("ISO \(Int(iso)) >= 800 -> sharpness -0.10")
            }
        }
        // Faces: avoid crunchy skin.
        if let faces = c.faceCount, faces > 0, s.detail {
            st.detailAmount = max(0, d.detailAmount - 0.1)
            why.append("\(faces) face(s) -> detail -0.10")
        }
        if why.isEmpty { why.append("no rule fired: Apple defaults kept (explicit)") }
        return Decision(settings: st, reasons: why)
    }
}

#if canImport(Vision) && canImport(CoreImage)
import CoreGraphics
import Vision

public enum VisionAnalyzer {
    /// Adds faces and classification labels. Failures (e.g. no ANE/GPU in CI) are swallowed and logged as nil.
    public static func enrich(_ ctx: inout SceneContext, image: CGImage) {
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        let faces = VNDetectFaceRectanglesRequest()
        let classify = VNClassifyImageRequest()
        do {
            try handler.perform([faces, classify])
            ctx.faceCount = faces.results?.count ?? 0
            var labels: [String: Double] = [:]
            for o in (classify.results ?? []) where o.confidence >= 0.3 { labels[o.identifier] = Double(o.confidence) }
            ctx.labels = labels
        } catch {
            ctx.faceCount = nil; ctx.labels = nil
        }
    }
}
#endif
