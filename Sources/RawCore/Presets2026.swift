import Foundation

/// Drop 2026 presets (brief "tune 7 preset skeleton", 2026-11-07), named `PRESET_26_*`.
///
/// What is from the spec and what is not:
/// - **From the spec (§3–§5 params):** exposure, white balance (temperature / tint), saturation, vibrance, shadows,
///   highlights, grain amount / size, vignette, skinProtect, default intensity (60 %, social-pop 80 %).
/// - **Provisional (marked `curveLocked = false`):** the tone-curve / per-channel "direction" (`PresetCurve`). The
///   brief only describes it in words and says the numbers designers lock in Lightroom/DaVinci are the real ones.
///   The values here only follow those words, so a render shows the intended direction. When a designer `.cube`
///   exists, pass it as `look` together with the stock: the explicit look replaces this curve and the stock's
///   finish (grain/vignette) is kept.
/// - Display names never contain film-brand trademarks; `specId` is the internal id used in the spec/JSON.
///
/// Mapping assumptions (documented, to be checked against the designer's Lightroom values):
/// - Temperature is relative to 5500 K (Chrome 64 = 5500 K / neutral): 5900 K renders warmer, 5400 K cooler,
///   i.e. Lightroom semantics. Tint: + = magenta, − = green, 0.25 % green gain per unit.
/// - Shadows / highlights ±1 move luma by at most ±0.12 (encoded) around 1/3 and 2/3.
/// - Grain size 1.0 = 0.07 % of the short edge (the engine's default cell).
public struct PresetLookParams: Codable, Equatable, Sendable {
    public var exposureEV: Float
    public var temperatureK: Float
    public var tint: Float
    public var saturation: Float
    public var vibrance: Float
    public var shadows: Float
    public var highlights: Float
    public var curve: PresetCurve

    public init(exposureEV: Float, temperatureK: Float, tint: Float, saturation: Float = 1, vibrance: Float = 0,
                shadows: Float = 0, highlights: Float = 0, curve: PresetCurve) {
        self.exposureEV = exposureEV; self.temperatureK = temperatureK; self.tint = tint; self.saturation = saturation
        self.vibrance = vibrance; self.shadows = shadows; self.highlights = highlights; self.curve = curve
    }

    public static let referenceTemperatureK: Float = 5500
}

/// Tone-curve direction. Channel offsets are hue-only (their luma is removed), weighted toward shadows
/// ((1−y)²), mid-tones (4y(1−y)) or highlights (y²).
public struct PresetCurve: Codable, Equatable, Sendable {
    /// Black-point lift (0 = none).
    public var toe: Float
    /// S-curve strength around mid grey (1 = none, < 1 softer, > 1 punchier).
    public var contrast: Float
    public var shadowRGB: SIMD3<Float>
    public var midRGB: SIMD3<Float>
    public var highlightRGB: SIMD3<Float>

    public init(toe: Float = 0, contrast: Float = 1, shadowRGB: SIMD3<Float> = .zero, midRGB: SIMD3<Float> = .zero,
                highlightRGB: SIMD3<Float> = .zero) {
        self.toe = toe; self.contrast = contrast; self.shadowRGB = shadowRGB; self.midRGB = midRGB; self.highlightRGB = highlightRGB
    }
}

public struct Preset26: Equatable, Sendable {
    public enum Tier: String, Codable, Sendable { case free, pro }
    public enum Group: String, Codable, Sendable { case film, digicam, cinematic }

    /// App name, `PRESET_26_*`.
    public var name: String
    /// Id in the spec / JSON (internal only).
    public var specId: String
    public var tier: Tier
    public var priority: String
    public var group: Group
    public var vibe: String
    public var params: PresetLookParams
    public var finish: FilmFinish
    public var intensity: Float
    public var skinProtect: Bool
    /// false until a designer locks real curve numbers (brief: "không bịa số curve").
    public var curveLocked: Bool
    /// Open questions found while implementing (shown in docs, not guessed).
    public var openQuestions: [String]

    public func lut(size: Int = 33) -> CubeLUT {
        let p = params
        let gains = Preset26.whiteBalanceGains(temperatureK: p.temperatureK, tint: p.tint) * pow(2, p.exposureEV)
        return CubeLUT.generate(size: size, title: name) { Preset26.apply($0, p, gains: gains) }
    }

    public var stock: FilmStock {
        FilmStock(name: name, source: .preset(params), lookIntensity: intensity, finish: finish,
                  summary: "\(tier.rawValue) · \(group.rawValue) · \(vibe)" + (curveLocked ? "" : " (curve provisional)"),
                  minSkinProtection: skinProtect ? 0.5 : nil)
    }

    // MARK: colour

    static let lumaEncoded = SIMD3<Float>(0.2126, 0.7152, 0.0722)
    /// Display P3 linear luminance weights.
    static let lumaLinear = SIMD3<Float>(0.22897, 0.69174, 0.07929)

    static func decode(_ v: Float) -> Float { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
    static func encode(_ v: Float) -> Float { v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1 / 2.4) - 0.055 }

    /// Planckian chromaticity (Kim et al. 2002 cubic fit, 1667–25000 K).
    static func planckXY(_ tK: Float) -> SIMD2<Float> {
        let t = Double(min(max(tK, 1667), 25000))
        let x: Double = t <= 4000
            ? -0.2661239e9 / (t * t * t) - 0.2343589e6 / (t * t) + 0.8776956e3 / t + 0.179910
            : -3.0258469e9 / (t * t * t) + 2.1070379e6 / (t * t) + 0.2226347e3 / t + 0.240390
        let y: Double
        if t <= 2222 { y = -1.1063814 * x * x * x - 1.34811020 * x * x + 2.18555832 * x - 0.20219683 }
        else if t <= 4000 { y = -0.9549476 * x * x * x - 1.37418593 * x * x + 2.09137015 * x - 0.16748867 }
        else { y = 3.0817580 * x * x * x - 5.8733867 * x * x + 3.75112997 * x - 0.37001483 }
        return SIMD2(Float(x), Float(y))
    }

    static func p3Linear(xy: SIMD2<Float>) -> SIMD3<Float> {
        let X = xy.x / xy.y, Y: Float = 1, Z = (1 - xy.x - xy.y) / xy.y
        return SIMD3(2.4934969 * X - 0.9313836 * Y - 0.4027108 * Z,
                     -0.8294890 * X + 1.7626641 * Y + 0.0236247 * Z,
                     0.0358458 * X - 0.0761724 * Y + 0.9568845 * Z)
    }

    /// Linear gains that re-balance an image rendered for the reference white as if the light were `temperatureK`
    /// (higher K → warmer, Lightroom semantics), plus tint; normalised to keep luminance.
    public static func whiteBalanceGains(temperatureK: Float, tint: Float) -> SIMD3<Float> {
        let ref = p3Linear(xy: planckXY(PresetLookParams.referenceTemperatureK)), tgt = p3Linear(xy: planckXY(temperatureK))
        var g = ref / tgt
        g.y *= 1 - 0.0025 * tint
        return g / (g * lumaLinear).sum()
    }

    static func apply(_ c: SIMD3<Float>, _ p: PresetLookParams, gains: SIMD3<Float>) -> SIMD3<Float> {
        let w = lumaEncoded
        // 1. White balance + exposure in linear light.
        let lin = SIMD3(decode(c.x), decode(c.y), decode(c.z)) * gains
        var e = SIMD3(encode(max(lin.x, 0)), encode(max(lin.y, 0)), encode(max(lin.z, 0)))
        // 2. Tone on luma (hue-stable, same scheme as BuiltInLook.film): shadows/highlights, S-curve, soft shoulder, toe.
        let y = max((e * w).sum(), 0)
        let k = p.curve.contrast
        func tone(_ v0: Float) -> Float {
            var v = v0
            v += p.shadows * 0.12 * 6.75 * min(v, 1) * pow(max(1 - v, 0), 2)
            v += p.highlights * 0.12 * 6.75 * min(v, 1) * min(v, 1) * max(1 - v, 0)
            let s = min(max(v, 0), 1.5)
            var o = s < 0.5 ? 0.5 * pow(2 * s, k) : (s <= 1 ? 1 - 0.5 * pow(2 * (1 - s), k) : s)
            // Soft shoulder with an asymptote below 1: with +0.2 EV, white must still roll off, not clip.
            let shoulder: Float = 0.88, top: Float = 0.985
            if o > shoulder { o = shoulder + (top - shoulder) * tanh((o - shoulder) / (top - shoulder)) }
            return o
        }
        let yc = tone(y)
        let ratio = y > 1e-4 ? min(yc / y, 2) : 1
        e = e * ratio + SIMD3(repeating: max(yc - y * ratio, 0))
        let toe = p.curve.toe
        e = SIMD3(repeating: toe) + e * (1 - toe)
        let yt = toe + (1 - toe) * yc
        // 3. Hue-only channel offsets by tonal zone.
        func hueOnly(_ v: SIMD3<Float>) -> SIMD3<Float> { v - SIMD3(repeating: (v * w).sum()) }
        let yz = min(max(yt, 0), 1)
        e += hueOnly(p.curve.shadowRGB) * (1 - yz) * (1 - yz)
        e += hueOnly(p.curve.midRGB) * 4 * yz * (1 - yz)
        e += hueOnly(p.curve.highlightRGB) * yz * yz
        // 4. Saturation + vibrance (vibrance boosts muted colours more), then fit into gamut by desaturating
        //    toward luma instead of clipping a channel (keeps saturated reds dense, not neon).
        let yo = (e * w).sum()
        let mx = e.max(), mn = e.min()
        let currentSat = mx > 1e-4 ? (mx - mn) / mx : 0
        let s = p.saturation * (1 + p.vibrance * (1 - min(currentSat, 1)))
        var chroma = (e - SIMD3(repeating: yo)) * s
        // Ceiling 0.99, not 1: a warm white balance would otherwise push R of pure white to a hard clip.
        let ceiling: Float = 0.99
        var t: Float = 1
        for i in 0..<3 {
            let c = chroma[i]
            if c > 0, yo + c > ceiling { t = min(t, max(ceiling - yo, 0) / c) }
            if c < 0, yo + c < 0 { t = min(t, -yo / c) }
        }
        chroma *= max(t, 0)
        return SIMD3(repeating: yo) + chroma
    }

    // MARK: the seven presets (brief order: P0, P1, P2)

    public static let all: [Preset26] = [
        Preset26(name: "PRESET_26_CPM35", specId: "cpm35", tier: .free, priority: "P0", group: .digicam,
                 vibe: "dreamy digicam, light green tint (street, cafe, film dump)",
                 params: PresetLookParams(exposureEV: 0.10, temperatureK: 5400, tint: -6, saturation: 0.95,
                                          curve: PresetCurve(toe: 0.03, contrast: 0.92, shadowRGB: SIMD3(-0.006, 0.010, -0.004),
                                                             midRGB: SIMD3(-0.003, 0.005, -0.002))),
                 finish: FilmFinish(grainAmount: 0.40, grainSize: 0.07 * 1.2, vignette: 0.25),
                 intensity: 0.6, skinProtect: false, curveLocked: false, openQuestions: []),
        Preset26(name: "PRESET_26_PORTRAIT160", specId: "portra-160", tier: .pro, priority: "P1", group: .film,
                 vibe: "pale, bright, light & airy; whites stay clean",
                 params: PresetLookParams(exposureEV: 0.20, temperatureK: 5700, tint: 2, saturation: 0.95, shadows: 0.30,
                                          curve: PresetCurve(toe: 0.045, contrast: 0.94, shadowRGB: SIMD3(0.008, 0, -0.008))),
                 finish: FilmFinish(grainAmount: 0.25, grainSize: 0.07),
                 intensity: 0.6, skinProtect: false, curveLocked: false, openQuestions: []),
        Preset26(name: "PRESET_26_SOFT400", specId: "fuji-400h", tier: .pro, priority: "P1", group: .film,
                 vibe: "pastel, bright pink skin, muted greens",
                 params: PresetLookParams(exposureEV: 0.20, temperatureK: 5800, tint: -2, saturation: 0.90, shadows: 0.30,
                                          curve: PresetCurve(toe: 0.03, contrast: 0.95, shadowRGB: SIMD3(0.005, -0.004, 0.002),
                                                             midRGB: SIMD3(0.004, -0.003, 0.001))),
                 finish: FilmFinish(grainAmount: 0.30, grainSize: 0.07),
                 intensity: 0.6, skinProtect: false, curveLocked: false,
                 openQuestions: ["spec display name \"Fuji Soft 400\" contains a trademark (checklist forbids it); app name used here: PRESET_26_SOFT400"]),
        Preset26(name: "PRESET_26_CHROME64", specId: "kodachrome-64", tier: .pro, priority: "P1", group: .film,
                 vibe: "deep reds, rich yellows, deep blacks, high contrast",
                 params: PresetLookParams(exposureEV: 0.0, temperatureK: 5500, tint: 2, saturation: 1.15, vibrance: 0.35,
                                          shadows: -0.10, highlights: -0.40,
                                          curve: PresetCurve(toe: 0, contrast: 1.18, midRGB: SIMD3(0.012, 0.002, -0.012))),
                 finish: FilmFinish(),
                 intensity: 0.6, skinProtect: false, curveLocked: false,
                 openQuestions: ["spec gives no grain for Chrome 64: none applied"]),
        Preset26(name: "PRESET_26_GOLDEN_R", specId: "grd-r", tier: .pro, priority: "P2", group: .digicam,
                 vibe: "light yellow film effect (selfie, everyday)",
                 params: PresetLookParams(exposureEV: 0.15, temperatureK: 5900, tint: 4, saturation: 1.0,
                                          curve: PresetCurve(toe: 0.03, contrast: 0.95, shadowRGB: SIMD3(0.006, 0.004, -0.010))),
                 finish: FilmFinish(grainAmount: 0.35, grainSize: 0.07 * 1.1),
                 intensity: 0.6, skinProtect: false, curveLocked: false,
                 openQuestions: ["group B says vignette is identity, but the spec has no vignette value for grd-r: none applied until PO gives one"]),
        Preset26(name: "PRESET_26_PALM_SPRINGS", specId: "palm-springs", tier: .pro, priority: "P2", group: .cinematic,
                 vibe: "cyan sky + warm earth tones, sun-drenched summer",
                 params: PresetLookParams(exposureEV: 0.15, temperatureK: 5700, tint: -3, saturation: 1.15, vibrance: 0.30,
                                          curve: PresetCurve(toe: 0.01, contrast: 1.06, midRGB: SIMD3(0.008, 0, -0.008),
                                                             highlightRGB: SIMD3(-0.010, 0.002, 0.010))),
                 finish: FilmFinish(grainAmount: 0.20, grainSize: 0.07),
                 intensity: 0.6, skinProtect: true, curveLocked: false,
                 openQuestions: ["PO decision pending: ship palm-springs or social-pop (spec counts 20, folder has 21)"]),
        Preset26(name: "PRESET_26_SOCIAL_POP", specId: "social-pop", tier: .pro, priority: "P2", group: .cinematic,
                 vibe: "Story/Reels 9:16: contrast + saturation for stop-scroll",
                 params: PresetLookParams(exposureEV: 0.10, temperatureK: 5600, tint: 0, saturation: 1.20, vibrance: 0.40,
                                          shadows: -0.05, curve: PresetCurve(toe: 0, contrast: 1.10)),
                 finish: FilmFinish(),
                 intensity: 0.8, skinProtect: true, curveLocked: false,
                 openQuestions: ["test at 9:16 full-screen crop (UI concern, not the engine)",
                                 "PO decision pending: separate Story preset vs 80 % intensity of a feed LUT"]),
    ]

    public static func named(_ n: String) -> Preset26? { all.first { $0.name == n } }
}
