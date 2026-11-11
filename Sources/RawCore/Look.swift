import Foundation

/// A 3D LUT in display-referred, transfer-encoded Display P3 (the domain .cube files are authored in).
/// Layout matches CIColorCube: red varies fastest, then green, then blue; RGBA float.
public struct CubeLUT: Equatable, Sendable {
    public let size: Int
    public var rgba: [Float]
    public var title: String?

    public init(size: Int, rgba: [Float], title: String? = nil) throws {
        guard (2...128).contains(size) else { throw RawCoreError.invalidLUT("size \(size) out of range 2...128") }
        guard rgba.count == size * size * size * 4 else {
            throw RawCoreError.invalidLUT("expected \(size * size * size * 4) floats, got \(rgba.count)")
        }
        self.size = size; self.rgba = rgba; self.title = title
    }

    public static func identity(size: Int = 33) -> CubeLUT {
        generate(size: size) { $0 }
    }

    /// Build a LUT from a function on encoded RGB in 0...1.
    public static func generate(size: Int, title: String? = nil, _ f: (SIMD3<Float>) -> SIMD3<Float>) -> CubeLUT {
        var data = [Float](repeating: 0, count: size * size * size * 4)
        let s = Float(size - 1)
        var o = 0
        for b in 0..<size {
            for g in 0..<size {
                for r in 0..<size {
                    let v = f(SIMD3(Float(r) / s, Float(g) / s, Float(b) / s))
                    data[o] = min(max(v.x, 0), 1); data[o + 1] = min(max(v.y, 0), 1); data[o + 2] = min(max(v.z, 0), 1)
                    data[o + 3] = 1
                    o += 4
                }
            }
        }
        // swiftlint:disable:next force_try
        return try! CubeLUT(size: size, rgba: data, title: title)
    }

    /// Parse an Adobe/Resolve .cube file (3D only). DOMAIN_MIN/MAX is the INPUT range the lattice spans (output
    /// values are stored as written); a non-default domain is resampled onto the 0…1 input range CIColorCube uses,
    /// inputs outside the domain clamp to its edge.
    public static func parse(_ text: String) throws -> CubeLUT {
        var size = 0
        var title: String?
        var dmin = SIMD3<Float>(0, 0, 0), dmax = SIMD3<Float>(1, 1, 1)
        var values: [Float] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            switch parts[0] {
            case "TITLE":
                title = line.dropFirst(5).trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            case "LUT_3D_SIZE":
                guard parts.count == 2, let n = Int(parts[1]) else { throw RawCoreError.invalidLUT("bad LUT_3D_SIZE: \(line)") }
                size = n
            case "LUT_1D_SIZE":
                throw RawCoreError.invalidLUT("1D LUTs are not supported")
            case "DOMAIN_MIN", "DOMAIN_MAX":
                guard parts.count == 4, let a = Float(parts[1]), let b = Float(parts[2]), let c = Float(parts[3]) else {
                    throw RawCoreError.invalidLUT("bad \(parts[0]): \(line)")
                }
                if parts[0] == "DOMAIN_MIN" { dmin = SIMD3(a, b, c) } else { dmax = SIMD3(a, b, c) }
            default:
                guard parts.count == 3, let a = Float(parts[0]), let b = Float(parts[1]), let c = Float(parts[2]) else {
                    throw RawCoreError.invalidLUT("unexpected line: \(line)")
                }
                values.append(contentsOf: [a, b, c, 1])
            }
        }
        guard size > 0 else { throw RawCoreError.invalidLUT("missing LUT_3D_SIZE") }
        guard all(dmax .> dmin) else { throw RawCoreError.invalidLUT("DOMAIN_MAX must be above DOMAIN_MIN") }
        let raw = try CubeLUT(size: size, rgba: values, title: title)
        if dmin == SIMD3(0, 0, 0), dmax == SIMD3(1, 1, 1) { return raw }
        // Lattice node i of the file sits at input dmin + i/(n−1)·(dmax − dmin): find each 0…1 input's place in it.
        return CubeLUT.generate(size: size, title: title) { c in raw.apply((c - dmin) / (dmax - dmin)) }
    }

    public static func load(_ url: URL) throws -> CubeLUT {
        try parse(String(contentsOf: url, encoding: .utf8))
    }

    /// True if the LUT maps saturated inputs to (near) neutral output: a black-and-white look.
    public var isMonochrome: Bool {
        let probes: [SIMD3<Float>] = [SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1), SIMD3(0.8, 0.5, 0.3), SIMD3(0.2, 0.4, 0.7)]
        return probes.allSatisfy { let o = apply($0); return o.max() - o.min() < 0.02 }
    }

    /// Trilinear lookup (CPU reference for tests and previews).
    public func apply(_ c: SIMD3<Float>) -> SIMD3<Float> {
        let s = Float(size - 1)
        let p = SIMD3(min(max(c.x, 0), 1), min(max(c.y, 0), 1), min(max(c.z, 0), 1)) * s
        let i0 = SIMD3<Int>(Int(p.x), Int(p.y), Int(p.z))
        let i1 = SIMD3<Int>(min(i0.x + 1, size - 1), min(i0.y + 1, size - 1), min(i0.z + 1, size - 1))
        let f = p - SIMD3<Float>(Float(i0.x), Float(i0.y), Float(i0.z))
        func at(_ r: Int, _ g: Int, _ b: Int) -> SIMD3<Float> {
            let o = ((b * size + g) * size + r) * 4
            return SIMD3(rgba[o], rgba[o + 1], rgba[o + 2])
        }
        func lerp(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ t: Float) -> SIMD3<Float> { a + (b - a) * t }
        let c00 = lerp(at(i0.x, i0.y, i0.z), at(i1.x, i0.y, i0.z), f.x)
        let c10 = lerp(at(i0.x, i1.y, i0.z), at(i1.x, i1.y, i0.z), f.x)
        let c01 = lerp(at(i0.x, i0.y, i1.z), at(i1.x, i0.y, i1.z), f.x)
        let c11 = lerp(at(i0.x, i1.y, i1.z), at(i1.x, i1.y, i1.z), f.x)
        return lerp(lerp(c00, c10, f.y), lerp(c01, c11, f.y), f.z)
    }
}

/// Parametric film looks generated in code (no third-party LUT assets). Applied on top of the
/// Apple-quality base render, so the look never has to repair tone or colour.
public enum BuiltInLook: String, CaseIterable, Sendable {
    case neutral
    /// Warm, soft-shouldered colour negative feel: lifted toe, gentle highlight roll-off,
    /// slight warm/teal split, saturation reduced in highlights.
    case warmNegative
    /// Cooler, punchier slide-film feel: deeper toe, more mid contrast, richer saturation.
    case coolSlide
    /// Black and white: luminance only, gentle S-curve, slightly lifted toe, neutral (r = g = b).
    case mono
    /// Tungsten-balanced night stock: pulls warm artificial light toward neutral, teal shadows, soft shoulder.
    /// Intentionally NOT neutral on daylight grey (it goes cool), like real tungsten film.
    case tungstenNight

    public func lut(size: Int = 33) -> CubeLUT {
        switch self {
        case .neutral:
            return .identity(size: size)
        case .warmNegative:
            return CubeLUT.generate(size: size, title: rawValue) { c in
                BuiltInLook.film(c, toe: 0.035, contrast: 0.92, shoulder: 0.9, warm: SIMD3(1.03, 1.0, 0.95),
                                 shadowTint: SIMD3(0.985, 1.0, 1.02), saturation: 0.92, highlightDesat: 0.35)
            }
        case .coolSlide:
            return CubeLUT.generate(size: size, title: rawValue) { c in
                BuiltInLook.film(c, toe: 0.0, contrast: 1.12, shoulder: 0.95, warm: SIMD3(0.98, 1.0, 1.03),
                                 shadowTint: SIMD3(1.0, 1.0, 1.0), saturation: 1.12, highlightDesat: 0.15)
            }
        case .mono:
            return CubeLUT.generate(size: size, title: rawValue) { c in
                let o = BuiltInLook.film(c, toe: 0.02, contrast: 1.08, shoulder: 0.9, warm: SIMD3(1, 1, 1),
                                         shadowTint: SIMD3(1, 1, 1), saturation: 0, highlightDesat: 0)
                let y = (o * SIMD3<Float>(0.2126, 0.7152, 0.0722)).sum()
                return SIMD3(repeating: y)
            }
        case .tungstenNight:
            return CubeLUT.generate(size: size, title: rawValue) { c in
                BuiltInLook.film(c, toe: 0.02, contrast: 1.0, shoulder: 0.85, warm: SIMD3(0.95, 1.0, 1.06),
                                 shadowTint: SIMD3(0.94, 1.0, 1.08), saturation: 0.95, highlightDesat: 0.3)
            }
        }
    }

    static func film(_ c: SIMD3<Float>, toe: Float, contrast: Float, shoulder: Float, warm: SIMD3<Float>,
                     shadowTint: SIMD3<Float>, saturation: Float, highlightDesat: Float) -> SIMD3<Float> {
        // Tone: S-curve anchored at 0 and 1 (power on each half), applied to luma so hue stays stable.
        // The toe lift is added as a neutral offset afterwards; multiplying colour by a large
        // luma ratio in deep shadows turns noise into saturated blotches (bug seen on USER_mooncake).
        let w = SIMD3<Float>(0.2126, 0.7152, 0.0722)
        let y = max((c * w).sum(), 0)
        func curve(_ v: Float) -> Float {
            let k = 1 / max(contrast, 0.1)
            let s = v < 0.5 ? 0.5 * pow(2 * v, 1 / k) : 1 - 0.5 * pow(2 * (1 - v), 1 / k)
            return s > shoulder ? shoulder + (1 - shoulder) * tanh((s - shoulder) / max(1 - shoulder, 1e-3)) : s
        }
        let yc = curve(y)
        let ratio = y > 1e-4 ? min(yc / y, 2) : 1
        let base = c * ratio + SIMD3(repeating: max(yc - y * ratio, 0))  // any shortfall added as neutral grey
        var out = SIMD3(repeating: toe) + base * (1 - toe)
        let yt = toe + (1 - toe) * yc
        // Split tone: tint shadows, warm highlights.
        let tint = shadowTint + (warm - shadowTint) * yt
        out *= tint
        // Saturation, reduced toward white.
        let yo = (out * w).sum()
        let sat = saturation * (1 - highlightDesat * yt * yt)
        out = SIMD3(repeating: yo) + (out - SIMD3(repeating: yo)) * sat
        return out
    }
}

/// Film finishing applied after the look: grain, halation, vignette. Every size is a percentage of the
/// image's SHORT edge, so a 12 MP export, a 48 MP export and a 1024 px preview look the same at the same
/// viewing size (grain does not get finer on bigger files).
public struct FilmFinish: Codable, Equatable, Sendable {
    /// 0...1. Multiplicative luminance grain; strongest in shadows/mid-tones, fades toward white.
    public var grainAmount: Float
    /// Grain cell size, % of the short edge (0.07 ≈ 2 px on a 3024 px edge).
    public var grainSize: Float
    /// Same seed, same grain: renders are reproducible from the recipe.
    public var grainSeed: UInt32
    /// 0...1. Red-orange glow around bright areas (light scattered back through the film base).
    public var halationAmount: Float
    /// Linear luminance where halation starts (0...1).
    public var halationThreshold: Float
    /// Glow radius, % of the short edge.
    public var halationRadius: Float
    /// 0...1 corner darkening.
    public var vignette: Float
    /// Light leak of the stock (plugin `lightLeak`, docs/ROADMAP.md EXTRAS). nil = none. Needs the roll position in
    /// `RenderSettings` (rollFrameIndex / rollFrameCount) to be drawn.
    public var lightLeak: LightLeakSpec? = nil

    public init(grainAmount: Float = 0, grainSize: Float = 0.07, grainSeed: UInt32 = 1, halationAmount: Float = 0,
                halationThreshold: Float = 0.75, halationRadius: Float = 0.5, vignette: Float = 0, lightLeak: LightLeakSpec? = nil) {
        self.grainAmount = grainAmount; self.grainSize = grainSize; self.grainSeed = grainSeed
        self.halationAmount = halationAmount; self.halationThreshold = halationThreshold
        self.halationRadius = halationRadius; self.vignette = vignette; self.lightLeak = lightLeak
    }

    public static let none = FilmFinish()
    public var isNone: Bool { grainAmount == 0 && halationAmount == 0 && vignette == 0 && lightLeak == nil }

    public func validate() throws {
        for (name, v) in [("grainAmount", grainAmount), ("halationAmount", halationAmount), ("vignette", vignette)] where !(0...1).contains(v) {
            throw RawCoreError.invalidSettings("\(name) must be in 0...1")
        }
        guard (0.01...1).contains(grainSize) else { throw RawCoreError.invalidSettings("grainSize must be 0.01...1 % of the short edge") }
        guard (0.05...5).contains(halationRadius) else { throw RawCoreError.invalidSettings("halationRadius must be 0.05...5 % of the short edge") }
        guard (0.1...0.99).contains(halationThreshold) else { throw RawCoreError.invalidSettings("halationThreshold must be 0.1...0.99") }
        try lightLeak?.validate()
    }
}

/// How a stock wants the RAW decoded (plugin `filmDevelop`, docs/ROADMAP.md EXTRAS; plan
/// `.orchestration/smartphone-look/SMARTPHONE_LOOK_PLAN_2026-11-11.md`): a soft film base instead of the phone's
/// crunchy one. All values are multipliers on / limits around Apple's per-file defaults; tone (contrast, boost,
/// boostShadow) is never touched, looks own the curve. `FilmStock.develop == nil` = no change.
public struct FilmDevelop: Codable, Equatable, Sendable {
    /// Short id recorded in the recipe and in `Developer.Base` ("iso<400", "iso400+portrait").
    public var profile: String
    /// Sharpness = Apple's default × this (never raised).
    public var sharpScale: Float
    /// Absolute floor of the scaled sharpness (a very low default is not scaled below it).
    public var sharpFloor: Float = 0.30
    /// Extra sharpness taken off when a face >= `DecisionEngine.Threshold.faceArea` is in frame.
    public var faceSharpDelta: Float = 0.05
    /// Multiplier on `highlightClarity` when highlightRecovery set one.
    public var clarityScale: Float = 0.4
    /// Luma NR may rise at most this far above Apple's default (nil = leave DecisionEngine's choice).
    public var lumaNRMaxDelta: Float? = nil
    /// ProRAW only (file whose default local tone map > 0): multiplier on the local tone map. nil = unchanged (trial off).
    public var ltmScale: Float? = nil
    /// ProRAW only (default detail > this): detail is lowered to this.
    public var proRAWDetail: Float = 0.2
    /// cameraMatch with this stock: how much of the HEIC's tone curve (ToneMatch stage 2) is kept, 0...1. The curve is
    /// blended toward identity (1 = full curve, 0 = none); the exposure match (stage 1) is unchanged. The HEIC's Smart-HDR
    /// tone would otherwise be imported into the film stock (plan §5; 0.5 asked by the user 2026-11-11).
    public var cameraMatchCurveStrength: Float = 0.5

    public init(profile: String, sharpScale: Float, sharpFloor: Float = 0.30, faceSharpDelta: Float = 0.05,
                clarityScale: Float = 0.4, lumaNRMaxDelta: Float? = nil, ltmScale: Float? = nil, proRAWDetail: Float = 0.2,
                cameraMatchCurveStrength: Float = 0.5) {
        self.cameraMatchCurveStrength = cameraMatchCurveStrength
        self.profile = profile; self.sharpScale = sharpScale; self.sharpFloor = sharpFloor; self.faceSharpDelta = faceSharpDelta
        self.clarityScale = clarityScale; self.lumaNRMaxDelta = lumaNRMaxDelta; self.ltmScale = ltmScale; self.proRAWDetail = proRAWDetail
    }

    /// Scale Apple's per-file defaults inside `settings` (already holding DecisionEngine's choices). Bounded: values only go
    /// down (luma NR is capped, never raised). Returns one reason per change; empty = nothing changed.
    public func apply(context c: SceneContext, defaults d: DecodeParameters, settings st: inout RenderSettings) -> [String] {
        var why: [String] = []
        let tag = "develop \(profile)"
        // Sharpness: scaled default, floor, extra for faces.
        let curSharp = st.sharpnessAmount ?? d.sharpnessAmount
        var target = max(d.sharpnessAmount * sharpScale, min(sharpFloor, d.sharpnessAmount))
        var faceNote = ""
        if (c.largestFaceArea ?? 0) >= DecisionEngine.Threshold.faceArea, faceSharpDelta > 0 {
            target = max(0, target - faceSharpDelta)
            faceNote = String(format: ", face %.1f%% of frame -%.2f", (c.largestFaceArea ?? 0) * 100, faceSharpDelta)
        }
        if target < curSharp - 0.001 {
            st.sharpnessAmount = target
            why.append(String(format: "%@: sharpness %.2f -> %.2f (Apple default %.2f x %.2f, floor %.2f%@)", tag, curSharp, target, d.sharpnessAmount, sharpScale, sharpFloor, faceNote))
        }
        // Luma NR cap.
        if let cap = lumaNRMaxDelta {
            let cur = st.luminanceNRAmountOrDefault(d)
            let limit = min(1, d.luminanceNoiseReductionAmount + cap)
            if cur > limit + 0.001 {
                st.luminanceNoiseReductionAmount = limit
                why.append(String(format: "%@: luminanceNR %.2f -> %.2f (at most %+.2f over Apple's %.2f; grain covers the rest, colour NR kept)", tag, cur, limit, cap, d.luminanceNoiseReductionAmount))
            }
        }
        // Highlight clarity from highlightRecovery.
        if let cl = st.highlightClarity, cl > 0, clarityScale < 1 {
            let v = cl * clarityScale
            st.highlightClarity = v
            why.append(String(format: "%@: highlight clarity %.2f -> %.2f (x%.2f, a film base has no HDR clarity)", tag, cl, v, clarityScale))
        }
        // ProRAW: Apple's detail 0.5 and optionally its local tone map.
        let proRAW = d.localToneMapAmount > 0
        if proRAW {
            let curDetail = st.detailAmount ?? d.detailAmount
            if curDetail > proRAWDetail + 0.001 {
                st.detailAmount = proRAWDetail
                why.append(String(format: "%@: ProRAW detail %.2f -> %.2f", tag, curDetail, proRAWDetail))
            }
            if let k = ltmScale {
                let cur = st.localToneMapAmount ?? d.localToneMapAmount
                let v = cur * k
                if abs(v - cur) > 0.001 {
                    st.localToneMapAmount = v
                    why.append(String(format: "%@: ProRAW local tone map %.2f -> %.2f", tag, cur, v))
                }
            }
        }
        return why
    }
}

extension RenderSettings {
    fileprivate func luminanceNRAmountOrDefault(_ d: DecodeParameters) -> Float { luminanceNoiseReductionAmount ?? d.luminanceNoiseReductionAmount }
}

/// A complete film stock = look LUT + finishing. Names are the app's own (no real film brand names).
public struct FilmStock: Equatable, Sendable {
    public enum Source: Equatable, Sendable {
        case builtIn(BuiltInLook)
        /// Parametric preset (Presets2026.swift).
        case preset(PresetLookParams)
        /// A declared LUT file (`<name>.manifest.json` + `.cube`, checked by `LookContract`; see `LookLibrary`).
        case library(String)
        /// A generated look of the 2026 set (FilmLooks.swift).
        case spec(LookSpec)
    }
    public var name: String
    public var source: Source
    public var lookIntensity: Float
    public var finish: FilmFinish
    public var summary: String
    /// false for looks where holding the look back on people breaks the image (black and white: colour skin in a
    /// mono frame). Skin protection is then skipped and the recipe says why.
    public var allowsSkinProtection: Bool = true
    /// Preset asks for skin protection on people ("skinProtect: true" in the 2026 spec): at least this strength.
    public var minSkinProtection: Float? = nil
    /// What the look LUT expects as input. `.log` looks are applied by the `logLook` plugin on a scene-linear decode.
    public var lookInput: LookInput = .display
    /// Encoded colour space of a display-referred LUT (CIColorCubeWithColorSpace encodes into it).
    public var lookColorSpace: LookColorSpace = .displayP3
    /// Input primaries of a log LUT.
    public var logPrimaries: LogLookPrimaries = .rec2020
    /// How the RAW is decoded for this stock (plugin `filmDevelop`). nil = no change to Apple's decode.
    public var develop: FilmDevelop? = nil

    public init(name: String, source: Source, lookIntensity: Float, finish: FilmFinish, summary: String,
                allowsSkinProtection: Bool = true, minSkinProtection: Float? = nil) {
        self.name = name; self.source = source; self.lookIntensity = lookIntensity; self.finish = finish
        self.summary = summary; self.allowsSkinProtection = allowsSkinProtection; self.minSkinProtection = minSkinProtection
    }

    public init(name: String, look: BuiltInLook, lookIntensity: Float, finish: FilmFinish, summary: String,
                allowsSkinProtection: Bool = true) {
        self.init(name: name, source: .builtIn(look), lookIntensity: lookIntensity, finish: finish, summary: summary,
                  allowsSkinProtection: allowsSkinProtection)
    }

    public func lut(size: Int = 33) -> CubeLUT {
        switch source {
        case .builtIn(let l): return l.lut(size: size)
        case .preset: return Preset26.named(name)?.lut(size: size) ?? .identity(size: size)
        case .library(let n): return FilmStock.libraryLUT(n) ?? .identity(size: size)
        case .spec(let spec): return LookSpecCache.shared.lut(name, spec, size: max(size, spec.cubeSize))
        }
    }

    /// The original four stocks.
    public static let classic: [FilmStock] = [
        FilmStock(name: "warm400", look: .warmNegative, lookIntensity: 0.85,
                  finish: FilmFinish(grainAmount: 0.45, grainSize: 0.07, halationAmount: 0.30, halationThreshold: 0.75, halationRadius: 0.5, vignette: 0.15),
                  summary: "warm colour negative, visible grain, soft glow on lights"),
        FilmStock(name: "slide100", look: .coolSlide, lookIntensity: 0.85,
                  finish: FilmFinish(grainAmount: 0.20, grainSize: 0.05, halationAmount: 0.10, halationThreshold: 0.8, halationRadius: 0.4, vignette: 0.10),
                  summary: "cool, punchy slide film, fine grain"),
        FilmStock(name: "mono400", look: .mono, lookIntensity: 1,
                  finish: FilmFinish(grainAmount: 0.60, grainSize: 0.08, halationAmount: 0, vignette: 0.20),
                  summary: "black and white, strong grain", allowsSkinProtection: false),
        FilmStock(name: "night800", look: .tungstenNight, lookIntensity: 0.9,
                  finish: FilmFinish(grainAmount: 0.70, grainSize: 0.09, halationAmount: 0.50, halationThreshold: 0.6, halationRadius: 0.7, vignette: 0.10),
                  summary: "tungsten-balanced night stock, big grain, strong halation on lamps"),
    ]

    /// Declared LUT files shipped in `Sources/RawCore/Looks` that pass `LookContract` (unusable ones are listed by
    /// `LookLibrary.bundled.checks` and `raw-bench lutcheck`, never loaded).
    public static var bundled: [FilmStock] { LookLibrary.bundled.stocks }

    private static let registryLock = NSLock()
    nonisolated(unsafe) private static var registered: [(FilmStock, LookLibrary?)] = []

    /// Adds stocks at run time (a user's checked LUT library, tests). A name already known is replaced.
    public static func register(_ stocks: [FilmStock], library: LookLibrary? = nil) {
        registryLock.lock(); defer { registryLock.unlock() }
        registered.removeAll { r in stocks.contains { $0.name == r.0.name } }
        registered += stocks.map { ($0, library) }
    }

    static func libraryLUT(_ n: String) -> CubeLUT? {
        registryLock.lock()
        let lib = registered.first { $0.0.name == n }?.1
        registryLock.unlock()
        return (lib ?? LookLibrary.bundled).lut(named: n)
    }

    /// Manifest of a library look (for the recipe).
    public static func manifest(_ n: String) -> LookManifest? {
        registryLock.lock()
        let lib = registered.first { $0.0.name == n }?.1
        registryLock.unlock()
        return (lib ?? LookLibrary.bundled).manifest(named: n)
    }

    static let builtIn: [FilmStock] = classic + Preset26.all.map(\.stock) + FilmLooks2026.stocks

    /// Classic stocks + the 2026 drop (PRESET_26_*) + the 2026 film-look set + checked library looks + registered ones.
    public static var all: [FilmStock] {
        registryLock.lock(); let r = registered.map(\.0); registryLock.unlock()
        let lib = bundled
        return builtIn + lib.filter { l in !r.contains { $0.name == l.name } } + r
    }

    /// Trial looks (`FilmLooks2026.trialStocks`) resolve by name for review renders but are not in `all` (not listed).
    /// Roll stocks (`RollStocks`, `rr-…` ids) resolve the same way.
    public static func named(_ n: String) -> FilmStock? {
        all.first { $0.name == n } ?? (FilmLooks2026.trialStocks + FilmLooks2026.retiredStocks + RollStocks.stocks).first { $0.name == n }
    }
}

/// Generated looks are built once per (name, size): a 33³ OKLab look costs a few ms to generate.
final class LookSpecCache: @unchecked Sendable {
    static let shared = LookSpecCache()
    private let lock = NSLock()
    private var items: [String: CubeLUT] = [:]
    func lut(_ name: String, _ spec: LookSpec, size: Int) -> CubeLUT {
        lock.lock(); defer { lock.unlock() }
        let key = "\(name)|\(size)"
        if let l = items[key] { return l }
        let l = spec.lut(size: size, title: name)
        items[key] = l
        return l
    }
}

// MARK: - Light leak (pure Swift; plugin `lightLeak` draws it)

/// Light leak of a stock, per `.orchestration/looks/RR_LOOKS_2026-11-11.md` ("Light leak spec"). Every number here is
/// either quoted from that spec or marked `OPEN:` (the spec does not state it; see WORK_LOG 2026-11-11 for the list).
public struct LightLeakSpec: Codable, Equatable, Sendable {
    /// One row of the per-frame table: chance and strength range (strength 1 = the spec's peak add).
    public struct Row: Codable, Equatable, Sendable {
        public var chance: Float
        public var strength: ClosedRange<Float>
        public init(chance: Float, strength: ClosedRange<Float>) { self.chance = chance; self.strength = strength }
    }
    /// Global amount (spec: 0.35 for Lá Phong).
    public var amount: Float = 0.35
    /// Peak add in linear light at the core at strength 1 (spec: about +0.25).
    public var peakAdd: Float = 0.25
    /// Core colour, linear (spec: [1.0, 0.30, 0.06], "OKLCh hue about 35-45 degrees"). OPEN: these two do not agree. The
    /// numbers give OKLCh hue 52 degrees in linear Display P3 (54 read as linear sRGB). The numbers are used as written, as
    /// linear values in the working space (Display P3); the hue stays what they give.
    public var coreColor: SIMD3<Float> = SIMD3(1.0, 0.30, 0.06)
    /// OKLCh hue at the outer falloff (spec: about 70 degrees).
    public var outerHue: Float = 70
    /// Jitter per frame: hue +-degrees, size +-fraction (spec: +-8 degrees, +-30 %).
    public var hueJitter: Float = 8
    public var sizeJitter: Float = 0.30
    /// Core distance outside the frame edge, fraction of the frame width (spec: 0 ... 10 %).
    public var coreOutside: ClosedRange<Float> = 0...0.10
    /// Falloff reach, fraction of the frame width, before the size jitter: the spec says 20-40 %; the middle (30 %)
    /// with +-30 % jitter spans 21-39 %. OPEN: where the 20-40 % is measured from (here: from the core).
    public var reach: Float = 0.30
    /// OPEN (spec says "elliptical", no ratio): sigma along the edge / sigma into the frame.
    public var aspect: Float = 1.5
    /// OPEN (spec: reach is "about" 20-40 %): the Gaussian is taken as 5 % of its peak at `reach`, i.e. reach = 2.45 sigma.
    public var reachSigmas: Float = 2.45
    /// Optional vertical streak (spec: faint band, 5-12 % wide, from the same edge). OPEN: chance and strength.
    public var streakChance: Float = 0.5
    public var streakWidth: ClosedRange<Float> = 0.05...0.12
    public var streakStrength: Float = 0.25
    /// Factor inside the Vision person mask (spec: 0.4).
    public var personFactor: Float = 0.4
    /// Output ceiling, display-encoded (spec: 0.99, no new clip).
    public var encodedCap: Float = 0.99
    /// Frames 1-2: always, strong 0.6-0.9.
    public var start = Row(chance: 1, strength: 0.6...0.9)
    /// Frame 3: 50 %, 0.3-0.5.
    public var third = Row(chance: 0.5, strength: 0.3...0.5)
    /// Middle of the roll: about 12 % of frames, faint 0.15-0.35.
    public var middle = Row(chance: 0.12, strength: 0.15...0.35)
    /// Last frame: 60 %, "medium". OPEN: the spec gives no number; the gap between faint (0.35) and strong (0.6).
    public var last = Row(chance: 0.6, strength: 0.35...0.6)

    public init() {}

    /// Spec preset for RR Lá Phong 100.
    public static let laPhong = LightLeakSpec()

    public func validate() throws {
        guard (0...1).contains(amount), peakAdd > 0, peakAdd <= 1 else { throw RawCoreError.invalidSettings("lightLeak amount must be 0...1 and peakAdd 0...1") }
        guard (0...1).contains(personFactor), (0.5...1).contains(encodedCap) else { throw RawCoreError.invalidSettings("lightLeak personFactor 0...1, encodedCap 0.5...1") }
        guard reach > 0, aspect > 0, reachSigmas > 0 else { throw RawCoreError.invalidSettings("lightLeak reach, aspect, reachSigmas must be > 0") }
    }
}

/// What the plugin decided for one frame. Everything the recipe logs.
public struct LightLeakPlan: Equatable, Sendable {
    public enum FrameClass: String, Sendable { case start, third, middle, last }
    public enum Edge: String, Sendable { case left, right }
    public var seed: UInt64
    public var frameClass: FrameClass
    /// Nil = this frame has no leak (the chance row said no).
    public var leak: Leak?
    public var chanceDraw: Float
    public var chance: Float

    public struct Leak: Equatable, Sendable {
        public var strength: Float
        public var edge: Edge
        /// Core distance outside the edge, fraction of the frame width.
        public var coreOutside: Float
        /// Core position along the edge, 0 = top ... 1 = bottom of the frame (never in the central third).
        public var position: Float
        /// Gaussian sigma into the frame, fraction of the frame width.
        public var sigma: Float
        /// Core hue (OKLCh degrees) after jitter; outer hue likewise.
        public var coreHue: Float
        public var outerHue: Float
        public var hueShift: Float
        /// Streak width as a fraction of the frame width, nil = no streak.
        public var streak: Float?
    }
}

public enum LightLeakPlanner {
    /// Deterministic: same (rollID, frame index) -> same plan. FNV-1a 64 of "rollID|frame" seeds SplitMix64
    /// (Swift's own hashing is randomised per process, so it is not used).
    public static func seed(rollID: String, frame: Int) -> UInt64 {
        var h: UInt64 = 0xcbf29ce484222325
        for b in "\(rollID)|\(frame)".utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return h
    }

    struct Rng {
        var state: UInt64
        mutating func next() -> Float {
            state &+= 0x9e3779b97f4a7c15
            var z = state
            z = (z ^ (z >> 30)) &* 0xbf58476d1ce4e5b9
            z = (z ^ (z >> 27)) &* 0x94d049bb133111eb
            z ^= z >> 31
            return Float(z >> 40) / Float(1 << 24)   // 24 bits: exact in Float, [0, 1)
        }
        mutating func range(_ r: ClosedRange<Float>) -> Float { r.lowerBound + (r.upperBound - r.lowerBound) * next() }
    }

    /// Table row of a frame. Order of precedence when classes overlap (OPEN, the spec does not say): start, third, last, middle
    /// (a 1- or 2-frame roll is all start; frame 3 of a 3-frame roll is the third; the last frame of a longer roll is last).
    public static func frameClass(frame: Int, count: Int) -> LightLeakPlan.FrameClass {
        if frame <= 2 { return .start }
        if frame == 3 { return .third }
        if frame == count { return .last }
        return .middle
    }

    /// Returns nil for an impossible position (frame outside 1...count).
    public static func plan(spec: LightLeakSpec, rollID: String, frame: Int, count: Int) -> LightLeakPlan? {
        guard count >= 1, (1...count).contains(frame) else { return nil }
        let cls = frameClass(frame: frame, count: count)
        let row: LightLeakSpec.Row
        switch cls { case .start: row = spec.start; case .third: row = spec.third; case .middle: row = spec.middle; case .last: row = spec.last }
        let seed = seed(rollID: rollID, frame: frame)
        // Fixed draw order whatever the class, so a frame's pattern does not depend on the other rows' numbers.
        var r = Rng(state: seed)
        let chanceDraw = r.next()
        let strength = r.range(row.strength)
        let edgeDraw = r.next(), sideDraw = r.next(), posDraw = r.next(), outDraw = r.range(spec.coreOutside)
        let sizeDraw = r.range(-spec.sizeJitter...spec.sizeJitter), hueDraw = r.range(-spec.hueJitter...spec.hueJitter)
        let streakDraw = r.next(), streakW = r.range(spec.streakWidth)
        var plan = LightLeakPlan(seed: seed, frameClass: cls, leak: nil, chanceDraw: chanceDraw, chance: row.chance)
        guard chanceDraw < row.chance else { return plan }
        // Never the central third: 0...1/3 or 2/3...1 along the edge.
        let pos = (sideDraw < 0.5 ? 0 : 2.0 / 3) + posDraw / 3
        let hue0 = coreHue(spec) + hueDraw
        plan.leak = .init(strength: strength, edge: edgeDraw < 0.5 ? .left : .right, coreOutside: outDraw, position: pos,
                          sigma: spec.reach * (1 + sizeDraw) / spec.reachSigmas, coreHue: hue0, outerHue: spec.outerHue + hueDraw,
                          hueShift: hueDraw, streak: streakDraw < spec.streakChance ? streakW : nil)
        return plan
    }

    /// The core colour in the working space (used as written, see `LightLeakSpec.coreColor`).
    public static func coreP3(_ spec: LightLeakSpec) -> SIMD3<Float> { spec.coreColor }

    /// OKLCh hue of the core colour (degrees).
    public static func coreHue(_ spec: LightLeakSpec) -> Float {
        let lab = OKLab.fromLinearP3(coreP3(spec))
        var h = atan2(lab.z, lab.y) * 180 / .pi
        if h < 0 { h += 360 }
        return h
    }

    /// Colour (max channel 1) at falloff depth t (0 core ... 1 outer): OKLCh hue from the core hue to the outer hue at
    /// the core's lightness and chroma, then scaled so the largest channel is 1.
    public static func colour(spec: LightLeakSpec, leak l: LightLeakPlan.Leak, t: Float) -> SIMD3<Float> {
        let core = OKLab.fromLinearP3(coreP3(spec))
        let chroma = (core.y * core.y + core.z * core.z).squareRoot()
        let hue = (l.coreHue + (l.outerHue - l.coreHue) * min(max(t, 0), 1)) * .pi / 180
        let rgb = OKLab.toLinearP3(SIMD3(core.x, chroma * cos(hue), chroma * sin(hue)))
        let c = SIMD3(max(rgb.x, 0), max(rgb.y, 0), max(rgb.z, 0))
        let m = max(c.x, c.y, c.z)
        return m > 1e-6 ? c / m : SIMD3(repeating: 0)
    }

    /// Linear light added at a point, x and y in 0...1 of the frame (y = 0 top), `aspectWH` = width / height.
    /// Peak = peakAdd * amount * strength at the core. Streak: raised cosine from the edge inward, `streakStrength` of the peak.
    public static func addition(spec: LightLeakSpec, leak l: LightLeakPlan.Leak, x: Float, y: Float, aspectWH: Float) -> SIMD3<Float> {
        let cx: Float = l.edge == .left ? -l.coreOutside : 1 + l.coreOutside
        let dx = x - cx                                     // fractions of the width
        let dy = (y - l.position) / aspectWH               // same unit (width) as dx
        let sx = l.sigma, sy = l.sigma * spec.aspect
        let g = exp(-0.5 * (dx * dx / (sx * sx) + dy * dy / (sy * sy)))
        let peak = spec.peakAdd * spec.amount * l.strength
        let c0: SIMD3<Float> = colour(spec: spec, leak: l, t: 1 - g)
        var out: SIMD3<Float> = c0 * (peak * g)
        if let w = l.streak {
            let d = l.edge == .left ? x : 1 - x           // distance from the edge, fraction of width
            if d < w {
                let s = 0.5 * (1 + cos(.pi * d / w))
                let c1: SIMD3<Float> = colour(spec: spec, leak: l, t: 0)
                out += c1 * (peak * spec.streakStrength * s)
            }
        }
        return out
    }

    /// Reason line for the recipe: seed, edge, position, strength and hue per frame (spec).
    public static func describe(_ p: LightLeakPlan, frame: Int, count: Int, rollID: String) -> String {
        let head = String(format: "frame %d/%d (%@), roll \"%@\", seed %016llx", frame, count, p.frameClass.rawValue, rollID, p.seed)
        guard let l = p.leak else {
            return head + String(format: ": no leak (draw %.3f >= chance %.2f)", p.chanceDraw, p.chance)
        }
        return head + String(format: ": leak (draw %.3f < chance %.2f) edge %@, core %.1f%% outside, position %.2f of the edge, strength %.2f, sigma %.1f%% of width, hue %.0f > %.0f deg (jitter %+.1f)%@",
                             p.chanceDraw, p.chance, l.edge.rawValue, l.coreOutside * 100, l.position, l.strength, l.sigma * 100,
                             l.coreHue, l.outerHue, l.hueShift, l.streak.map { String(format: ", streak %.1f%% wide", $0 * 100) } ?? ", no streak")
    }
}
