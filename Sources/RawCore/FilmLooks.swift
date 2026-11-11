import Foundation

/// The 2026 film-look set that replaces MoodRoll's looks (AGENTS.md, decided 2026-11-09; research and traits:
/// `.orchestration/looks/LOOKS_RESEARCH.md`). Every look is a `LookSpec`: measurable parameters, generated in code
/// into a 33³ cube in encoded Display P3 (display-referred, applied on the base render). Names are generic; the film
/// family each one is modelled on stays in the research note, never in user-facing strings.
///
/// Order inside a look: white balance (linear light) → tone curve on luma (black point, S-contrast, soft shoulder)
/// → colour in OKLCh (per-hue shifts, saturation, highlight/shadow desaturation, split toning) → gamut fit by
/// reducing chroma at constant lightness (never a hard channel clip) → encode. Mono looks mix channels to grey.
public struct LookSpec: Equatable, Sendable {
    /// One hue band in OKLCh: centre and half-width (degrees), hue rotation (degrees), chroma scale and relative
    /// lightness change inside it (−0.05 = 5 % darker; the per-colour "luminance" slider of a film grade). Lightness
    /// fades in with chroma (full from C = 0.05), so greys and near-greys never move.
    public struct HueBand: Equatable, Sendable {
        public var centre: Float, width: Float, shift: Float, chroma: Float, lightness: Float
        public init(_ centre: Float, width: Float = 35, shift: Float = 0, chroma: Float = 1, lightness: Float = 0) {
            self.centre = centre; self.width = width; self.shift = shift; self.chroma = chroma; self.lightness = lightness
        }
    }

    /// White balance of the look: target temperature (K, 5500 = neutral) and tint (+ magenta, − green).
    public var temperatureK: Float = 5500
    public var tint: Float = 0
    /// Encoded output level of input black (toe lift, 0 = none).
    public var black: Float = 0
    /// S-curve exponent around `pivot` (1 = none, > 1 punchier, < 1 softer).
    public var contrast: Float = 1
    public var pivot: Float = 0.42
    /// Soft shoulder: above `shoulder` the curve rolls off toward `white` (white ≥ 1 and shoulder ≥ 1 = hard clip).
    public var shoulder: Float = 0.86
    public var white: Float = 0.985
    /// Global chroma scale; reduced toward white by `highlightDesat` and toward black by `shadowDesat`.
    public var saturation: Float = 1
    public var highlightDesat: Float = 0.25
    public var shadowDesat: Float = 0
    /// Subtractive dye density: saturated colours get darker, not brighter (film dyes absorb; digital adds light).
    /// Lightness × (1 − density · min(C / 0.2, 1)) in OKLab; greys untouched. Keeps strong reds deep instead of neon.
    public var density: Float = 0
    /// Sky hold (0 = off): bright blue input pixels keep their own white balance, at least their own chroma and most
    /// of their tone, so a soft, warm look does not wash the sky to milk (same rule as `PresetLookParams.skyHold`).
    public var skyHold: Float = 0
    public var bands: [HueBand] = []
    /// Split toning: OKLab (a, b) added in shadows (weight 6.75·L·(1−L)², peak at L = 1/3, zero at black so black
    /// stays neutral) and highlights (weight L²).
    public var shadowTint: SIMD2<Float> = .zero
    public var highlightTint: SIMD2<Float> = .zero
    /// Black and white: luminance from these channel weights (linear P3), then grey. nil = colour look.
    public var monoWeights: SIMD3<Float>? = nil
    /// Declared exceptions, so the acceptance tests know what the look is allowed to do.
    public var allowsClip = false
    public var neutralDrift: Float = 0.012   // max OKLab chroma of a grey input after the look
    /// Cube size the look ships at: 65³ for colour looks (33³ leaves an interpolation tail at saturated gamut corners,
    /// FilmLooksTests.testOffGridInterpolationError), 33³ is plenty for mono.
    public var cubeSize: Int { monoWeights == nil ? 65 : 33 }
    public var skinTolerance: Float = 8      // max skin hue shift (degrees) before skin protection

    public init() {}

    public func lut(size: Int = 33, title: String? = nil) -> CubeLUT {
        let gains = Preset26.whiteBalanceGains(temperatureK: temperatureK, tint: tint)
        return CubeLUT.generate(size: size, title: title) { apply($0, gains: gains) }
    }

    // MARK: Look function (encoded P3 in → encoded P3 out)

    func tone(_ y: Float) -> Float {
        let v = min(max(y, 0), 1)
        let p = pivot
        let s = v < p ? p * pow(v / p, contrast) : 1 - (1 - p) * pow((1 - v) / (1 - p), contrast)
        var o = s
        if shoulder < 1, o > shoulder {
            let top = max(white, shoulder + 1e-3)
            o = shoulder + (top - shoulder) * tanh((o - shoulder) / (top - shoulder))
        }
        return black + (1 - black) * o
    }

    func apply(_ c: SIMD3<Float>, gains: SIMD3<Float>) -> SIMD3<Float> {
        typealias O = OKLab
        let sky = skyHold <= 0 || monoWeights != nil ? 0 : min(skyHold, 1) * Preset26.skyWeight(c)
        let linIn = SIMD3(Preset26.decode(c.x), Preset26.decode(c.y), Preset26.decode(c.z))
        var lin = linIn * (gains + (SIMD3<Float>(repeating: 1) - gains) * sky)
        if let w = monoWeights {
            let g = max((lin * w).sum() / w.sum(), 0)
            let t = tone(Preset26.encode(g))
            return SIMD3(repeating: t)
        }
        // Tone on encoded luma; colour follows by the luma ratio, any shortfall added as neutral grey (stable hue,
        // no noise blow-up in deep shadows — same scheme as BuiltInLook.film).
        var e = SIMD3(Preset26.encode(max(lin.x, 0)), Preset26.encode(max(lin.y, 0)), Preset26.encode(max(lin.z, 0)))
        let y = max((e * Preset26.lumaEncoded).sum(), 0)
        let yt = tone(y)
        let ratio = y > 1e-4 ? min(yt / y, 2) : 1
        e = e * ratio + SIMD3(repeating: max(yt - y * ratio, 0))
        lin = SIMD3(Preset26.decode(e.x), Preset26.decode(e.y), Preset26.decode(e.z))

        // Colour in OKLCh.
        var lab = O.fromLinearP3(lin)
        let L = min(max(lab.x, 0), 1)
        var ch = (lab.y * lab.y + lab.z * lab.z).squareRoot()
        var h = atan2(lab.z, lab.y) * 180 / .pi
        var shift: Float = 0, scale: Float = 1, light: Float = 1
        for b in bands {
            var d = abs(h - b.centre).truncatingRemainder(dividingBy: 360)
            if d > 180 { d = 360 - d }
            guard d < b.width else { continue }
            let w = 0.5 * (1 + cos(.pi * d / b.width))            // smooth raised-cosine weight
            shift += b.shift * w
            scale *= 1 + (b.chroma - 1) * w
            light *= 1 + b.lightness * w
        }
        h += shift
        let chromaWeight = min(ch / 0.05, 1)
        lab.x *= (1 + (light - 1) * chromaWeight) * (1 - density * min(ch / 0.2, 1))
        let tonal = saturation * (1 - highlightDesat * L * L * L) * (1 - shadowDesat * (1 - L) * (1 - L))
        ch *= max(scale * tonal, 0)
        if sky > 0 {
            let labIn = O.fromLinearP3(linIn)
            let chIn = (labIn.y * labIn.y + labIn.z * labIn.z).squareRoot()
            ch += (max(chIn, ch) - ch) * sky
        }
        let rad = h * .pi / 180
        lab = SIMD3(lab.x, ch * cos(rad), ch * sin(rad))
        let ws = 6.75 * L * (1 - L) * (1 - L), wh = L * L
        lab.y += shadowTint.x * ws + highlightTint.x * wh
        lab.z += shadowTint.y * ws + highlightTint.y * wh

        // Gamut fit: keep lightness, shrink chroma until the encoded result sits in [0, ceiling].
        let ceiling: Float = allowsClip ? 1 : 0.99
        func encoded(_ k: Float) -> SIMD3<Float> {
            let l = O.toLinearP3(SIMD3(lab.x, lab.y * k, lab.z * k))
            return SIMD3(Preset26.encode(max(l.x, 0)), Preset26.encode(max(l.y, 0)), Preset26.encode(max(l.z, 0)))
        }
        func fits(_ k: Float) -> Bool {
            let l = O.toLinearP3(SIMD3(lab.x, lab.y * k, lab.z * k))
            return l.min() >= -1e-4 && Preset26.encode(max(l.max(), 0)) <= ceiling
        }
        var out: SIMD3<Float>
        if fits(1) { out = encoded(1) } else {
            var lo: Float = 0, hi: Float = 1
            for _ in 0..<12 { let m = (lo + hi) / 2; if fits(m) { lo = m } else { hi = m } }
            let o = encoded(lo)
            out = SIMD3(min(o.x, ceiling), min(o.y, ceiling), min(o.z, ceiling))
        }
        // The sky keeps most of its own tone (toe, soft contrast and shoulder flatten its gradient).
        return sky > 0 ? out + (SIMD3(min(c.x, ceiling), min(c.y, ceiling), min(c.z, ceiling)) - out) * (0.6 * sky) : out
    }
}

/// OKLab (Ottosson 2020) on linear Display P3 (D65): perceptual lightness, chroma and hue for look design and tests.
public enum OKLab {
    static let p3ToXYZ: [Float] = [0.4865709, 0.2656677, 0.1982173, 0.2289746, 0.6917385, 0.0792869, 0.0, 0.0451134, 1.0439444]
    static let xyzToP3: [Float] = [2.4934969, -0.9313836, -0.4027108, -0.8294890, 1.7626641, 0.0236247, 0.0358458, -0.0761724, 0.9568845]
    static let m1: [Float] = [0.8189330101, 0.3618667424, -0.1288597137, 0.0329845436, 0.9293118715, 0.0361456387, 0.0482003018, 0.2643662691, 0.6338517070]
    static let m1Inv: [Float] = [1.2270138511, -0.5577999807, 0.2812561490, -0.0405801784, 1.1122568696, -0.0716766787, -0.0763812845, -0.4214819784, 1.5861632204]
    static let m2: [Float] = [0.2104542553, 0.7936177850, -0.0040720468, 1.9779984951, -2.4285922050, 0.4505937099, 0.0259040371, 0.7827717662, -0.8086757660]
    static let m2Inv: [Float] = [1, 0.3963377774, 0.2158037573, 1, -0.1055613458, -0.0638541728, 1, -0.0894841775, -1.2914855480]

    static func mul(_ m: [Float], _ v: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3(m[0] * v.x + m[1] * v.y + m[2] * v.z, m[3] * v.x + m[4] * v.y + m[5] * v.z, m[6] * v.x + m[7] * v.y + m[8] * v.z)
    }
    static func cbrt(_ v: Float) -> Float { v < 0 ? -pow(-v, 1 / 3) : pow(v, 1 / 3) }

    public static func fromLinearP3(_ c: SIMD3<Float>) -> SIMD3<Float> {
        let lms = mul(m1, mul(p3ToXYZ, c))
        return mul(m2, SIMD3(cbrt(lms.x), cbrt(lms.y), cbrt(lms.z)))
    }
    public static func toLinearP3(_ lab: SIMD3<Float>) -> SIMD3<Float> {
        let l = mul(m2Inv, lab)
        return mul(xyzToP3, mul(m1Inv, l * l * l))
    }
    /// (L, C, h°) of an encoded Display P3 colour.
    public static func lch(encodedP3 c: SIMD3<Float>) -> SIMD3<Float> {
        let lab = fromLinearP3(SIMD3(Preset26.decode(c.x), Preset26.decode(c.y), Preset26.decode(c.z)))
        var h = atan2(lab.z, lab.y) * 180 / .pi
        if h < 0 { h += 360 }
        return SIMD3(lab.x, (lab.y * lab.y + lab.z * lab.z).squareRoot(), h)
    }
}

/// The 2026 set: 10 listed generated looks (declared LUT files come through `LookLibrary`).
public enum FilmLooks2026 {
    // OKLCh hue landmarks (degrees): red ≈ 25, skin ≈ 40–60 (ColorChecker skins ≈ 41), orange ≈ 55, yellow ≈ 100, green ≈ 140, cyan ≈ 200, blue ≈ 260.
    static func spec(_ f: (inout LookSpec) -> Void) -> LookSpec { var s = LookSpec(); f(&s); return s }

    public static let looks: [(name: String, summary: String, spec: LookSpec, intensity: Float, finish: FilmFinish, minSkin: Float?)] = [
        // Tuned 2026-11-10 (.orchestration/looks/LOOK_TUNE_2026-11-10.md): each look pushed further from the base and
        // from its neighbours; band `lightness` and `density` give film's deeper saturated colours (no neon reds).
        ("softPortrait", "light and airy portrait negative: bright open mids, lifted toe, luminous peach skin, soft olive greens, fine grain",
         spec { $0.temperatureK = 5700; $0.tint = 1; $0.black = 0.03; $0.contrast = 0.86; $0.pivot = 0.55; $0.shoulder = 0.84; $0.white = 0.98
             $0.saturation = 0.9; $0.highlightDesat = 0.3; $0.density = 0.05; $0.skyHold = 1
             $0.highlightTint = SIMD2(0.003, 0.004); $0.neutralDrift = 0.02
             $0.bands = [.init(55, width: 30, shift: 2, chroma: 0.96, lightness: 0.04), .init(100, width: 35, shift: -5, chroma: 0.85),
                         .init(140, width: 40, shift: -6, chroma: 0.75), .init(255, width: 40, shift: -8, chroma: 0.85)] },
         0.85, FilmFinish(grainAmount: 0.25, grainSize: 0.06, vignette: 0.05), nil),
        ("goldenDay", "warm faded everyday film: golden light, softly lifted blacks, gentle contrast, honey yellows, rich reds, olive foliage, visible grain",
         spec { $0.temperatureK = 6200; $0.tint = 1; $0.black = 0.034; $0.contrast = 1.0; $0.pivot = 0.55; $0.shoulder = 0.88; $0.white = 0.99; $0.saturation = 1.0; $0.highlightDesat = 0.35; $0.density = 0.03
             $0.shadowTint = SIMD2(0.002, 0.004); $0.highlightTint = SIMD2(0.003, 0.007); $0.neutralDrift = 0.035
             $0.bands = [.init(28, shift: 3, chroma: 1.12, lightness: -0.06), .init(55, width: 25, shift: -4, chroma: 0.72),
                         .init(95, width: 40, shift: -6, chroma: 1.2), .init(140, width: 40, shift: -10, chroma: 0.85),
                         .init(255, width: 40, shift: -8, lightness: -0.02)] },   // faded (trend 2026-11-10); roll consistency 2026-11-10: highlights up (bright frames were darkened 10-13 %)
         0.85, FilmFinish(grainAmount: 0.4, grainSize: 0.07, halationAmount: 0.1, halationThreshold: 0.9, halationRadius: 0.4, vignette: 0.04), nil),
        ("vividFine", "vivid memory colour: deep crimson reds, rich warm yellows, yellow-greens, deep cyan-leaning blues, clean deep blacks, fine grain",
         spec { $0.temperatureK = 5650; $0.tint = 1; $0.black = 0.006; $0.contrast = 1.18; $0.saturation = 1.16; $0.highlightDesat = 0.55; $0.shadowDesat = 0.1
             $0.density = 0.12; $0.shadowTint = SIMD2(0.003, -0.002)
             $0.bands = [.init(25, width: 35, shift: -3, chroma: 1.15, lightness: -0.07),
                         .init(100, width: 35, shift: -4, chroma: 1.18), .init(140, width: 40, shift: -6, chroma: 1.05, lightness: -0.04),
                         .init(255, width: 40, shift: -6, chroma: 1.1, lightness: -0.05)] },
         0.85, FilmFinish(grainAmount: 0.22, grainSize: 0.055, vignette: 0.05), nil),
        ("pastelCool", "pastel airy colour: soft contrast, lifted slate shadows, muted mint greens, rose skin, clean soft whites",
         spec { $0.temperatureK = 5400; $0.tint = 3; $0.black = 0.035; $0.contrast = 0.86; $0.pivot = 0.5; $0.shoulder = 0.82; $0.white = 0.975
             $0.saturation = 0.85; $0.highlightDesat = 0.2
             $0.shadowTint = SIMD2(-0.004, -0.008); $0.highlightTint = SIMD2(0.001, 0.002); $0.neutralDrift = 0.03
             $0.bands = [.init(55, width: 35, shift: -4, chroma: 1.22, lightness: 0.03), .init(100, width: 35, shift: 5, chroma: 0.8),
                         .init(140, width: 40, shift: 6, chroma: 0.75, lightness: 0.04), .init(255, width: 40, shift: -6, chroma: 0.8, lightness: 0.04)] },
         0.85, FilmFinish(grainAmount: 0.2, grainSize: 0.06), nil),
        ("everydayGreen", "everyday 400 colour: warm-muted analog, softly lifted blacks, emerald greens and green shadows, magenta-leaning reds, medium grain",
         spec { $0.temperatureK = 5650; $0.tint = -2; $0.black = 0.03; $0.contrast = 1.0; $0.pivot = 0.55; $0.shoulder = 0.88; $0.white = 0.99
             $0.saturation = 0.92; $0.highlightDesat = 0.36; $0.density = 0.03
             $0.shadowTint = SIMD2(-0.008, 0.003); $0.highlightTint = SIMD2(0.002, 0.006); $0.neutralDrift = 0.03
             $0.bands = [.init(28, shift: -6), .init(55, width: 25, shift: -3, chroma: 1.08), .init(140, width: 45, shift: 5, chroma: 1.05, lightness: -0.015),
                         .init(200, width: 40, chroma: 0.85)] },   // roll consistency 2026-11-10: bright frames were darkened up to 10.7 %
         0.85, FilmFinish(grainAmount: 0.45, grainSize: 0.075, vignette: 0.04), nil),
        ("tungstenGlow", "tungsten night film: cool teal daylight, neutral lamps, deep clean blacks, strong red-orange halation, big grain",
         spec { $0.temperatureK = 4700; $0.black = 0.012; $0.contrast = 1.08; $0.saturation = 0.98; $0.shadowDesat = 0.1; $0.density = 0.08
             $0.shadowTint = SIMD2(-0.01, -0.015); $0.neutralDrift = 0.06
             $0.bands = [.init(28, chroma: 1.05, lightness: -0.03), .init(255, width: 40, shift: -10)]
             $0.skinTolerance = 25 },   // tungsten film in daylight turns skin cool by design; held back on people (0.5)
         0.9, FilmFinish(grainAmount: 0.6, grainSize: 0.085, halationAmount: 0.45, halationThreshold: 0.85, halationRadius: 0.7, vignette: 0.1), 0.5),   // threshold 0.85: glow on lamps, not on daylit walls (0.6 clipped 8 % of a white room)
        ("mutedChrome", "muted chrome colour: low saturation, brick reds, olive greens, deep calm blues, firm shadows, warm highlights",
         spec { $0.black = 0.012; $0.contrast = 1.1; $0.pivot = 0.45; $0.saturation = 0.82; $0.highlightDesat = 0.35; $0.shadowDesat = 0.15
             $0.density = 0.08; $0.shadowTint = SIMD2(-0.002, -0.003); $0.highlightTint = SIMD2(0.002, 0.006); $0.neutralDrift = 0.02
             $0.bands = [.init(20, width: 25, shift: 4, chroma: 0.85), .init(45, width: 30, chroma: 1.3), .init(100, width: 35, shift: -6, chroma: 0.75),
                         .init(140, width: 40, shift: -8, chroma: 0.7), .init(255, width: 40, shift: -6, chroma: 0.85, lightness: -0.06)] },
         0.9, FilmFinish(grainAmount: 0.15, grainSize: 0.05), nil),
        ("monoSoft", "soft black and white: gentle contrast, open shadows, smooth highlights, strong grain",
         spec { $0.monoWeights = SIMD3(0.30, 0.59, 0.11); $0.black = 0.03; $0.contrast = 0.92; $0.pivot = 0.45; $0.shoulder = 0.84; $0.white = 0.975 },
         1, FilmFinish(grainAmount: 0.5, grainSize: 0.08, vignette: 0.1), nil),
        ("monoPunch", "punchy black and white: deep velvety blacks, darkened skies, crisp highlights, gritty grain",
         spec { $0.monoWeights = SIMD3(0.42, 0.53, 0.05); $0.black = 0.006; $0.contrast = 1.3; $0.pivot = 0.4; $0.shoulder = 0.88 },
         1, FilmFinish(grainAmount: 0.65, grainSize: 0.08, vignette: 0.15), nil),
        ("flashDigicam", "early digital compact: hard contrast, clipped whites, cool-green cast, bright saturated colour, flash falloff",
         spec { $0.temperatureK = 5200; $0.tint = -4; $0.black = 0; $0.contrast = 1.2; $0.shoulder = 1; $0.white = 1
             $0.saturation = 1.1; $0.highlightDesat = 0.1; $0.allowsClip = true; $0.neutralDrift = 0.04
             $0.shadowTint = SIMD2(-0.006, -0.002)
             $0.bands = [.init(140, width: 40, chroma: 1.1), .init(255, width: 40, shift: -6, chroma: 1.1)] },
         0.9, FilmFinish(grainAmount: 0.3, grainSize: 0.05, vignette: 0.3), nil),
    ]

    public static var names: [String] { looks.map(\.name) }

    public static let stocks: [FilmStock] = looks.map(stock)

    /// Looks the user took out of the launch set; kept in the library (resolvable by name, never listed).
    /// cinemaNegative (2026-11-10): too close to mutedChrome; night teal is tungstenGlow's job.
    public static let retiredLooks: [(name: String, summary: String, spec: LookSpec, intensity: Float, finish: FilmFinish, minSkin: Float?)] = [
        ("cinemaNegative", "cinema negative: firm contrast, deep crimson, amber yellows, dense desaturated greens, teal-leaning skies, skin held back",
         spec { $0.temperatureK = 5450; $0.black = 0.012; $0.contrast = 1.12; $0.shoulder = 0.84; $0.white = 0.98; $0.saturation = 0.9
             $0.highlightDesat = 0.35; $0.density = 0.1
             $0.shadowTint = SIMD2(-0.004, -0.004); $0.highlightTint = SIMD2(0.002, 0.005); $0.neutralDrift = 0.03
             $0.bands = [.init(25, width: 30, shift: -4, chroma: 1.1, lightness: -0.05), .init(55, width: 25, chroma: 1.05),
                         .init(100, width: 35, shift: -8, chroma: 0.8), .init(140, width: 45, shift: 6, chroma: 0.8, lightness: -0.05),
                         .init(240, width: 45, shift: -10, chroma: 0.9)] },   // colour separation by hue, not a global orange-teal split
         0.85, FilmFinish(grainAmount: 0.2, grainSize: 0.055, vignette: 0.08), 0.5),
    ]

    public static let retiredStocks: [FilmStock] = retiredLooks.map(stock)

    /// UNLISTED looks: they resolve through `FilmStock.named` (raw-bench looks, review tool) but are NOT in `names`,
    /// `stocks` or `FilmStock.all`, so the app does not list them. Candidates from the 2026 trend report
    /// (`.orchestration/looks/TREND_LOOK_PLAN_2026-11-10.md`; names chosen by the user 2026-11-10: brightTravel, sunFade,
    /// warmEvening; trialCoolFade waits for evidence). Promote one by moving it into `looks`.
    public static let trialLooks: [(name: String, summary: String, spec: LookSpec, intensity: Float, finish: FilmFinish, minSkin: Float?)] = [
        ("trialCoolFade", "cool faded 400: grey lifted blacks, low contrast, cool green-cyan shadows, muted colour, magenta-leaning reds, medium grain",
         spec { $0.temperatureK = 5250; $0.tint = -2; $0.black = 0.042; $0.contrast = 0.9; $0.pivot = 0.45; $0.shoulder = 0.84; $0.white = 0.965
             $0.saturation = 0.8; $0.highlightDesat = 0.3; $0.shadowDesat = 0.1; $0.density = 0.03
             $0.shadowTint = SIMD2(-0.012, -0.002); $0.highlightTint = SIMD2(0.003, -0.002); $0.neutralDrift = 0.035
             $0.bands = [.init(25, width: 30, shift: -6, chroma: 0.95), .init(42, width: 28, shift: 1, chroma: 1.5),
                         .init(100, width: 35, shift: 4, chroma: 0.75), .init(150, width: 45, shift: 8, chroma: 0.9, lightness: -0.02),
                         .init(235, width: 45, shift: -4, chroma: 0.85, lightness: 0.02)] },
         0.85, FilmFinish(grainAmount: 0.42, grainSize: 0.07, vignette: 0.08), nil),
        ("brightTravel", "clean vivid daylight: punchy contrast, saturated clean blues and emerald greens, true reds, bright whites, almost no grain",
         spec { $0.black = 0.008; $0.contrast = 1.15; $0.shoulder = 0.88; $0.saturation = 1.28; $0.highlightDesat = 0.5; $0.shadowDesat = 0.05
             $0.density = 0.05
             $0.bands = [.init(25, width: 30, chroma: 1.0), .init(45, width: 25, chroma: 0.8), .init(140, width: 40, shift: 3, chroma: 1.12),
                         .init(205, width: 35, chroma: 1.12), .init(255, width: 40, shift: -4, chroma: 1.15, lightness: -0.05)] },
         0.9, FilmFinish(grainAmount: 0.05, grainSize: 0.04), nil),
        ("warmEvening", "pushed warm moody: deeper mids, lifted brown blacks, muted warm palette, olive-brown greens, creamy highlights, coarse grain",
         spec { $0.temperatureK = 5900; $0.tint = 1; $0.black = 0.025; $0.contrast = 1.08; $0.pivot = 0.45; $0.shoulder = 0.82; $0.white = 0.97
             $0.saturation = 0.82; $0.highlightDesat = 0.35; $0.shadowDesat = 0.2; $0.density = 0.06
             $0.shadowTint = SIMD2(0.004, 0.006); $0.highlightTint = SIMD2(0.003, 0.008); $0.neutralDrift = 0.035
             $0.bands = [.init(28, width: 30, chroma: 1.0, lightness: -0.03), .init(45, width: 25, chroma: 1.15),
                         .init(95, width: 35, shift: -8, chroma: 0.85), .init(140, width: 45, shift: -12, chroma: 0.65, lightness: -0.04),
                         .init(255, width: 40, shift: -6, chroma: 0.7)] },
         0.85, FilmFinish(grainAmount: 0.5, grainSize: 0.085, halationAmount: 0.06, halationThreshold: 0.85, halationRadius: 0.5, vignette: 0.15), nil),
        ("sunFade", "expired warm film: strongly faded, grey-brown blacks, soft contrast, yellow-cream cast, muted greens and skies, heavy grain",
         spec { $0.temperatureK = 6000; $0.tint = 1; $0.black = 0.05; $0.contrast = 0.85; $0.pivot = 0.45; $0.shoulder = 0.8; $0.white = 0.95
             $0.saturation = 0.8; $0.highlightDesat = 0.35; $0.shadowDesat = 0.15
             $0.shadowTint = SIMD2(0.003, 0.008); $0.highlightTint = SIMD2(0.002, 0.008); $0.neutralDrift = 0.04
             $0.bands = [.init(28, width: 30, shift: 3, chroma: 0.95), .init(45, width: 25, shift: -3, chroma: 1.18),
                         .init(140, width: 45, shift: -12, chroma: 0.7), .init(255, width: 40, shift: -8, chroma: 0.7, lightness: 0.03)] },
         0.85, FilmFinish(grainAmount: 0.5, grainSize: 0.08, vignette: 0.12), nil),
        // Roll-stock looks (2026-11-11, .orchestration/looks/RR_LOOKS_2026-11-11.md): one look per RR stock character
        // that the shared looks could not carry (intensity alone is not character).
        ("mapleRed", "slow warm daylight film: deep crimson reds, clear cyan-teal blues and shadows, low-medium contrast, warm highlights, fine grain",
         spec { $0.temperatureK = 5900; $0.tint = 1; $0.black = 0.022; $0.contrast = 0.94; $0.pivot = 0.6; $0.shoulder = 0.88; $0.white = 0.99
             $0.saturation = 1.04; $0.highlightDesat = 0.35; $0.density = 0.05
             $0.shadowTint = SIMD2(-0.018, -0.010); $0.highlightTint = SIMD2(0.004, 0.008); $0.neutralDrift = 0.035
             $0.bands = [.init(22, width: 30, shift: -4, chroma: 1.35, lightness: -0.06), .init(55, width: 22, chroma: 1.05),
                         .init(100, width: 35, shift: -4, chroma: 1.05), .init(140, width: 40, shift: 8, chroma: 0.8, lightness: -0.01),
                         .init(205, width: 35, shift: -4, chroma: 1.4), .init(255, width: 40, shift: -20, chroma: 1.1, lightness: -0.02)] },
         0.85, FilmFinish(grainAmount: 0.18, grainSize: 0.05, halationAmount: 0.05, halationThreshold: 0.9, halationRadius: 0.4, vignette: 0.06), nil),
        ("warmMuted", "soft warm everyday 200: amber-red warmth, open mids, medium contrast, moderate colour, orange-red reds, pale yellows, muted greens, greyed cyan blues, clean blacks",
         spec { $0.temperatureK = 6100; $0.tint = 3; $0.black = 0.014; $0.contrast = 1.05; $0.pivot = 0.45; $0.shoulder = 0.86; $0.white = 0.985
             $0.saturation = 0.98; $0.highlightDesat = 0.3; $0.density = 0.05; $0.skyHold = 0.5
             $0.shadowTint = SIMD2(0.006, 0.002); $0.highlightTint = SIMD2(0.006, 0.004); $0.neutralDrift = 0.035
             $0.bands = [.init(24, width: 22, shift: 4, chroma: 1.22, lightness: -0.04), .init(52, width: 25, shift: -2, chroma: 0.92),
                         .init(95, width: 35, shift: -2, chroma: 0.8), .init(140, width: 45, shift: -4, chroma: 0.82),
                         .init(255, width: 40, shift: -10, chroma: 0.9)] },
         0.85, FilmFinish(grainAmount: 0.3, grainSize: 0.06, vignette: 0.06), nil),
        ("naturalPortrait", "natural portrait 400: true warm skin, medium contrast, moderate colour, warm shadows and highlights, soft rolloff, cyan-leaning blues",
         spec { $0.temperatureK = 5700; $0.tint = 1; $0.black = 0.016; $0.contrast = 1.02; $0.pivot = 0.48; $0.shoulder = 0.85; $0.white = 0.985
             $0.saturation = 1.07; $0.highlightDesat = 0.3; $0.density = 0.05; $0.skyHold = 0.6
             $0.shadowTint = SIMD2(0.002, 0.004); $0.highlightTint = SIMD2(0.002, 0.005); $0.neutralDrift = 0.025
             $0.bands = [.init(25, width: 25, chroma: 1.06, lightness: -0.03), .init(52, width: 28, shift: 1, chroma: 0.94, lightness: 0.02),
                         .init(100, width: 35, shift: -4, chroma: 0.9), .init(140, width: 40, shift: -4, chroma: 0.85),
                         .init(255, width: 40, shift: -8, chroma: 0.95)] },
         0.85, FilmFinish(grainAmount: 0.3, grainSize: 0.065, vignette: 0.04), nil),
        ("cleanLab", "clean lab scan: neutral colour, accurate skin, clean soft whites, gentle film toe and shoulder, deeper reds and blues, fine grain",
         spec { $0.temperatureK = 5500; $0.black = 0.02; $0.contrast = 1.0; $0.pivot = 0.45; $0.shoulder = 0.88; $0.white = 0.99
             $0.saturation = 1.0; $0.highlightDesat = 0.3; $0.density = 0.06; $0.neutralDrift = 0.012
             $0.bands = [.init(25, width: 30, chroma: 1.06, lightness: -0.04), .init(140, width: 40, shift: 2, chroma: 0.92, lightness: -0.02),
                         .init(255, width: 40, shift: -4, chroma: 1.05, lightness: -0.02)] },
         0.85, FilmFinish(grainAmount: 0.22, grainSize: 0.055, vignette: 0.03), nil),
    ]

    public static var trialNames: [String] { trialLooks.map(\.name) }

    public static let trialStocks: [FilmStock] = trialLooks.map(stock)

    static func stock(_ l: (name: String, summary: String, spec: LookSpec, intensity: Float, finish: FilmFinish, minSkin: Float?)) -> FilmStock {
        FilmStock(name: l.name, source: .spec(l.spec), lookIntensity: l.intensity, finish: l.finish, summary: l.summary,
                  allowsSkinProtection: l.spec.monoWeights == nil, minSkinProtection: l.minSkin)
    }
}
