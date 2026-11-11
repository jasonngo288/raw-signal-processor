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
    /// Luminance histograms of the same-press camera HEIC (same measure as `lumaHistogram`; `…Fine` = 256 bins),
    /// stored at analysis time so cameraMatch does not need the HEIC file when the roll develops.
    public var cameraReferenceHistogram: [Double]? = nil
    public var cameraReferenceHistogramFine: [Double]? = nil
    /// Sky mask (plugin `skyMask`): algorithm version it was made with (nil = not made: plugin off or older analysis).
    public var skyMaskVersion: Int? = nil
    /// Fraction of the frame the sky mask covers (0 = the label gate said no sky, nil = no decision possible).
    public var skyFraction: Double? = nil
    /// Why the mask is what it is: the label that opened the gate and the heuristic coverage, or why it stayed empty.
    public var skyGate: String? = nil

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
        /// Scene-linear median (log2, 0 = diffuse white) below which a frame counts as dark / night.
        /// Midpoint of the gap between the tuning files only (holdout never used): darkest non-dark MTN01 −4.57,
        /// brightest dark CAFE01 −6.13 (NIGHT01 −6.36) → −5.35. Was −5.0, chosen with the holdout TOKYO01 in view.
        public static let darkMedianStops = -5.35
        public static let veryHighISO = 1600.0
        public static let landscapeLabelConfidence = 0.5
        public static let landscapeLabels: Set<String> = ["sky", "land", "mountain", "hill", "beach", "grass", "field", "sunset", "sunrise", "ocean", "lake", "forest"]
        public static let lookIntensityRange: ClosedRange<Float> = -0.15...0.10
    }

    /// Roadmap 13, context blending: how much of the (fixed) look this frame gets. Pure, bounded, every reason logged.
    public static func lookIntensityOffset(context c: SceneContext) -> (Float, [String]) {
        var off: Float = 0
        var why: [String] = []
        if c.logP50 < Threshold.darkMedianStops {
            off -= 0.10
            why.append(String(format: "dark scene (median %.2f stops < %.2f) -> look -0.10 (colour shifts and grain read as noise in the dark)", c.logP50, Threshold.darkMedianStops))
        }
        if let iso = c.iso, iso >= Threshold.veryHighISO {
            off -= 0.05
            why.append("ISO \(Int(iso)) >= \(Int(Threshold.veryHighISO)) -> look -0.05")
        }
        let people = (c.personFraction ?? 0) >= Threshold.personFraction || (c.largestFaceArea ?? 0) >= Threshold.faceArea
        if people {
            off -= 0.05
            why.append("people in frame -> look -0.05 (on top of skin protection)")
        } else if c.logP50 >= Threshold.darkMedianStops,
                  let hit = (c.labels ?? [:]).filter({ Threshold.landscapeLabels.contains($0.key) && $0.value >= Threshold.landscapeLabelConfidence }).max(by: { $0.value < $1.value }) {
            off += 0.05
            why.append(String(format: "landscape (%@ %.2f), no people -> look +0.05", hit.key, hit.value))
        }
        let r = Threshold.lookIntensityRange
        let clamped = min(max(off, r.lowerBound), r.upperBound)
        if clamped != off { why.append(String(format: "look offset %.2f clamped to %.2f", off, clamped)) }
        return (clamped, why)
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
        // Visible faces: avoid crunchy skin. Tiny faces (crowd, stage) are left alone. Detail first; on Bayer files
        // Apple's detail default is 0 (nothing to lower), so sharpness takes the -0.10 instead (was a dead rule).
        if let faces = c.faceCount, faces > 0 {
            let area = c.largestFaceArea ?? 0
            if area >= Threshold.faceArea {
                if s.detail, d.detailAmount >= 0.1 {
                    st.detailAmount = max(0, d.detailAmount - 0.1)
                    why.append(String(format: "%d face(s), largest %.1f%% of frame -> detail -0.10", faces, area * 100))
                } else if s.sharpness {
                    let cur = st.sharpnessAmount ?? d.sharpnessAmount
                    st.sharpnessAmount = max(0, cur - 0.1)
                    why.append(String(format: "%d face(s), largest %.1f%% of frame, detail default %.2f (nothing to lower) -> sharpness %.2f -> %.2f", faces, area * 100, d.detailAmount, cur, st.sharpnessAmount!))
                }
            } else {
                why.append(String(format: "%d small face(s) (largest %.2f%% of frame): sharpness/detail kept", faces, area * 100))
            }
        }
        // Look intensity from the scene (only matters when a look/stock is applied; the caller can lock it with 0).
        if st.lookIntensityOffset == nil {
            let (off, r) = lookIntensityOffset(context: c)
            if off != 0 { st.lookIntensityOffset = off; why += r }
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


/// Pure-Swift heuristic sky mask (plugin `skyMask`, research `.orchestration/context/CONTEXT_ANALYSIS_LIMITS_2026-11-11.md`).
/// On the 512 px scene-linear render: bright blue or bright neutral (cloud) pixels with low local texture, kept only
/// where the region touches the top of the frame, then refined with a guided filter (luma guide) into a soft mask.
/// It decides WHERE a look's `skyHold` may act; the hold itself stays colour-gated (`Preset26.skyWeight`), so blue-cast
/// shade whites (textured), blue objects mid-frame (not connected to the top) and non-sky frames (label gate) are not held.
public enum SkyMask {
    /// Bumped when the algorithm or its thresholds change: a stored mask of another version is re-made.
    public static let version = 1
    /// Below this share of the frame the mask counts as empty (no sky in the frame).
    public static let minCoverage = 0.01
    public static let labelConfidence = 0.3
    /// Vision labels that open the gate: sky itself plus the landscape labels `DecisionEngine` already uses.
    /// "outdoor" is left out on purpose (it is high for streets, parked cars, balconies).
    public static let gateLabels: Set<String> = DecisionEngine.Threshold.landscapeLabels.union(
        ["blue_sky", "cloudy", "cloud", "sunset_sunrise", "horizon", "rainbow"])

    public enum Gate: Equatable, Sendable {
        case open(label: String, confidence: Double)
        case closed(reason: String)        // classification exists and says no sky
        case unavailable(reason: String)   // no classification: no decision
    }

    public static func gate(labels: [String: Double]?) -> Gate {
        guard let labels else { return .unavailable(reason: "no classification (Vision unavailable)") }
        if let hit = labels.filter({ gateLabels.contains($0.key) && $0.value >= labelConfidence }).max(by: { $0.value < $1.value }) {
            return .open(label: hit.key, confidence: hit.value)
        }
        let top = labels.sorted { $0.value > $1.value }.prefix(3).map { String(format: "%@ %.2f", $0.key, $0.value) }.joined(separator: ", ")
        return .closed(reason: String(format: "no sky / landscape label >= %.2f (top: %@)", labelConfidence, top.isEmpty ? "none" : top))
    }

    public struct Result: Sendable {
        public var width: Int
        public var height: Int
        /// 0...1 per pixel, row 0 = top of the frame.
        public var mask: [Float]
        /// Mean of the mask.
        public var coverage: Double
    }

    static func smooth(_ a: Float, _ b: Float, _ x: Float) -> Float { let t = min(max((x - a) / (b - a), 0), 1); return t * t * (3 - 2 * t) }

    /// Mean over a (2r+1)² window, window shrunk at the border (integral image).
    static func boxMean(_ a: [Float], width w: Int, height h: Int, radius r: Int) -> [Float] {
        var integral = [Double](repeating: 0, count: (w + 1) * (h + 1))
        for y in 0..<h {
            var row = 0.0
            for x in 0..<w {
                row += Double(a[y * w + x])
                integral[(y + 1) * (w + 1) + x + 1] = integral[y * (w + 1) + x + 1] + row
            }
        }
        var out = [Float](repeating: 0, count: w * h)
        for y in 0..<h {
            let y0 = max(0, y - r), y1 = min(h - 1, y + r)
            for x in 0..<w {
                let x0 = max(0, x - r), x1 = min(w - 1, x + r)
                let s = integral[(y1 + 1) * (w + 1) + x1 + 1] - integral[y0 * (w + 1) + x1 + 1] - integral[(y1 + 1) * (w + 1) + x0] + integral[y0 * (w + 1) + x0]
                out[y * w + x] = Float(s / Double((y1 - y0 + 1) * (x1 - x0 + 1)))
            }
        }
        return out
    }

    /// Guided filter (He et al.), grey guide: edge-aware smoothing of `p` that follows the guide's edges.
    static func guidedFilter(guide I: [Float], p: [Float], width w: Int, height h: Int, radius r: Int, eps: Float) -> [Float] {
        let n = w * h
        let mI = boxMean(I, width: w, height: h, radius: r), mp = boxMean(p, width: w, height: h, radius: r)
        let mII = boxMean((0..<n).map { I[$0] * I[$0] }, width: w, height: h, radius: r)
        let mIp = boxMean((0..<n).map { I[$0] * p[$0] }, width: w, height: h, radius: r)
        var a = [Float](repeating: 0, count: n), b = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let varI = mII[i] - mI[i] * mI[i], cov = mIp[i] - mI[i] * mp[i]
            a[i] = cov / (varI + eps); b[i] = mp[i] - a[i] * mI[i]
        }
        let ma = boxMean(a, width: w, height: h, radius: r), mb = boxMean(b, width: w, height: h, radius: r)
        return (0..<n).map { min(max(ma[$0] * I[$0] + mb[$0], 0), 1) }
    }

    /// The mask of one scene-linear image (Display P3 linear, row 0 = top). Pure and deterministic.
    public static func compute(sceneLinear img: LinearImage) -> Result {
        let w = img.width, h = img.height, n = w * h
        var luma = [Float](repeating: 0, count: n), cand = [Float](repeating: 0, count: n)
        var r = [Float](repeating: 0, count: n), g = r, b = r
        for i in 0..<n {
            r[i] = Preset26.encode(min(max(img.pixels[i * 3], 0), 1))
            g[i] = Preset26.encode(min(max(img.pixels[i * 3 + 1], 0), 1))
            b[i] = Preset26.encode(min(max(img.pixels[i * 3 + 2], 0), 1))
            luma[i] = (r[i] * Preset26.lumaEncoded.x + g[i] * Preset26.lumaEncoded.y + b[i] * Preset26.lumaEncoded.z)
        }
        // Texture: local standard deviation of encoded luma (7x7). Sky is smooth; shade walls, foliage, cloth are not.
        let rad = 3
        let m1 = boxMean(luma, width: w, height: h, radius: rad)
        let m2 = boxMean(luma.map { $0 * $0 }, width: w, height: h, radius: rad)
        for i in 0..<n {
            let std = max(m2[i] - m1[i] * m1[i], 0).squareRoot()
            // Wider than Preset26.skyWeight on purpose (scene-linear input, hazy horizon sky): the mask only has to cover
            // where the colour-gated hold could act on real sky; the hold itself stays colour-gated.
            let blue = smooth(0.0, 0.05, b[i] - r[i]) * smooth(-0.12, -0.02, b[i] - g[i]) * smooth(0.12, 0.25, luma[i])
            let chroma = max(r[i], g[i], b[i]) - min(r[i], g[i], b[i])
            let cloud = (1 - smooth(0.04, 0.10, chroma)) * smooth(0.45, 0.60, luma[i])   // overcast / cloud: bridges blue patches
            cand[i] = max(blue, cloud) * (1 - smooth(0.025, 0.06, std))
        }
        // Connected regions (4-neighbours) of candidates that touch the top rows and are not tiny.
        var keep = [Float](repeating: 0, count: n)
        var seen = [Bool](repeating: false, count: n)
        let topRows = max(1, h / 50), minArea = max(1, Int(minCoverage * Double(n)))
        var stack: [Int] = [], region: [Int] = []
        for start in 0..<n where cand[start] > 0.5 && !seen[start] {
            region.removeAll(keepingCapacity: true); stack.removeAll(keepingCapacity: true)
            stack.append(start); seen[start] = true
            var touchesTop = false
            while let i = stack.popLast() {
                region.append(i)
                let x = i % w, y = i / w
                if y < topRows { touchesTop = true }
                if x > 0, cand[i - 1] > 0.5, !seen[i - 1] { seen[i - 1] = true; stack.append(i - 1) }
                if x < w - 1, cand[i + 1] > 0.5, !seen[i + 1] { seen[i + 1] = true; stack.append(i + 1) }
                if y > 0, cand[i - w] > 0.5, !seen[i - w] { seen[i - w] = true; stack.append(i - w) }
                if y < h - 1, cand[i + w] > 0.5, !seen[i + w] { seen[i + w] = true; stack.append(i + w) }
            }
            if touchesTop, region.count >= minArea { for i in region { keep[i] = 1 } }
        }
        // Refine: guided filter with the luma as guide (edges of the sky follow the image), small feather.
        let radius = max(2, Int((0.016 * Double(max(w, h))).rounded()))
        var mask = guidedFilter(guide: luma, p: keep, width: w, height: h, radius: radius, eps: 1e-3)
        for i in 0..<n where mask[i] < 0.02 { mask[i] = 0 }
        let coverage = Double(mask.reduce(0, +)) / Double(n)
        return Result(width: w, height: h, mask: mask, coverage: coverage)
    }
}
