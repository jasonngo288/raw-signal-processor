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

    /// The curve blended toward identity: y = x + k (y_curve - x), k in 0...1. A convex mix of two monotone curves is
    /// monotone, so the result stays a valid tone curve. k = 1 returns the curve, k = 0 the identity.
    public static func blended(_ c: [SIMD2<Double>], strength k: Double) -> [SIMD2<Double>] {
        let k = min(max(k, 0), 1)
        return c.map { SIMD2($0.x, $0.x + k * ($0.y - $0.x)) }
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

/// Decode-headroom split (RSP 0.3.0), the ONE implementation: `HeadroomPlugin` (legacy exposure model) calls it, and a
/// host that renders display-referred samples should call it too instead of keeping its own copy (MoodRoll
/// `FilmSampleStore.headroomSplit`, PIPELINE_AUDIT 2026-11-17 §6 row 6). A negative bias stays in the decode, a positive
/// one goes into the display restore: decode = min(bias, 0) − Δ, restore = Δ + max(bias, 0). Δ <= 0 = no split.
public enum HeadroomSplit {
    public static func split(bias: Float, headroomEV d: Float) -> (decodeEV: Float, restoreEV: Float?) {
        guard d > 0 else { return (bias, nil) }
        return (min(bias, 0) - d, d + max(bias, 0))
    }
}

/// Pipeline v2 stage 1 (MoodRoll PIPELINE_V2_CONTRACT): one continuous scene normalizer, the same for every stock.
/// No scene classifier and no `if night` branch: every term is a continuous function of measured inputs.
/// Inputs: the RAW histogram (scene-linear percentiles and Apple's default RAW render histogram from the analysis),
/// highlight headroom (scene-linear p99.9 against Apple's tone-curve white after BaselineExposure), metering / capture
/// exposure (DNG BaselineExposure as Apple's per-file default, ISO, shutter, aperture -> EV100) and the person mask.
/// The Apple HEIC is NOT an input (it has no field here); `Developer` only records it as a diagnostic ΔEV.
///
/// Model, in display-linear luminance Y of the stage-1 output (the base before any stock):
/// 1. Anchor: the median of Apple's default RAW render (`appleDefaultMedianY`, exposure 0 = the camera's metering).
/// 2. Target: `midTargetL` lowered by up to `nightTargetDropL` on a smoothstep of EV100 (night intent, continuous).
/// 3. Global EV: `strength` x the log2 distance from anchor to target, bounded to -maxCutEV...+maxLiftEV. A strength
///    below 1 keeps high-key / low-key order (a bright scene stays brighter than a dark one).
/// 4. Highlights: the decode is lowered by the smallest Δ (bisection on small SDR probe decodes of the same RAW) whose
///    display clipping (any channel >= 0.98) exceeds the sensor-clipped share by at most `highlightClipAllowance`;
///    Δ and the positive part of the EV come back in display space with the continuous max-channel shoulder
///    (`HeadroomRestore.curveV2`), solved on the measured decode so the median lands on target.
/// 5. Skin: with people (smooth `ScenePrediction.people` score) the skin median inside the person mask is lifted toward
///    `skinFloorL` by at most `maxSkinLiftEV` x the score. Never lowered.
///
/// EVERY number in `Parameters` is PROVISIONAL (not approved by the User; MoodRoll PIPELINE_V2_CONTRACT: numbers are
/// set when the golden set is frozen). The recipe records them with `parametersStatus`.
public enum SceneNormalizer {
    public static let version = 1
    public static let parametersStatus = "provisional: not approved (PIPELINE_V2_CONTRACT, numbers wait for the frozen golden set)"

    public struct Parameters: Codable, Equatable, Sendable {
        /// L* (D65) the median of the stage-1 output is pulled toward. 50 ~ scene middle grey (18 % reflectance -> Y 0.18
        /// -> L* 49.5).
        public var midTargetL: Double = 50
        /// 0...1: share of the log2 distance between the camera-metered median and the target that is removed.
        /// 0 = the camera's metering untouched, 1 = every median on the target (no key intent left).
        public var strength: Double = 0.5
        /// Bounds of the global EV (before the skin lift).
        public var maxLiftEV: Double = 1.0
        public var maxCutEV: Double = 1.5
        /// Night intent: the target drops by `nightTargetDropL` L* on a smoothstep from EV100 `nightEV100None`
        /// (no drop) down to `nightEV100Full` (full drop). EV100 = log2(N²/t) − log2(ISO/100) of the capture.
        public var nightEV100None: Double = 5
        public var nightEV100Full: Double = 2
        public var nightTargetDropL: Double = 12
        /// Share of pixels that may clip in the decode (any channel >= 0.98, 512 px SDR probe) beyond those the sensor
        /// already clipped. The highlight cut Δ is the smallest that meets it (probe bisection, `highlightProbeSteps`).
        public var highlightClipAllowance: Double = 0.002
        /// Bisection steps after the two end probes (resolution maxDecodeHeadroomEV / 2^steps).
        public var highlightProbeSteps: Int = 4
        /// Largest decode cut Δ for highlights (RenderSettings.decodeHeadroomEV range is 0...1.5).
        public var maxDecodeHeadroomEV: Double = 1.5
        /// Largest display restore gain (Δ + lift + what Apple's toe loses at the lower decode). Above it the median is
        /// left under target (recorded): a large display gain after Apple's toe compresses the highlights toward white.
        /// The display gain may also go negative (plain darkening) down to −maxCutEV, when Apple's shoulder keeps the
        /// lowered decode above target.
        public var maxRestoreEV: Double = 1.5
        /// Skin median L* floor inside the person mask, and the largest lift (x the people score) toward it.
        public var skinFloorL: Double = 40
        public var maxSkinLiftEV: Double = 0.5
        /// Stage-1 clip cap (review M2): a restored pixel counts as hard-clipped when any channel encodes (8-bit,
        /// display-encoded) to this code or above. 255 = only the top code (truly saturated); 254 = near-white counts too.
        /// Interim default 254 (User, 2026-11-18, PIPELINE_V2_CONTRACT round 7). Missing key in JSON and nil both mean the
        /// default (`defaultClipTopCode8bit`, User 2026-11-19, contract round 8).
        public var clipTopCode8bit: Int? = Parameters.defaultClipTopCode8bit
        public static let defaultClipTopCode8bit = 254
        /// `clipTopCode8bit`, nil = the default.
        public var effectiveClipTopCode8bit: Int { clipTopCode8bit ?? Parameters.defaultClipTopCode8bit }
        /// Bright-scene blend of the stage-1 highlight rule (sun-frame dimness option C, User 2026-11-19, MoodRoll
        /// PIPELINE_V2_CONTRACT round 9). nil = off (default): stage 1 is exactly the rule above. Absent from the JSON when nil.
        public var brightSceneBlend: BrightSceneBlend? = nil

        /// Option C: a continuous weight w = smoothstep((EV100 − ev100None) / (ev100Full − ev100None)) blends the stage-1
        /// display gain from today's rule (`clipTopCode8bit`, `maxRestoreEV`) toward `clipTopCode8bit` / `maxRestoreEV` of
        /// this struct. No scene classifier, no stock input. How (as film-lab emulated it, SUN_DIMNESS_DIAGNOSIS 2026-11-19
        /// §3 C): g254 = the gain today's rule delivers, gWanted = the gain the median asks for with the bound `maxRestoreEV`
        /// here (before any highlight rule); the solve then runs once more with the highlight rule at `clipTopCode8bit` here
        /// and the restore bound g254 + w·(gWanted − g254) (quantised 0.01 EV). w = 0 (EV100 at or below `ev100None`, or
        /// unknown) = today's pixels exactly. EVERY number here is PROVISIONAL: the ramp ends were fitted to 6 bright frames
        /// from one phone (9 = just above the highest indoor EV100 of the golden set, 8.6; 13 = between GS-A01 12.9 and
        /// GS-C02 13.7; 2.5 = first 0.5 step above the largest wanted gain, 2.33 on GS-A01). Missing keys decode as these.
        public struct BrightSceneBlend: Codable, Equatable, Sendable {
            /// EV100 at and below which w = 0 (PROVISIONAL).
            public var ev100None: Double = 9
            /// EV100 at and above which w = 1 (PROVISIONAL).
            public var ev100Full: Double = 13
            /// Stage-1 hard-clip code at w > 0 (PROVISIONAL).
            public var clipTopCode8bit: Int = 255
            /// Restore bound for the wanted gain at w = 1 (PROVISIONAL).
            public var maxRestoreEV: Double = 2.5

            public init() {}
            public static let provisional = BrightSceneBlend()

            public init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                let d = BrightSceneBlend()
                ev100None = try c.decodeIfPresent(Double.self, forKey: .ev100None) ?? d.ev100None
                ev100Full = try c.decodeIfPresent(Double.self, forKey: .ev100Full) ?? d.ev100Full
                clipTopCode8bit = try c.decodeIfPresent(Int.self, forKey: .clipTopCode8bit) ?? d.clipTopCode8bit
                maxRestoreEV = try c.decodeIfPresent(Double.self, forKey: .maxRestoreEV) ?? d.maxRestoreEV
            }

            /// Restore bound of the blended pass: quantised(max(g254 + w·max(gWanted − g254, 0), 0)), 0.01 EV grid. A gWanted
            /// below g254 does not lower the bound (it stays g254, or 0 when g254 is a darkening).
            public static func restoreBound(today g254: Double, wanted: Double, weight w: Double) -> Double {
                Double(HeadroomRestore.quantised(Float(max(g254 + w * max(wanted - g254, 0), 0))))
            }

            /// N1 clamp (User 2026-11-19): true = the blended pass delivered less gain than the blend-off pass, so the
            /// blend-off pass is kept. The delivered gain is never below g254.
            public static func keepsToday(blended: Double, today g254: Double) -> Bool { blended < g254 - 1e-9 }

            /// 0...1 smoothstep of EV100 from `ev100None` (0) to `ev100Full` (1); 0 when EV100 is unknown.
            public func weight(ev100: Double?) -> Double {
                guard let e = ev100, e.isFinite else { return 0 }
                return ScenePrediction.ramp(e, from: ev100None, to: ev100Full)
            }

            public func validate() throws {
                func check(_ ok: Bool, _ what: String) throws { if !ok { throw RawCoreError.invalidSettings("sceneNormalizer.brightSceneBlend: \(what)") } }
                try check([ev100None, ev100Full, maxRestoreEV].allSatisfy { $0.isFinite }, "all values must be finite")
                try check(ev100None < ev100Full, "ev100None < ev100Full")
                try check((0...4).contains(maxRestoreEV), "maxRestoreEV in 0...4")
                try check((1...255).contains(clipTopCode8bit), "clipTopCode8bit in 1...255")
            }

            /// Also checked against the base parameters: the blend's restore bound must be >= the base `maxRestoreEV`.
            public func validate(base: Parameters) throws {
                try validate()
                if !(maxRestoreEV >= base.maxRestoreEV) {
                    throw RawCoreError.invalidSettings("sceneNormalizer.brightSceneBlend: maxRestoreEV \(maxRestoreEV) must be >= base maxRestoreEV \(base.maxRestoreEV)")
                }
            }
        }

        public init() {}
        public static let provisional = Parameters()

        /// Synthesized decoding except `clipTopCode8bit`: absent (JSON from before the key) decodes as the default, not nil.
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            midTargetL = try c.decode(Double.self, forKey: .midTargetL)
            strength = try c.decode(Double.self, forKey: .strength)
            maxLiftEV = try c.decode(Double.self, forKey: .maxLiftEV)
            maxCutEV = try c.decode(Double.self, forKey: .maxCutEV)
            nightEV100None = try c.decode(Double.self, forKey: .nightEV100None)
            nightEV100Full = try c.decode(Double.self, forKey: .nightEV100Full)
            nightTargetDropL = try c.decode(Double.self, forKey: .nightTargetDropL)
            highlightClipAllowance = try c.decode(Double.self, forKey: .highlightClipAllowance)
            highlightProbeSteps = try c.decode(Int.self, forKey: .highlightProbeSteps)
            maxDecodeHeadroomEV = try c.decode(Double.self, forKey: .maxDecodeHeadroomEV)
            maxRestoreEV = try c.decode(Double.self, forKey: .maxRestoreEV)
            skinFloorL = try c.decode(Double.self, forKey: .skinFloorL)
            maxSkinLiftEV = try c.decode(Double.self, forKey: .maxSkinLiftEV)
            clipTopCode8bit = try c.decodeIfPresent(Int.self, forKey: .clipTopCode8bit) ?? Parameters.defaultClipTopCode8bit
            brightSceneBlend = try c.decodeIfPresent(BrightSceneBlend.self, forKey: .brightSceneBlend)
        }

        public func validate() throws {
            func check(_ ok: Bool, _ what: String) throws { if !ok { throw RawCoreError.invalidSettings("sceneNormalizer: \(what)") } }
            let all = [midTargetL, strength, maxLiftEV, maxCutEV, nightEV100None, nightEV100Full, nightTargetDropL,
                       highlightClipAllowance, maxDecodeHeadroomEV, maxRestoreEV, skinFloorL, maxSkinLiftEV]
            try check(all.allSatisfy { $0.isFinite }, "all values must be finite")
            try check((5...95).contains(midTargetL), "midTargetL in 5...95")
            try check((0...1).contains(strength), "strength in 0...1")
            try check((0...3).contains(maxLiftEV) && (0...3).contains(maxCutEV), "maxLiftEV / maxCutEV in 0...3")
            try check(nightEV100Full < nightEV100None, "nightEV100Full < nightEV100None")
            try check((0...40).contains(nightTargetDropL) && midTargetL - nightTargetDropL >= 5, "nightTargetDropL in 0...40, target stays >= 5")
            try check((0...0.1).contains(highlightClipAllowance), "highlightClipAllowance in 0...0.1")
            try check((0...8).contains(highlightProbeSteps), "highlightProbeSteps in 0...8")
            try check((0...1.5).contains(maxDecodeHeadroomEV), "maxDecodeHeadroomEV in 0...1.5")
            try check((0...4).contains(maxRestoreEV), "maxRestoreEV in 0...4")
            try check((0...95).contains(skinFloorL) && (0...2).contains(maxSkinLiftEV), "skinFloorL in 0...95, maxSkinLiftEV in 0...2")
            try check((1...255).contains(effectiveClipTopCode8bit), "clipTopCode8bit in 1...255")
            try brightSceneBlend?.validate(base: self)
        }
    }

    /// What the normalizer reads. No Apple HEIC field, by contract.
    public struct Inputs: Codable, Equatable, Sendable {
        /// Median display-linear luminance of Apple's default RAW render at exposure 0 (analysis `lumaHistogram`,
        /// 1024 px). nil = the analysis has no histogram (then the global EV is 0 and the recipe says so).
        public var appleDefaultMedianY: Double?
        /// Scene-linear log2 luminance percentiles (RAW, no BaselineExposure; 0 = the decoder's white).
        public var sceneLogP50: Double
        public var sceneLogP99: Double
        public var sceneLogP999: Double
        public var sensorClippedFraction: Double
        /// Apple-decode measure (`SceneContext.appleDecodeClippedFraction`), never the camera-HEIC one (no Apple HEIC input, by contract).
        public var displayClippedFraction: Double?
        public var edrHeadroom: Double?
        /// Apple's per-file default `baselineExposure` (the DNG BaselineExposure the decoder applies).
        public var baselineExposureEV: Double
        public var iso: Double?
        public var exposureTime: Double?
        public var fNumber: Double?
        public var ev100: Double?
        /// Smooth 0...1 people score (`ScenePrediction.people`) and what it is made of.
        public var people: Double
        public var personFraction: Double?
        public var largestFaceArea: Double?

        public init(context c: SceneContext, baselineExposureEV: Double, fNumber: Double?) {
            appleDefaultMedianY = c.lumaHistogram.map { ColorMath.decodeTransfer(ToneMatch.quantile($0, 0.5)) }
            sceneLogP50 = c.logP50; sceneLogP99 = c.logP99; sceneLogP999 = c.logP999 ?? c.logP99
            sensorClippedFraction = c.clippedFraction; displayClippedFraction = c.appleDecodeClippedFraction; edrHeadroom = c.edrHeadroom
            self.baselineExposureEV = baselineExposureEV
            iso = c.iso; exposureTime = c.exposureTime; self.fNumber = fNumber
            ev100 = SceneNormalizer.ev100(fNumber: fNumber, exposureTime: c.exposureTime, iso: c.iso)
            people = c.prediction.people; personFraction = c.personFraction; largestFaceArea = c.largestFaceArea
        }
    }

    /// Stage-1 decision made before the decode (pure). The display restore is solved after the decode.
    public struct Plan: Codable, Equatable, Sendable {
        /// 0...1 night weight from EV100 (0 when EV100 is unknown) and the resulting median target.
        public var nightWeight: Double
        public var targetL: Double
        /// L* of the camera-metered anchor (Apple's default RAW render median); nil without a histogram.
        public var anchorL: Double?
        /// Global EV vs Apple's default RAW render (bounded), before the skin lift.
        public var globalEV: Double
        /// Median the restore must deliver (anchor x 2^globalEV), display-linear Y; nil without a histogram.
        public var targetMedianY: Double?
        /// Highlight decode cut Δ and the CIRAWFilter `exposure` actually decoded with (= min(globalEV, 0) − Δ).
        public var highlightCutEV: Double
        public var decodeExposureEV: Double
        /// The probes behind Δ: (cut EV, display-clipped share of the 512 px SDR decode), in the order made.
        public var highlightProbes: [HighlightProbe] = []
        public var notes: [String]
    }

    public static func ev100(fNumber: Double?, exposureTime: Double?, iso: Double?) -> Double? {
        guard let n = fNumber, let t = exposureTime, let s = iso, n > 0, t > 0, s > 0 else { return nil }
        return log2(n * n / t) - log2(s / 100)
    }

    /// CIE L* (D65, Y in 0...1) and back.
    public static func lstar(_ y: Double) -> Double {
        let e = 216.0 / 24389.0, k = 24389.0 / 27.0
        let t = max(y, 0)
        return t > e ? 116 * cbrt(t) - 16 : k * t
    }
    public static func luminance(lstar l: Double) -> Double {
        let k = 24389.0 / 27.0
        return l > 8 ? pow((l + 16) / 116, 3) : l / k
    }

    public static func decide(_ i: Inputs, _ p: Parameters) -> Plan {
        var notes: [String] = []
        let w = i.ev100.map { ScenePrediction.ramp($0, from: p.nightEV100None, to: p.nightEV100Full) } ?? 0
        if i.ev100 == nil { notes.append("EV100 unknown (ISO, shutter or aperture missing): night term 0") }
        let targetL = p.midTargetL - p.nightTargetDropL * w
        var e = 0.0
        var anchorL: Double?
        var targetY: Double?
        if let y0 = i.appleDefaultMedianY, y0 > 1e-6 {
            anchorL = lstar(y0)
            let raw = p.strength * (log2(luminance(lstar: targetL)) - log2(y0))
            e = min(max(raw, -p.maxCutEV), p.maxLiftEV)
            if abs(e - raw) > 1e-9 { notes.append(String(format: "global EV %+.2f bounded to %+.2f", raw, e)) }
            targetY = y0 * pow(2, e)
        } else {
            notes.append("no Apple default render histogram in the analysis: global EV 0, no restore solve")
        }
        return Plan(nightWeight: w, targetL: targetL, anchorL: anchorL, globalEV: e, targetMedianY: targetY,
                    highlightCutEV: 0, decodeExposureEV: min(e, 0), notes: notes)
    }

    public struct HighlightProbe: Codable, Equatable, Sendable {
        public var cutEV: Double
        public var clippedFraction: Double
    }

    /// The highlight cut Δ for `plan` (pure search; `clipAt(exposureEV)` makes one probe decode and returns its clipped
    /// share). Smallest Δ in 0...maxDecodeHeadroomEV with clip − sensorClip <= allowance: probe at 0, then at the cap,
    /// then bisection. Returns the plan with Δ, the decode exposure and the probes.
    public static func withHighlightCut(_ plan: Plan, _ p: Parameters, sensorClippedFraction sensor: Double,
                                        clipAt: (Double) throws -> Double) rethrows -> Plan {
        var out = plan
        let base = min(plan.globalEV, 0)
        func ok(_ c: Double) -> Bool { c - sensor <= p.highlightClipAllowance }
        func probe(_ cut: Double) throws -> Double {
            let c = try clipAt(base - cut)
            out.highlightProbes.append(HighlightProbe(cutEV: cut, clippedFraction: c))
            return c
        }
        var cut = 0.0
        if try !ok(probe(0)), p.maxDecodeHeadroomEV > 0 {
            if try !ok(probe(p.maxDecodeHeadroomEV)) {
                cut = p.maxDecodeHeadroomEV
                out.notes.append(String(format: "highlights still clip beyond the allowance at the %.2f EV cap", cut))
            } else {
                var lo = 0.0, hi = p.maxDecodeHeadroomEV
                for _ in 0..<p.highlightProbeSteps {
                    let mid = (lo + hi) / 2
                    if try ok(probe(mid)) { hi = mid } else { lo = mid }
                }
                cut = hi
            }
        }
        out.highlightCutEV = cut
        out.decodeExposureEV = base - cut
        return out
    }

    /// Next display gain (EV) toward the target median from the median `measured` at gain `g`: g + log2(target / measured),
    /// bounded to −minEV...maxEV. Negative = a plain linear darkening, used when Apple's shoulder kept the lowered decode
    /// above target. Pure step of the delivery loop in `Developer`.
    public static func nextRestore(_ g: Double, measured: Double, target: Double, maxEV: Double, minEV: Double = 0) -> Double {
        guard measured > 1e-6, target > 1e-6 else { return g }
        return min(max(g + log2(target / measured), -minEV), maxEV)
    }
}

/// What stage 1 did in one render (`DecodeRecipe.exposureNormalizer`, only with `exposureModel = .v2Normalizer`).
public struct ExposureNormalizerRecord: Codable, Equatable, Sendable {
    public static let currentSchema = 1
    public var schema: Int = ExposureNormalizerRecord.currentSchema
    public var model: RenderSettings.ExposureModel = .v2Normalizer
    public var normalizerVersion: Int = SceneNormalizer.version
    public var parameters: SceneNormalizer.Parameters
    public var parametersStatus: String = SceneNormalizer.parametersStatus
    /// Caller values that v2 does NOT use for exposure (stock exposureBias, stock decodeHeadroomEV, cameraMatchStrength).
    public var ignoredCallerExposureEV: Float?
    public var ignoredDecodeHeadroomEV: Float?
    public var ignoredCameraMatchStrength: Float?
    /// v2 forces highlightRecovery off for every stock (User 2026-11-18); true = the caller's plugin list had it on.
    public var highlightRecoveryForcedOff: Bool?
    public var inputs: SceneNormalizer.Inputs?
    public var plan: SceneNormalizer.Plan?
    /// Median L* of the decode before the restore, the display gain applied (EV, quantised 0.01; > 0 = restore with the
    /// v2 shoulder, < 0 = linear darkening) and how many measurements it took.
    public var decodeMedianL: Double?
    public var restoreEV: Double?
    public var restoreIterations: Int?
    /// Skin check inside the person mask (skin-hue pixels): median L* before the lift, the lift, after.
    public var skinMedianL: Double?
    public var skinPixels: Int?
    public var skinLiftEV: Double?
    public var skinMedianLAfter: Double?
    /// Median L* delivered; EV decided (global + skin lift) and EV delivered, both vs Apple's default RAW render median.
    /// They differ when the restore bound binds (`notes`).
    public var deliveredMedianL: Double?
    public var decidedEV: Double?
    public var deliveredEV: Double?
    /// DIAGNOSTIC ONLY (never an input): mid-tone ΔEV of the Apple HEIC vs this stage-1 output (positive = HEIC brighter),
    /// same measure as cameraMatch (64-bin luma, 1024 px, quantiles 30-70 %), unbounded. nil = no HEIC reference.
    public var appleDiagnosticDeltaEV: Double?
    public var appleDiagnosticSource: String?
    /// Highlight rule on the stage-1 output (review M2; contract clipping definition, User 2026-11-18): pipeline-induced clip
    /// (`stage1ClipMeasure`: recoverable in the stage-0 master, hard-clipped in the restored stage-1 image; no
    /// specular / sun / window exclusion) at gain 0, the limit max(allowance, at gain 0), and what is delivered.
    /// `masterClippedFraction` = master pixels at/above the clip level (not recoverable, not counted). `medianRestoreEV` is
    /// the gain the median asked for when the rule lowered it (nil = the rule did not bind).
    public var stage1ClipMeasure: String?
    public var masterClippedFraction: Double?
    public var stage1ClippedBeforeRestore: Double?
    public var stage1ClipLimit: Double?
    public var stage1ClippedFraction: Double?
    public var medianRestoreEV: Double?
    /// log2(target median / delivered median), target incl. the skin lift: > 0 = delivered darker than decided.
    public var shortfallEV: Double?
    /// Bright-scene blend (option C, PROVISIONAL); nil when `parameters.brightSceneBlend` is nil (absent from the JSON).
    public var brightSceneBlend: BrightSceneBlendRecord?
    /// How the stage-1 image and the highlight probes were decoded.
    public var stage1Decode: Stage1Decode?
    /// Why the normalizer did not run (render without analysis), nil when it ran.
    public var skipped: String?
    public var notes: [String] = []

    public init(parameters: SceneNormalizer.Parameters) { self.parameters = parameters }

    /// Decode of the v2 measurements. The anchor is the analysis' Apple default render (`mode .appleDefault`, local tone
    /// map = the file's default, 0 on Bayer files). The stage-1 image and the probes use DecisionEngine's settings for
    /// this file (no plugin, no stock) + the colour source, at the decode exposure; `differsFromDelivered` lists the decode
    /// fields where the delivered decode differs (stock-dependent: highlightRecovery EDR, filmDevelop sharpening / NR /
    /// clarity / ProRAW detail and local tone map).
    public struct Stage1Decode: Codable, Equatable, Sendable {
        public var decoderVersion: String
        public var anchorLocalToneMapAmount: Float
        public var localToneMapAmount: Float
        public var probeLongEdge: Int
        public var measureLongEdge: Int
        public var differsFromDelivered: [String] = []
    }

    /// What the bright-scene blend did (option C, PROVISIONAL). `ev100` = `inputs.ev100` (log2(N²/t) − log2(ISO/100):
    /// N = EXIF FNumber of the DNG, t and ISO = the analysis `SceneContext.exposureTime` / `iso`). `weight` = w.
    /// `effectiveClipTopCode8bit` / `effectiveMaxRestoreEV` = the highlight code and restore bound the delivered solve used
    /// (today's values when w = 0). `todayRestoreEV` = g254 (gain under today's rule), `wantedRestoreEV` = gWanted (the
    /// median's gain with the blend's bound, before any highlight rule); both nil when w = 0 or not applied.
    /// `blendedRestoreEV` = the gain of the blended pass; `clampedToToday` = true when it was below g254 and today's pass was
    /// kept (N1, User 2026-11-19; then `applied` is false and the effective values are today's). `applied` = the blended
    /// pass is the delivered one.
    public struct BrightSceneBlendRecord: Codable, Equatable, Sendable {
        public static let defaultBlend = "restore bound = g254 + w*(gWanted - g254), quantised 0.01 EV, solved under the blend's clip code when w > 0 (film-lab option C emulation); delivered gain never below g254"
        public static let defaultStatus = "provisional: ramp ends 9/13 EV100, code 255 and 2.5 EV fitted to 6 bright frames from one phone (PIPELINE_V2_CONTRACT round 9)"
        public var ev100: Double?
        public var weight: Double
        public var applied: Bool
        public var effectiveClipTopCode8bit: Int
        public var effectiveMaxRestoreEV: Double
        public var todayRestoreEV: Double?
        public var wantedRestoreEV: Double?
        public var blendedRestoreEV: Double?
        public var clampedToToday: Bool?
        public var blend: String = BrightSceneBlendRecord.defaultBlend
        public var parametersStatus: String = BrightSceneBlendRecord.defaultStatus
        public var notes: [String] = []

        public init(ev100: Double?, weight: Double, applied: Bool, effectiveClipTopCode8bit: Int, effectiveMaxRestoreEV: Double,
                    todayRestoreEV: Double? = nil, wantedRestoreEV: Double? = nil, blendedRestoreEV: Double? = nil,
                    clampedToToday: Bool? = nil, notes: [String] = []) {
            self.ev100 = ev100; self.weight = weight; self.applied = applied
            self.effectiveClipTopCode8bit = effectiveClipTopCode8bit; self.effectiveMaxRestoreEV = effectiveMaxRestoreEV
            self.todayRestoreEV = todayRestoreEV; self.wantedRestoreEV = wantedRestoreEV
            self.blendedRestoreEV = blendedRestoreEV; self.clampedToToday = clampedToToday; self.notes = notes
        }

        /// Fields with a default (`blend`, `parametersStatus`, `notes`) may be absent from the JSON.
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            ev100 = try c.decodeIfPresent(Double.self, forKey: .ev100)
            weight = try c.decode(Double.self, forKey: .weight)
            applied = try c.decode(Bool.self, forKey: .applied)
            effectiveClipTopCode8bit = try c.decode(Int.self, forKey: .effectiveClipTopCode8bit)
            effectiveMaxRestoreEV = try c.decode(Double.self, forKey: .effectiveMaxRestoreEV)
            todayRestoreEV = try c.decodeIfPresent(Double.self, forKey: .todayRestoreEV)
            wantedRestoreEV = try c.decodeIfPresent(Double.self, forKey: .wantedRestoreEV)
            blendedRestoreEV = try c.decodeIfPresent(Double.self, forKey: .blendedRestoreEV)
            clampedToToday = try c.decodeIfPresent(Bool.self, forKey: .clampedToToday)
            blend = try c.decodeIfPresent(String.self, forKey: .blend) ?? Self.defaultBlend
            parametersStatus = try c.decodeIfPresent(String.self, forKey: .parametersStatus) ?? Self.defaultStatus
            notes = try c.decodeIfPresent([String].self, forKey: .notes) ?? []
        }
    }
}
