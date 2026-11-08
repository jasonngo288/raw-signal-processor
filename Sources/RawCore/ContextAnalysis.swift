import Foundation

/// What the scene looks like. Pure-Swift statistics on small renders plus optional Vision results.
/// Inputs for `DecisionEngine`. Every field is recorded in the recipe of an `auto` render.
public struct SceneContext: Codable, Equatable, Sendable {
    /// Log2 luminance percentiles of the scene-linear render (stops; 0 = diffuse white).
    public var logP1: Double
    public var logP50: Double
    public var logP99: Double
    /// p99.9 − p1 in stops (p99.9 so lamps and sky are not cut away; earlier builds used p99).
    public var dynamicRangeStops: Double
    /// Fraction of pixels with any channel >= 0.98 in scene-linear: clipped by the sensor, not recoverable.
    public var clippedFraction: Double
    public var iso: Double?
    public var faceCount: Int?
    /// Top Vision classification labels with confidence >= 0.3.
    public var labels: [String: Double]?
    public var logP999: Double? = nil
    /// Fraction of pixels with any channel >= 0.98 in Apple's default render (what the user sees).
    public var displayClippedFraction: Double? = nil
    /// p99.9 of max(R,G,B) in an EDR decode (extendedDynamicRangeAmount 1). > 1 means highlight data
    /// above SDR white exists and can be tone-mapped back instead of clipping.
    public var edrHeadroom: Double? = nil
    /// Largest face as a fraction of the image area (Vision run at 1024 px).
    public var largestFaceArea: Double? = nil
    public var exposureTime: Double? = nil
    /// Share of the frame covered by people (Vision person segmentation, mean of the mask).
    public var personFraction: Double? = nil
    /// Union of Vision attention-saliency boxes, normalised [x, y, w, h] (origin bottom-left).
    public var saliencyBox: [Double]? = nil
    /// 64-bin histogram (GPU, CIAreaHistogram) of display-encoded luminance of the 512 px Apple render;
    /// encoded luminance ≈ log-like spacing of tones. Sums to 1.
    public var lumaHistogram: [Double]? = nil
    /// Correlated colour temperature / tint the camera's white balance chose (CIRAWFilter neutral defaults).
    public var cct: Double? = nil
    public var tint: Double? = nil

    /// Clipped by Apple's tone curve but present in the RAW.
    public var recoverableClippedFraction: Double? {
        displayClippedFraction.map { max(0, $0 - clippedFraction) }
    }

    public static func measure(sceneLinear img: LinearImage, iso: Double?) -> SceneContext {
        let y = img.pixelsLuminanceUnclamped()
        let logs = y.map { log2(Double(max($0, 1e-5))) }.sorted()
        func pct(_ p: Double) -> Double { logs[min(logs.count - 1, Int(p / 100 * Double(logs.count - 1)))] }
        var clipped = 0
        for i in 0..<img.pixelCount where max(img.pixels[i * 3], img.pixels[i * 3 + 1], img.pixels[i * 3 + 2]) >= 0.98 { clipped += 1 }
        return SceneContext(logP1: pct(1), logP50: pct(50), logP99: pct(99), dynamicRangeStops: pct(99.9) - pct(1),
                            clippedFraction: Double(clipped) / Double(img.pixelCount), iso: iso, faceCount: nil, labels: nil,
                            logP999: pct(99.9))
    }

    /// Fraction of pixels with any channel >= 0.98 (display-clamped render).
    public static func clippedFraction(_ img: LinearImage) -> Double {
        var c = 0
        for i in 0..<img.pixelCount where max(img.pixels[i * 3], img.pixels[i * 3 + 1], img.pixels[i * 3 + 2]) >= 0.98 { c += 1 }
        return Double(c) / Double(img.pixelCount)
    }

    /// p99.9 of max(R,G,B), at least 1.
    public static func headroom(_ img: LinearImage) -> Double {
        let m = (0..<img.pixelCount).map { max(img.pixels[$0 * 3], img.pixels[$0 * 3 + 1], img.pixels[$0 * 3 + 2]) }.sorted()
        return max(1, Double(m[min(m.count - 1, Int(0.999 * Double(m.count - 1)))]))
    }
}

extension LinearImage {
    public func pixelsLuminanceUnclamped() -> [Float] {
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

    /// Thresholds in one place so tuning is visible in diffs.
    public enum Threshold {
        public static let wideDynamicRange = 9.0
        public static let highISO = 800.0
        public static let faceArea = 0.01
        public static let personFraction = 0.03
        public static let skinProtection: Float = 0.5
    }

    public static func decide(context c: SceneContext, defaults d: DecodeParameters, support s: DecoderSupport,
                              base: RenderSettings = .explicit) -> Decision {
        var st = base
        st.mode = .explicit
        var why: [String] = []

        // Wide dynamic range: more local tone mapping, if this decoder allows it for the file.
        if c.dynamicRangeStops > Threshold.wideDynamicRange {
            if s.localToneMap {
                let extra = Float(min(0.25, (c.dynamicRangeStops - Threshold.wideDynamicRange) * 0.05))
                st.localToneMapAmount = min(1, d.localToneMapAmount + extra)
                why.append(String(format: "DR %.1f stops > %.0f -> localToneMap %.2f -> %.2f", c.dynamicRangeStops, Threshold.wideDynamicRange, d.localToneMapAmount, st.localToneMapAmount!))
            } else {
                why.append(String(format: "DR %.1f stops > %.0f but local tone map unsupported for this file/decoder", c.dynamicRangeStops, Threshold.wideDynamicRange))
            }
        }
        // High ISO: more luminance NR, less sharpening.
        if let iso = c.iso, iso >= Threshold.highISO {
            if s.luminanceNoiseReduction {
                st.luminanceNoiseReductionAmount = min(1, d.luminanceNoiseReductionAmount + 0.1)
                why.append("ISO \(Int(iso)) >= \(Int(Threshold.highISO)) -> luminanceNR +0.10")
            }
            if s.sharpness {
                st.sharpnessAmount = max(0, d.sharpnessAmount - 0.1)
                why.append("ISO \(Int(iso)) >= \(Int(Threshold.highISO)) -> sharpness -0.10")
            }
            if s.colorNoiseReduction {
                st.colorNoiseReductionAmount = min(1, d.colorNoiseReductionAmount + 0.1)
                why.append("ISO \(Int(iso)) >= \(Int(Threshold.highISO)) -> colorNR +0.10")
            }
        }
        // Lens correction: use it whenever the decoder can do it for this file.
        if s.lensCorrection && !d.lensCorrection {
            st.lensCorrection = true
            why.append("lens correction supported -> on")
        }
        // People in frame: hold part of the look back on them (skin protection through the Vision mask).
        let person = c.personFraction ?? 0, face = c.largestFaceArea ?? 0
        if st.skinProtection == nil, person >= Threshold.personFraction || face >= Threshold.faceArea {
            st.skinProtection = Threshold.skinProtection
            why.append(String(format: "people %.1f%% of frame, largest face %.1f%% -> skin protection %.2f", person * 100, face * 100, Threshold.skinProtection))
        }
        // Visible faces: avoid crunchy skin. Tiny faces (crowd, stage) are left alone.
        if let faces = c.faceCount, faces > 0, s.detail {
            if (c.largestFaceArea ?? 0) >= Threshold.faceArea {
                st.detailAmount = max(0, d.detailAmount - 0.1)
                why.append(String(format: "%d face(s), largest %.1f%% of frame -> detail -0.10", faces, (c.largestFaceArea ?? 1) * 100))
            } else {
                why.append(String(format: "%d small face(s) (largest %.2f%% of frame): detail kept", faces, (c.largestFaceArea ?? 0) * 100))
            }
        }
        if why.isEmpty { why.append("no rule fired: Apple defaults kept (explicit)") }
        return Decision(settings: st, reasons: why)
    }
}

/// Rule of the `highlightRecovery` plugin (pure, testable): where Apple's tone curve clips data the RAW still
/// holds, decode with EDR and tone-map that headroom back, blended only near white (see HighlightRecoveryPlugin).
public enum HighlightRecoveryRule {
    public static let displayClipped = 0.03
    public static let recoverable = 0.015
    public static let minHeadroom = 1.15
    public static let maxHeadroom = 16.0
    public static let headroomFraction = 1.0
    public static let clarity: Float = 0.4

    public static func decide(context c: SceneContext, settings: inout RenderSettings) -> [String] {
        guard let disp = c.displayClippedFraction, let rec = c.recoverableClippedFraction else { return [] }
        let head = c.edrHeadroom ?? 1
        if disp > displayClipped, rec > recoverable, head >= minHeadroom {
            settings.extendedDynamicRangeAmount = 1
            settings.toneMapSourceHeadroom = Float(min(1 + headroomFraction * (head - 1), maxHeadroom))
            settings.highlightClarity = clarity
            return [String(format: "display clipped %.1f%% (sensor %.1f%%, recoverable %.1f%%), EDR headroom %.2fx -> EDR 1 + tone-map %.2f -> 1, clarity %.2f",
                           disp * 100, c.clippedFraction * 100, rec * 100, head, settings.toneMapSourceHeadroom!, clarity)]
        }
        if disp > displayClipped {
            return [String(format: "display clipped %.1f%% but only %.1f%% recoverable / headroom %.2fx: kept (sensor clipping cannot be recovered)",
                           disp * 100, rec * 100, head)]
        }
        return []
    }
}
