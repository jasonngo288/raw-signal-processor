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
    /// What the user sees clipped: share of the same-press camera HEIC (stored `cameraReferenceHistogramFine`, 1024 px)
    /// with encoded Display P3 luma >= encodeTransfer(`clipLevel` 0.98) (threshold bin counted proportionally). nil = no camera reference at analysis time (or analysis schema < 5).
    /// Luma, not any-channel: a lower bound of the any-channel measure. Schema 5; before it this field held
    /// the CIRAWFilter appleDefault measure, now `appleDecodeClippedFraction`.
    public var displayClippedFraction: Double? = nil
    /// Fraction of pixels with any channel >= 0.98 in CIRAWFilter's appleDefault decode (1024 px). Reads 10-100x the HEIC
    /// (not what the camera shows). The old `displayClippedFraction`; still what `HighlightRecoveryRule` gates on by default.
    public var appleDecodeClippedFraction: Double? = nil
    /// EV100 = log2(N^2/t) - log2(ISO/100) from the DNG's ISO, exposure time and FNumber; nil if any is missing.
    /// Measurement only, no consumer yet. `ev100Version` = formula version (1), nil when `ev100` was not made.
    public var ev100: Double? = nil
    public var ev100Version: Int? = nil
    /// Lens aperture (EXIF FNumber of the DNG), nil when absent.
    public var fNumber: Double? = nil
    /// p99.9 of max(R,G,B) in an EDR decode (extendedDynamicRangeAmount 1). > 1 means highlight data
    /// above SDR white exists and can be tone-mapped back instead of clipping.
    public var edrHeadroom: Double? = nil
    /// Largest face as a fraction of the image area (Vision run at 1024 px).
    public var largestFaceArea: Double? = nil
    public var exposureTime: Double? = nil
    /// Share of the frame covered by people (Vision person segmentation, mean of the mask).
    public var personFraction: Double? = nil
    /// What the Vision person-segmentation step did and what the mask it returned measured. nil = not run (older analysis).
    public var personMaskDiag: PersonMaskDiagnostics? = nil
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

    /// Clipped by Apple's tone curve but present in the RAW (from the appleDefault decode measure; unchanged meaning).
    public var recoverableClippedFraction: Double? {
        appleDecodeClippedFraction.map { max(0, $0 - clippedFraction) }
    }

    /// Same, from the camera-HEIC measure (`displayClippedFraction`).
    public var recoverableClippedFractionCamera: Double? {
        displayClippedFraction.map { max(0, $0 - clippedFraction) }
    }

    public static let ev100FormulaVersion = 1

    /// Share of a display-encoded luminance histogram at or above `linear` (decoded level); the bin holding the
    /// threshold counts proportionally.
    public static func histogramFraction(_ hist: [Double], atOrAboveLinear linear: Double) -> Double? {
        guard !hist.isEmpty else { return nil }
        let pos = ColorMath.encodeTransfer(linear) * Double(hist.count)
        let b = min(hist.count - 1, max(0, Int(pos)))
        let part = hist[b] * (1 - (pos - Double(b)))
        return max(0, min(1, part + hist[(b + 1)...].reduce(0, +)))
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

    /// Clip level of `clippedFraction` and of the sensor-clip share in `measure` (any channel >= this).
    public static let clipLevel = 0.98

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
        public static let skinProtection: Float = 0.75
        /// Scene-linear median (log2, 0 = diffuse white) below which a frame counts as dark / night.
        /// Midpoint of the gap between the tuning files only (holdout never used): darkest non-dark MTN01 −4.57,
        /// brightest dark CAFE01 −6.13 (NIGHT01 −6.36) → −5.35. Was −5.0, chosen with the holdout TOKYO01 in view.
        public static let darkMedianStops = -5.35
        public static let veryHighISO = 1600.0
        public static let landscapeLabelConfidence = 0.5
        /// Vision classifier labels that mean "a person is in the frame". Their best confidence fades the +0.05 landscape
        /// look boost out through `labelRamp` (0.4...0.6, same ramp as the other label terms): boost x (1 - ramp). A person mask
        /// can miss a small subject; skin protection and the 3 % / 1.5-4.5 % ramp are untouched.
        /// Evidence (device roll 8FDA6B37, mask missed: face 0, pf ~0): people/adult f01 0.79, f03 0.63, f08 0.65, f10 0.73
        /// (frames with a landscape label); frame_inventory.json F82B f3 0.90. f04 0.46 and f09 0.47 have no landscape label,
        /// so the boost never applied there. Frames with no people/adult label keep the old path unchanged.
        public static let peopleLabels: Set<String> = ["people", "adult"]
        public static let landscapeLabels: Set<String> = ["sky", "land", "mountain", "hill", "beach", "grass", "field", "sunset", "sunrise", "ocean", "lake", "forest"]
        public static let lookIntensityRange: ClosedRange<Float> = -0.15...0.10
        /// Score ramps (smoothstep), centred on the thresholds above. Dark: 0 at −4.6, 1 at −6.1 stops (ends inside
        /// the tuning gap MTN01 −4.57 / CAFE01 −6.13). ISO: ±0.5 stop around 1600. People: ±50 % around 3 % mask /
        /// 1 % face. Label confidence: 0.4…0.6 around 0.5.
        public static let darkRamp: ClosedRange<Double> = -6.1 ... -4.6
        public static let isoRampStops = 0.5
        public static let peopleRamp = 0.5
        public static let labelRamp: ClosedRange<Double> = 0.4...0.6
    }

    /// Roadmap 13, context blending: how much of the (fixed) look this frame gets. Pure, bounded, every reason logged.
    /// Since 2026-11-15 each term is a 0...1 score (`ScenePrediction`) times its weight instead of a yes/no threshold:
    /// two frames of one roll at median −5.34 and −5.36 used to differ by 0.10 of look; now they differ by ~0.002.
    /// The ramps are centred on the old thresholds, and their ends sit inside the gaps between tuning files, so every
    /// tuning file keeps its old value (MTN01 −4.57 → 0, CAFE01 −6.13 → full).
    public static func lookIntensityOffset(context c: SceneContext) -> (Float, [String]) {
        let r = lookIntensityOffsetDetailed(context: c)
        return (r.clamped, r.why)
    }

    /// Same arithmetic as `lookIntensityOffset`, plus the typed terms and the unclamped sum (CALA M1-01 trace: record only).
    static func lookIntensityOffsetDetailed(context c: SceneContext) -> (clamped: Float, why: [String], terms: [LookAdaptationTrace.LookOffset.Term], sum: Float) {
        let p = c.prediction
        var off: Float = 0
        var why: [String] = []
        var terms: [LookAdaptationTrace.LookOffset.Term] = []
        func add(_ weight: Float, _ score: Double, _ text: String, id: String) {
            let v = weight * Float(score)
            guard abs(v) >= 0.0005 else { return }
            terms.append(.init(id: id, score: score, weight: weight, value: v))
            off += v
            why.append(String(format: "%@ -> look %+.3f", text, v))
        }
        add(-0.10, p.night, String(format: "dark scene %.2f (median %.2f stops, ramp %.2f…%.2f)", p.night, c.logP50,
                                   Threshold.darkRamp.lowerBound, Threshold.darkRamp.upperBound), id: "night")
        add(-0.05, p.highISO, String(format: "high ISO %.2f (ISO %ld, ramp around %ld)", p.highISO, Int(c.iso ?? 0), Int(Threshold.veryHighISO)), id: "highISO")
        add(-0.05, p.people, String(format: "people %.2f (mask %.1f%%, face %.1f%%; on top of skin protection)", p.people,
                                    (c.personFraction ?? 0) * 100, (c.largestFaceArea ?? 0) * 100), id: "people")
        // Landscape only where there are no people and it is not dark (people and night win, as before).
        // A high people label also vetoes it: the mask / face signal can miss a small subject (TASK-02 b).
        let landscapeText = String(format: "landscape %.2f (%@), x no-people x not-dark", p.landscape, p.landscapeLabel ?? "none")
        let fullBoost = p.landscape * (1 - p.people) * (1 - p.night)
        if let pl = (c.labels ?? [:]).filter({ Threshold.peopleLabels.contains($0.key) }).max(by: { $0.value < $1.value }),
           pl.value > Threshold.labelRamp.lowerBound {
            let fade = ScenePrediction.ramp(pl.value, from: Threshold.labelRamp.lowerBound, to: Threshold.labelRamp.upperBound)
            let kept = fullBoost * (1 - fade)
            if 0.05 * Float(fullBoost) >= 0.0005 {   // the boost would have shown up: say how it was reduced
                if 0.05 * Float(kept) >= 0.0005 {
                    add(0.05, kept, String(format: "%@, x (1 - people label %@ %.2f ramp %.2f)", landscapeText, pl.key, pl.value, fade), id: "landscape")
                } else {
                    why.append(String(format: "%@ boost skipped: people label %@ %.2f (ramp %.2f) -> look +0.000", landscapeText, pl.key, pl.value, fade))
                }
            }
        } else {
            add(0.05, fullBoost, landscapeText, id: "landscape")
        }
        let r = Threshold.lookIntensityRange
        let clamped = min(max(off, r.lowerBound), r.upperBound)
        if abs(clamped - off) > 1e-6 { why.append(String(format: "look offset %.3f clamped to %.2f", off, clamped)) }
        return (clamped, why, terms, off)
    }

    public static func decide(context c: SceneContext, defaults d: DecodeParameters, support s: DecoderSupport,
                              base: RenderSettings = .explicit, autoSkinProtection: Float? = nil) -> Decision {
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
            let strength = autoSkinProtection ?? Threshold.skinProtection   // per-look value (0.8.4-rc2); nil = global default
            st.skinProtection = strength
            why.append(String(format: "people %.1f%% of frame, largest face %.1f%% -> skin protection %.2f", person * 100, face * 100, strength))
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
            else if r.contains(where: { $0.contains("boost skipped") }) { why += r }   // gate removed the whole boost: keep the reason
        }
        if why.isEmpty { why.append("no rule fired: Apple defaults kept (explicit)") }
        why.append(c.prediction.summary)
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

    /// `useCameraClip` (default off: pixels unchanged) gates on the camera-HEIC measure instead of the appleDefault decode.
    public static func decide(context c: SceneContext, settings: inout RenderSettings, useCameraClip: Bool = false) -> [String] {
        guard let disp = useCameraClip ? c.displayClippedFraction : c.appleDecodeClippedFraction,
              let rec = useCameraClip ? c.recoverableClippedFractionCamera : c.recoverableClippedFraction else { return [] }
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

/// Scene semantics as 0...1 scores with the evidence behind each (the "feature fusion" layer of the 2026-11-15
/// architecture review). Pure and derived from `SceneContext`, so a stored analysis needs no new fields.
/// Measurements decide what they measure (darkness from the scene-linear median, people from the Vision mask / faces);
/// Vision labels only give environment and landscape, each with its confidence. A label id that Vision never returns
/// simply never matches.
public struct ScenePrediction: Codable, Equatable, Sendable {
    public enum Environment: String, Codable, Sendable { case indoor, outdoor, unknown }
    /// Dark / night appearance from the scene-linear median (measured, not a label).
    public var night: Double
    public var highISO: Double
    /// People from the Vision person mask and the largest face.
    public var people: Double
    /// Best landscape label confidence, ramped (0.4…0.6).
    public var landscape: Double
    public var landscapeLabel: String?
    public var outdoor: Double
    public var indoor: Double
    public var environment: Environment

    public static let outdoorLabels: Set<String> = DecisionEngine.Threshold.landscapeLabels.union(
        ["outdoor", "cloudy", "blue_sky", "cityscape", "skyscraper", "street", "road", "garden", "park", "snow", "desert"])
    public static let indoorLabels: Set<String> = ["indoor", "interior_room", "room", "living_room", "bedroom", "kitchen", "office",
                                                   "restaurant", "furniture", "sofa", "couch", "bed", "tableware", "utensil", "stairs", "door", "ceiling"]
    /// An environment is named only when its evidence is >= this and beats the other side by `environmentMargin`.
    public static let environmentConfidence = 0.5
    public static let environmentMargin = 0.15

    /// smoothstep: 0 at `a`, 1 at `b` (works for a > b too).
    public static func ramp(_ x: Double, from a: Double, to b: Double) -> Double {
        guard a != b else { return x >= b ? 1 : 0 }
        let t = min(max((x - a) / (b - a), 0), 1)
        return t * t * (3 - 2 * t)
    }

    public init(context c: SceneContext) {
        typealias T = DecisionEngine.Threshold
        night = Self.ramp(c.logP50, from: T.darkRamp.upperBound, to: T.darkRamp.lowerBound)
        if let iso = c.iso, iso > 0 {
            let stops = log2(iso / T.veryHighISO)
            highISO = Self.ramp(stops, from: -T.isoRampStops, to: T.isoRampStops)
        } else { highISO = 0 }
        let person = c.personFraction ?? 0, face = c.largestFaceArea ?? 0
        let k = T.peopleRamp
        people = max(Self.ramp(person, from: T.personFraction * (1 - k), to: T.personFraction * (1 + k)),
                     Self.ramp(face, from: T.faceArea * (1 - k), to: T.faceArea * (1 + k)))
        let labels = c.labels ?? [:]
        func best(_ set: Set<String>) -> (String, Double)? {
            labels.filter { set.contains($0.key) }.max { $0.value < $1.value }.map { ($0.key, $0.value) }
        }
        let land = best(T.landscapeLabels)
        landscapeLabel = land?.0
        landscape = Self.ramp(land?.1 ?? 0, from: T.labelRamp.lowerBound, to: T.labelRamp.upperBound)
        outdoor = best(Self.outdoorLabels)?.1 ?? 0
        indoor = best(Self.indoorLabels)?.1 ?? 0
        if outdoor >= Self.environmentConfidence, outdoor - indoor >= Self.environmentMargin { environment = .outdoor }
        else if indoor >= Self.environmentConfidence, indoor - outdoor >= Self.environmentMargin { environment = .indoor }
        else { environment = .unknown }
    }

    /// One recipe line.
    public var summary: String {
        String(format: "scene: %@ (outdoor %.2f, indoor %.2f), night %.2f, high ISO %.2f, people %.2f, landscape %.2f%@",
               environment.rawValue, outdoor, indoor, night, highISO, people, landscape, landscapeLabel.map { " (\($0))" } ?? "")
    }
}

public extension SceneContext {
    /// Scores derived from this context (computed, not stored).
    var prediction: ScenePrediction { ScenePrediction(context: self) }
}

/// Diagnostics of the Vision person mask (status plus measurements of the raw 8-bit `CVPixelBuffer`). Diagnosis only:
/// nothing in the render reads it except the recipe lines.
public struct PersonMaskDiagnostics: Codable, Sendable, Equatable {
    public enum Status: String, Codable, Sendable { case ok, requestFailed, noResult, noCGImage }
    public var status: Status
    /// `domain code` of the Vision error when the request failed (no message text).
    public var error: String?
    public var width: Int?
    public var height: Int?
    /// Largest pixel value (0...255) of the mask buffer.
    public var maxValue: Int?
    public var nonZeroPixels: Int?
    public var pixelsAtLeast128: Int?
    /// Which Vision quality produced the mask the render uses (nil on failures / old data).
    public enum Source: String, Codable, Sendable { case balanced, fastFallback }
    public var source: Source?
    /// Stats of `.balanced` / `.fast` when the fast fallback ran (balanced was empty). The main fields above describe the used mask
    /// (or, when both are empty, the balanced one). Optional: older stored data without them still decodes.
    public var balancedMaxValue: Int?
    public var balancedPixelsAtLeast128: Int?
    public var fastMaxValue: Int?
    public var fastPixelsAtLeast128: Int?

    public init(status: Status, error: String? = nil) { self.status = status; self.error = error }

    /// True when a mask exists but not one pixel reaches 128.
    public var maskIsEmpty: Bool { status == .ok && (pixelsAtLeast128 ?? 0) == 0 }

    public var summary: String {
        switch status {
        case .ok:
            var t = "ok, \(width ?? 0)x\(height ?? 0), max \(maxValue ?? 0), non-zero \(nonZeroPixels ?? 0) px, >=128 \(pixelsAtLeast128 ?? 0) px"
            if let s = source { t += ", source \(s.rawValue)" }
            if let bm = balancedMaxValue {
                t += ", balanced max \(bm) >=128 \(balancedPixelsAtLeast128 ?? 0) px, fast max \(fastMaxValue.map(String.init) ?? "n/a") >=128 \(fastPixelsAtLeast128 ?? 0) px"
            }
            if maskIsEmpty {
                t += fastMaxValue == nil ? ", balanced mask empty, fast not available: treated as no person"
                                         : ", balanced and fast masks empty: treated as no person"
            }
            return t
        case .requestFailed: return "Vision person request failed (\(error ?? "unknown")): no mask"
        case .noResult: return "Vision person request returned no result: no mask"
        case .noCGImage: return "no CGImage for Vision: person mask not run"
        }
    }
}

#if canImport(CoreVideo)
import CoreVideo
extension PersonMaskDiagnostics {
    /// Measures a OneComponent8 buffer (size, max, non-zero count, count >= 128).
    mutating func measure(_ buf: CVPixelBuffer) {
        let w = CVPixelBufferGetWidth(buf), h = CVPixelBufferGetHeight(buf)
        width = w; height = h
        guard CVPixelBufferGetPixelFormatType(buf) == kCVPixelFormatType_OneComponent8,
              CVPixelBufferLockBaseAddress(buf, .readOnly) == kCVReturnSuccess else { return }
        defer { CVPixelBufferUnlockBaseAddress(buf, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buf) else { return }
        let stride = CVPixelBufferGetBytesPerRow(buf)
        var mx = 0, nz = 0, hi = 0
        for y in 0..<h {
            let row = base.advanced(by: y * stride).assumingMemoryBound(to: UInt8.self)
            for x in 0..<w {
                let v = Int(row[x])
                if v > mx { mx = v }
                if v != 0 { nz += 1 }
                if v >= 128 { hi += 1 }
            }
        }
        maxValue = mx; nonZeroPixels = nz; pixelsAtLeast128 = hi
    }
}
#endif
