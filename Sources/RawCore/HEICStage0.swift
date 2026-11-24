#if canImport(CoreImage)
import CoreImage
import Foundation
import ImageIO

/// What stage 0-H (HEIC entry, selfie / front camera) read and decided for one frame. Written into the recipe
/// (`DecodeRecipe.heicStage0`); nil on RAW frames. Plan: SELFIE_HEIC_STAGE0H_PLAN_2026-11-19.
public struct HEICStage0Record: Codable, Equatable, Sendable {
    /// Version of the 0-H definition (bumped when the HEIC -> linear mapping changes).
    public var version: String
    /// Always "heic".
    public var source: String
    /// Always "none": a HEIC has no highlight headroom (values above 1.0 do not exist).
    public var headroom: String
    /// How the pixels were made scene-linear (display transfer + tone-curve inversion, parameters included).
    public var transfer: String
    /// The inverse tone curve's strength `k` (see `HEICToneInverse`). 0 = no tone inversion (display transfer only).
    public var toneCurveK: Double = 0
    public var nativeSize: [Int]
    public var camera: String?
    public var iso: Double?
    public var exposureTime: Double?
    public var fNumber: Double?
    /// Stage-1 exposure gain applied on top of the inverted HEIC (EV): the stock's bounded deviation (`stockExposureRequestedEV`
    /// clamped to `Developer.heicStockExposureRangeEV`). The HEIC is the camera's exposure as shot, so this is the ONLY gain.
    public var stockExposureEV: Float
    /// The stock's `RenderSettings.exposure` the host sent (nil = none sent), before the bound.
    public var stockExposureRequestedEV: Float? = nil
    /// The user's exposure compensation recorded at the press (`RenderSettings.userExposureBiasEV`), already inside the HEIC.
    /// Recorded only: nothing re-applies it and nothing cancels it. nil = unknown.
    public var userExposureBiasEV: Double? = nil
    /// Stage-0 illuminant metadata: estimated from the HEIC's EXIF (`HEICIlluminant`), never nil on a HEIC frame.
    public var illuminant: IlluminantMetadata
    public var notes: [String]
}

/// Stage 0-H tone inversion: an approximation of Apple's display transfer + global tone curve, inverted to scene-linear P3.
///
/// Deterministic and APPROXIMATE. Two steps:
/// 1. Display transfer: the colour-managed decode of the Display P3 HEIC (the P3 transfer function is the sRGB piecewise curve)
///    gives display-linear P3. Exact.
/// 2. Tone curve: Apple's global tone curve is modelled as a symmetric S-curve on the encoded (sRGB-transfer) value of the
///    luminance, `T(e) = e + k * e * (1 - e) * (2e - 1)` (fixed ends 0 and 1, slope `1 - k` at both ends and `1 + k / 2` at
///    mid-grey, monotone for k < 1). `HEICToneInverse.curveInverse` solves `T(e_s) = e_d` by a fixed-step bisection (no
///    iteration-count or hardware dependence), then the pixel is scaled by `Y_s / Y_d` (P3 luminance, linear) so hue and the
///    chroma ratio are kept (same hue-stable scheme as `HeadroomRestore`). A pixel keeps its channel order; none can reach
///    above 1 because the inverse only lowers values above mid-grey and raises shadows by at most `1 / (1 - k)`.
/// The constant `k` is PROVISIONAL: it was not fitted to measured data (no Apple tone-curve measurement exists in this repo).
/// `raw-bench heic-pairs --tone-k` sweeps it against rear DNG + apple.heic pairs for the P2 fit. k = 0 turns step 2 off.
/// Apple's local tone map, noise reduction and sharpening cannot be inverted and stay in the image.
public enum HEICToneInverse {
    /// Version of this inversion (part of `HEICStage0Record.transfer`).
    public static let version = "toneS-2"
    /// Strength of the modelled S-curve: 0.4 (User-approved 2026-11-23, SELFIE_0H_P3; was the provisional 0.25).
    public static let defaultK: Float = 0.4
    public static let cubeSize = 33

    /// Forward model T(e) on an encoded value in 0...1.
    public static func curve(_ e: Float, k: Float) -> Float { e + k * e * (1 - e) * (2 * e - 1) }

    /// Inverse of `curve` on 0...1 by 40 fixed bisection steps (monotone T for k in 0...<1).
    public static func curveInverse(_ d: Float, k: Float) -> Float {
        let target = min(max(d, 0), 1)
        guard k > 0 else { return target }
        var lo: Float = 0, hi: Float = 1
        for _ in 0..<40 {
            let mid = (lo + hi) / 2
            if curve(mid, k: k) < target { lo = mid } else { hi = mid }
        }
        return (lo + hi) / 2
    }

    /// Scene-linear P3 pixel from a display-encoded P3 pixel (the LUT body; also used by the tests).
    static func invert(encoded e: SIMD3<Float>, k: Float) -> SIMD3<Float> {
        let lin = SIMD3(Preset26.decode(e.x), Preset26.decode(e.y), Preset26.decode(e.z))
        let w = SIMD3<Float>(0.2289746, 0.6917385, 0.0792869)
        let yd = (lin * w).sum()
        guard k > 0 else { return lin }
        let ratio: Float
        if yd > 1e-6 {
            let ys = Preset26.decode(curveInverse(Preset26.encode(min(yd, 1)), k: k))
            ratio = ys / yd
        } else {
            ratio = 1 / (1 - k)
        }
        var o = lin * ratio
        let yo = (o * w).sum()
        let m = max(o.x, max(o.y, o.z))
        if m > 1 { let t = max((1 - yo) / (m - yo), 0); o = SIMD3(repeating: yo) + (o - SIMD3(repeating: yo)) * t }
        return o
    }

    /// The cube (encoded display P3 in, encoded value of the scene-linear result out; Core Image decodes the output to
    /// linear). Cached for the default k; other k (lab sweeps) are built per call.
    public static func lut(k: Float = defaultK) -> CubeLUT {
        if k == defaultK { return defaultLUT }
        return make(k: k)
    }
    private static let defaultLUT = make(k: defaultK)
    private static func make(k: Float) -> CubeLUT {
        CubeLUT.generate(size: cubeSize, title: "heicToneInverse") { e in
            let o = invert(encoded: e, k: k)
            return SIMD3(Preset26.encode(max(o.x, 0)), Preset26.encode(max(o.y, 0)), Preset26.encode(max(o.z, 0)))
        }
    }
}

/// Stage 0-H illuminant estimate from the HEIC's EXIF. A HEIC has no white-balance neutral; Apple's MakerNote holds no
/// white-balance field this code reads (the keys are not public and none was verified on a device), so only standard EXIF is
/// used, in this order: EXIF `LightSource` (standard code to CCT), `Flash` fired (nominal 5500 K), a bright-scene prior
/// (EV100 >= 12 reads as daylight, 5500 K), else the documented fallback 5000 K. Tint is 0 in every branch (EXIF has no tint).
/// The result is an estimate, never a measurement; `source` names the branch and each one is logged into the recipe.
public enum HEICIlluminant {
    public static let fallbackCCT: Double = 5000
    public static let daylightCCT: Double = 5500
    public static let brightSceneEV100: Double = 12

    /// EXIF `LightSource` code to CCT (K). 0 (unknown) and 255 (other) have none.
    static func cct(lightSource code: Int) -> Double? {
        switch code {
        case 1, 9, 4, 20: return 5500        // daylight, fine weather, flash, D55
        case 2: return 4200                  // fluorescent
        case 3: return 2850                  // tungsten
        case 10: return 6500                 // cloudy
        case 11: return 7500                 // shade
        case 12: return 6400                 // daylight fluorescent (D 5700-7100)
        case 13: return 5000                 // day white fluorescent
        case 14: return 4150                 // cool white fluorescent
        case 15: return 3500                 // white fluorescent
        case 17: return 2856                 // standard light A
        case 18: return 4874                 // standard light B
        case 19: return 6774                 // standard light C
        case 21: return 6504                 // D65
        case 22: return 7504                 // D75
        case 23: return 5003                 // D50
        case 24: return 3200                 // ISO studio tungsten
        default: return nil
        }
    }

    /// Pure: (cct, tint, source) from the EXIF dictionary values.
    public static func estimate(lightSource: Int?, flash: Int?, ev100: Double?) -> IlluminantMetadata {
        if let ls = lightSource, let k = cct(lightSource: ls) {
            return IlluminantMetadata(cct: k, tint: 0, source: "estimate: EXIF LightSource \(ls) -> \(Int(k)) K, tint 0 (EXIF has no tint)")
        }
        if let f = flash, f & 1 == 1 {
            return IlluminantMetadata(cct: daylightCCT, tint: 0, source: "estimate: EXIF Flash fired -> nominal \(Int(daylightCCT)) K, tint 0")
        }
        if let ev = ev100, ev.isFinite, ev >= brightSceneEV100 {
            return IlluminantMetadata(cct: daylightCCT, tint: 0, source: String(format: "estimate: bright-scene prior (EV100 %.1f >= %.0f) -> %d K daylight, tint 0", ev, brightSceneEV100, Int(daylightCCT)))
        }
        return IlluminantMetadata(cct: fallbackCCT, tint: 0, source: "fallback: no usable LightSource / Flash / bright-scene EV100 in the EXIF -> \(Int(fallbackCCT)) K, tint 0 (no white-balance information)")
    }
}

extension Developer {
    /// Value of `Analysis.decoderVersion` for a HEIC analysis, and `DecodeRecipe.decoderVersion` of a HEIC render.
    public static let heicDecoderVersion = "heic-0H-3"
    /// Version of the stage 0-H definition (`HEICStage0Record.version`).
    public static let heicStage0Version = "0H-4"
    /// Bound of the stock's exposure deviation on a HEIC (EV). Upper +0.8: Round 10 (soft / high-key stocks up to +0.8 EV;
    /// night stocks at or under the iPhone are negative values inside the range). Lower -1: the catalog's own
    /// `render.exposureBias` range (-1...1); Round 10 sets no lower bound ("an intentionally dim stock is allowed").
    public static let heicStockExposureRangeEV: ClosedRange<Float> = -1...0.8

    /// Plugins that make sense without a RAW decode. The RAW decode plugins (highlightRecovery, headroom, cameraMatch,
    /// filmDevelop) are dropped: stage 1 of a HEIC is the HEIC itself.
    static let heicPluginIDs: Set<String> = ["vignette", "logLook", "lightLeak", "skyMask", "qualityGuard"]

    /// Stage 0-H: decode the HEIC (Display P3, oriented, SDR base layer, no gain map) to the working space (extended linear
    /// Display P3), origin at 0,0, optionally downscaled. The colour-managed decode inverts the display transfer; with
    /// `invertTone` Apple's global tone curve is then inverted (`HEICToneInverse`, approximate) so the result is approximately
    /// scene-linear P3. No headroom: nothing above 1.0. Analysis reads the display-referred decode (`invertTone: false`, the same
    /// kind of image the RAW analysis measures); develop reads the inverted one.
    func stage0H(url: URL, scaleFactor: Float, invertTone: Bool = true, toneK: Float = HEICToneInverse.defaultK) throws -> (image: CIImage, properties: [String: Any], nativeSize: [Int]) {
        guard let source = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) else {
            throw RawCoreError.renderFailed("cannot open the HEIC \(url.lastPathComponent)")
        }
        let props = source.properties
        var image = source
        let e = image.extent
        guard e.width > 0, e.height > 0, e.width.isFinite, e.height.isFinite else {
            throw RawCoreError.renderFailed("HEIC \(url.lastPathComponent) has no pixels")
        }
        let native = [Int(e.width), Int(e.height)]
        image = image.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
        let s = min(max(scaleFactor, 0.01), 1)
        if s < 1 {
            image = image.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: s, kCIInputAspectRatioKey: 1.0])
            let o = image.extent
            image = image.transformed(by: CGAffineTransform(translationX: -o.minX, y: -o.minY))
        }
        if invertTone && toneK > 0 {
            image = try renderer.applyLook(HEICToneInverse.lut(k: toneK), to: image, intensity: 1, colorSpace: .displayP3)
        }
        return (image, props, native)
    }

    private static func exifNumber(_ props: [String: Any], _ key: CFString) -> Double? {
        let exif = props[kCGImagePropertyExifDictionary as String] as? [String: Any]
        return (exif?[key as String] as? NSNumber)?.doubleValue
    }

    private static func exifInt(_ props: [String: Any], _ key: CFString) -> Int? {
        (props[kCGImagePropertyExifDictionary as String] as? [String: Any])?[key as String].flatMap { ($0 as? NSNumber)?.intValue }
    }

    /// The stage 0-H illuminant estimate of one HEIC (`HEICIlluminant.estimate` on its EXIF).
    static func heicIlluminant(_ props: [String: Any], ev100: Double?) -> IlluminantMetadata {
        HEICIlluminant.estimate(lightSource: exifInt(props, kCGImagePropertyExifLightSource), flash: exifInt(props, kCGImagePropertyExifFlash), ev100: ev100)
    }

    private static func exifISO(_ props: [String: Any]) -> Double? {
        let exif = props[kCGImagePropertyExifDictionary as String] as? [String: Any]
        return (exif?[kCGImagePropertyExifISOSpeedRatings as String] as? [NSNumber])?.first?.doubleValue
    }

    private static func cameraName(_ props: [String: Any]) -> String? {
        let tiff = props[kCGImagePropertyTIFFDictionary as String] as? [String: Any]
        let name = [tiff?[kCGImagePropertyTIFFMake as String] as? String, tiff?[kCGImagePropertyTIFFModel as String] as? String]
            .compactMap { $0 }.joined(separator: " ")
        return name.isEmpty ? nil : name
    }

    private static var heicZeroParameters: DecodeParameters {
        DecodeParameters(exposure: 0, baselineExposure: 0, shadowBias: 0, boostAmount: 0, boostShadowAmount: 0, localToneMapAmount: 0,
                         sharpnessAmount: 0, contrastAmount: 0, detailAmount: 0, luminanceNoiseReductionAmount: 0,
                         colorNoiseReductionAmount: 0, moireReductionAmount: 0, extendedDynamicRangeAmount: 0,
                         lensCorrection: false, gamutMapping: false, neutralTemperature: 0, neutralTint: 0)
    }

    private static var heicNoSupport: DecoderSupport {
        DecoderSupport(localToneMap: false, sharpness: false, contrast: false, detail: false, luminanceNoiseReduction: false,
                       colorNoiseReduction: false, moireReduction: false, lensCorrection: false, maxExtendedDynamicRange: 0)
    }

    // MARK: Analysis

    /// Scene analysis of a HEIC frame (stage 0-H input): light statistics, Vision faces / labels / person mask and the sky
    /// mask, all on the display-referred linear render. RAW-only fields (EDR headroom, DNG defaults, camera reference
    /// histogram) are nil or zero; CCT / tint are the EXIF estimate (`HEICIlluminant`). Same file format as the RAW analysis (`write(to:)` / `read(from:)`), with
    /// `decoderVersion == heicDecoderVersion`, so a RAW render never reuses it and vice versa.
    public func analyze(heic url: URL) throws -> Analysis {
        let t0 = Date()
        let small = try stage0H(url: url, scaleFactor: 1, invertTone: false)
        let s512 = CameraMatchPlugin.small(small.image, longEdge: 512)
        let sceneLin = try renderer.linearImage(s512)
        let iso = Self.exifISO(small.properties)
        var c = SceneContext.measure(sceneLinear: sceneLin, iso: iso)
        c.exposureTime = Self.exifNumber(small.properties, kCGImagePropertyExifExposureTime)
        let s1024 = CameraMatchPlugin.small(small.image, longEdge: CameraMatchPlugin.histogramLongEdge)
        c.appleDecodeClippedFraction = SceneContext.clippedFraction(try renderer.linearImage(s1024))
        c.fNumber = Self.exifNumber(small.properties, kCGImagePropertyExifFNumber)
        c.ev100 = SceneNormalizer.ev100(fNumber: c.fNumber, exposureTime: c.exposureTime, iso: c.iso)
        c.ev100Version = c.ev100 == nil ? nil : SceneContext.ev100FormulaVersion
        let estimated = Self.heicIlluminant(small.properties, ev100: c.ev100)
        c.cct = estimated.cct; c.tint = estimated.tint
        c.lumaHistogram = renderer.lumaHistogram(s1024)

        var mask: CIImage?
        #if canImport(Vision)
        if let cg = renderer.cgImage(s1024) {
            mask = VisionAnalyzer.enrich(&c, image: cg)
            if let mask { c.personFraction = renderer.areaMean(mask) }
        }
        #endif
        var sky: CIImage?
        if plugins.defaultEnabled.contains("skyMask") {
            c.skyMaskVersion = SkyMask.version
            switch SkyMask.gate(labels: c.labels) {
            case .unavailable(let why):
                c.skyFraction = nil; c.skyGate = "unavailable: " + why
            case .closed(let why):
                c.skyFraction = 0; c.skyGate = why
            case .open(let label, let conf):
                let r = SkyMask.compute(sceneLinear: sceneLin)
                c.skyFraction = r.coverage
                if r.coverage >= SkyMask.minCoverage {
                    sky = renderer.maskImage(r.mask, width: r.width, height: r.height)
                    c.skyGate = String(format: "label %@ %.2f, heuristic coverage %.1f%%", label, conf, r.coverage * 100)
                } else {
                    c.skyGate = String(format: "label %@ %.2f, but heuristic coverage %.2f%% < %.0f%%", label, conf, r.coverage * 100, SkyMask.minCoverage * 100)
                }
            }
        }
        let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
        return Analysis(context: c, defaults: Self.heicZeroParameters, support: Self.heicNoSupport,
                        seconds: Date().timeIntervalSince(t0), decoderVersion: Self.heicDecoderVersion,
                        plugins: plugins.defaultEnabled.filter { Self.heicPluginIDs.contains($0) },
                        sourceFile: url.lastPathComponent, sourceBytes: bytes, personMask: mask, skyMask: sky)
    }

    // MARK: Develop

    /// Develop a HEIC frame: `finish(developBase(heic:))`. `auto` is implied (the analysis is used or made).
    public func develop(heic url: URL, settings: RenderSettings, scaleFactor: Float, analysis: Analysis? = nil) throws -> Output {
        try finish(developBase(heic: url, settings: settings, scaleFactor: scaleFactor, analysis: analysis))
    }

    /// Same two-step guard as the RAW `previewGuardStrength`: measure on a small preview, no grain, return the strength.
    public func previewGuardStrength(heic url: URL, settings: RenderSettings, previewScaleFactor: Float = 0.25,
                                     analysis: Analysis? = nil) throws -> Float {
        var s = guardEnabled(settings)
        s.qualityGuardStrength = nil
        let base = try developBase(heic: url, settings: s, scaleFactor: previewScaleFactor, analysis: analysis)
        return try finish(base, grain: false).recipe.qualityGuardStrength ?? 1
    }

    /// Stage 0-H + stage 1 for a HEIC. Stage 1 here: the anchor is the HEIC itself (the iPhone's exposure, offset 0), plus the
    /// stock's bounded exposure deviation as ONE linear gain on the inverted (approximately scene-linear) image,
    ///   gain EV = clamp(settings.exposure, `heicStockExposureRangeEV`)      (-1 ... +0.8; nil = 0)
    /// applied with `HeadroomRestore.curveV2` (exactly G*y below the knee, rational shoulder, 1 -> 1), so a pixel at or below
    /// 1.0 never ends above 1.0 and a positive gain does not clip. No EV100 ramp, no normalizer, no cameraMatch, no headroom
    /// decode or restore (`decodeHeadroomEV` and `cameraMatchStrength` compensate the RAW decode and are not applied), no
    /// highlight work. The user's exposure compensation is already in the HEIC pixels: recorded, never re-applied.
    /// `finish` then runs the same stock render, look, crop, grain and plugins as for a RAW frame.
    public func developBase(heic url: URL, settings: RenderSettings, scaleFactor: Float, analysis: Analysis? = nil) throws -> Base {
        var settings = settings
        settings.headroomRestoreEV = nil
        try settings.validate()
        var st = settings
        var reasons: [String] = []
        let requested = try plugins.active(for: settings)
        let active = requested.filter { Self.heicPluginIDs.contains($0.id) }
        let dropped = requested.map(\.id).filter { !Self.heicPluginIDs.contains($0) }
        if !dropped.isEmpty { reasons.append("[heic] plugins not used on a HEIC frame: \(dropped.joined(separator: ", "))") }

        let a: Analysis
        if let given = analysis {
            if let why = given.staleReason(url: url, decoderVersion: Self.heicDecoderVersion, plugins: active.map(\.id)) {
                a = try analyze(heic: url)
                reasons.append("stored analysis not used (\(why)): analysed again")
            } else {
                a = given
                reasons.append(String(format: "stored analysis used (made in %.2fs)", given.seconds))
            }
        } else {
            a = try analyze(heic: url)
        }
        // Scene rules that do not touch a decode (people -> skin protection, scene -> look intensity): the same
        // DecisionEngine as the RAW path. No decode support is declared, so no decode parameter can change.
        let d = DecisionEngine.decide(context: a.context, defaults: a.defaults, support: a.support, base: st)
        st.skinProtection = d.settings.skinProtection
        st.lookIntensityOffset = d.settings.lookIntensityOffset
        reasons += d.reasons

        let stage0 = try stage0H(url: url, scaleFactor: scaleFactor, invertTone: true, toneK: heicToneK)
        var image = stage0.image
        let k = heicToneK
        reasons.append(k > 0
            ? String(format: "[heic] stage 0-H: display transfer + tone inversion %@ k=%.2f (approximate, provisional k)", HEICToneInverse.version, k)
            : "[heic] stage 0-H: display transfer only (tone inversion off, k=0)")
        // Stage 1: the stock's bounded exposure deviation only.
        // 0.8.0: the stock's exposure bias is IGNORED on a HEIC (P3 "x0"): the camera's exposure as shot is the anchor. Only
        // recorded (`stockExposureRequestedEV`). `heicStockExposureRangeEV` is kept for API compatibility and no longer read.
        let requestedEV = st.exposure
        let ev: Float = 0
        if let r = requestedEV, r.isFinite, r != 0 {
            reasons.append(String(format: "[heic] stage 1: stock exposure %+.2f EV ignored on a HEIC (camera exposure kept)", r))
        }
        if ev != 0 {
            let q = HeadroomRestore.quantised(ev)
            image = try renderer.applyLook(HeadroomRestore.lutV2(gainEV: q), to: image, intensity: 1)
            reasons.append(String(format: "[heic] stage 1: HEIC anchor (offset 0 EV) + stock deviation %+.2f EV (max-channel shoulder from 0.5, 1 -> 1; no clip of values <= 1.0)", q))
        } else {
            reasons.append("[heic] stage 1: HEIC anchor, stock deviation 0 EV")
        }
        if let b = st.userExposureBiasEV, b.isFinite, b != 0 {
            reasons.append(String(format: "[heic] stage 1: the user's %+.2f EV exposure compensation is already in the HEIC pixels, not re-applied", b))
        }
        if (st.decodeHeadroomEV ?? 0) > 0 || (st.cameraMatchStrength ?? 0) > 0 {
            reasons.append("[heic] stage 1: decodeHeadroomEV / cameraMatchStrength compensate the RAW decode and are not applied")
        }
        let ctx = a.context
        let heicImage = image
        let pctx = PluginRenderContext(renderer: renderer, decodeBase: { heicImage }, scene: ctx, decodeSceneLinear: nil)
        let illuminant = Self.heicIlluminant(stage0.properties, ev100: ctx.ev100)
        reasons.append("[heic] illuminant \(illuminant.source)")
        let record = HEICStage0Record(
            version: Self.heicStage0Version, source: "heic", headroom: "none",
            transfer: k > 0 ? "Display P3 decode (display transfer inverted by the colour-managed decode) + tone-curve inversion \(HEICToneInverse.version) k=\(k) (approximate)"
                            : "Display P3 decode (display transfer inverted by the colour-managed decode); tone curve not inverted (k=0)",
            toneCurveK: Double(k),
            nativeSize: stage0.nativeSize, camera: Self.cameraName(stage0.properties), iso: ctx.iso,
            exposureTime: ctx.exposureTime, fNumber: ctx.fNumber, stockExposureEV: ev, stockExposureRequestedEV: requestedEV,
            userExposureBiasEV: st.userExposureBiasEV, illuminant: illuminant,
            notes: ["no highlight headroom: highlights clipped by the camera stay clipped",
                    "Apple local tone map, noise reduction and sharpening are baked in; grain goes on top",
                    "tone inversion is an approximation with a provisional strength; cct / tint are an EXIF estimate, not a measurement"])
        var recipe = DecodeRecipe(file: url.lastPathComponent, settings: st, decoderVersion: Self.heicDecoderVersion,
                                  supportedDecoderVersions: [Self.heicDecoderVersion], defaults: Self.heicZeroParameters,
                                  effective: Self.heicZeroParameters, support: Self.heicNoSupport, nativeSize: stage0.nativeSize,
                                  scaleFactor: min(max(scaleFactor, 0.01), 1), camera: record.camera, iso: ctx.iso,
                                  exposureTime: ctx.exposureTime, decisions: reasons)
        recipe.decoderVersionSource = "heic stage 0-H"
        recipe.pluginsEnabled = active.map(\.id)
        recipe.heicStage0 = record
        return Base(image: image, recipe: recipe, settings: st, context: ctx, personMask: a.personMask, skyMask: a.skyMask,
                    developedFor: nil, active: active, ran: [], pluginContext: pctx)
    }
}
#endif
