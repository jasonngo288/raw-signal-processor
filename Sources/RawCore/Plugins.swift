#if canImport(CoreImage)
import CoreImage
import Foundation

/// Optional stages that are NOT part of the roadmap architecture (docs/ROADMAP.md, "Extras").
/// Each one can be unplugged at any time: per render (`RenderSettings.plugins`), per developer
/// (`Developer(plugins:)`) or from the CLI (`--plugins none|id,id`). With no plugins the pipeline is exactly
/// the roadmap core. Every plugin that runs is listed in the recipe (`DecodeRecipe.plugins`).
public protocol DevelopPlugin: Sendable {
    /// Stable id used in settings, CLI and recipes.
    var id: String { get }
    var summary: String { get }
    /// After DecisionEngine: may change decode settings (bounded) and returns the reasons it logs.
    func decide(context: SceneContext, settings: inout RenderSettings) -> [String]
    /// Same, with Apple's per-file decode defaults (for plugins that scale a default). Defaults to the call above.
    func decide(context: SceneContext, defaults: DecodeParameters, settings: inout RenderSettings) -> [String]
    /// After CIRAWFilter decode, before the look. `ctx` can decode the plain SDR base on demand.
    func afterDecode(_ image: CIImage, settings: RenderSettings, ctx: PluginRenderContext) throws -> (CIImage, [String])
    /// After look + skin protection, before grain/halation: effects that happen at exposure on film (a light leak
    /// fogs the emulsion, so grain must sit on top of it).
    func beforeGrain(_ image: CIImage, settings: RenderSettings, finish: FilmFinish?, ctx: PluginRenderContext) throws -> (CIImage, [String])
    /// After look + skin protection + grain/halation.
    func afterFinish(_ image: CIImage, settings: RenderSettings, finish: FilmFinish?, ctx: PluginRenderContext) throws -> (CIImage, [String])
    /// Look stage for a stock whose LUT is not made for the display base (`FilmStock.lookInput`). Return the looked
    /// image (full strength) to take over the look, or nil to leave it to the core.
    func look(stock: FilmStock, settings: RenderSettings, ctx: PluginRenderContext) throws -> (CIImage, [String])?
}

public extension DevelopPlugin {
    func decide(context: SceneContext, settings: inout RenderSettings) -> [String] { [] }
    func decide(context: SceneContext, defaults: DecodeParameters, settings: inout RenderSettings) -> [String] {
        decide(context: context, settings: &settings)
    }
    func afterDecode(_ image: CIImage, settings: RenderSettings, ctx: PluginRenderContext) throws -> (CIImage, [String]) { (image, []) }
    func beforeGrain(_ image: CIImage, settings: RenderSettings, finish: FilmFinish?, ctx: PluginRenderContext) throws -> (CIImage, [String]) { (image, []) }
    func afterFinish(_ image: CIImage, settings: RenderSettings, finish: FilmFinish?, ctx: PluginRenderContext) throws -> (CIImage, [String]) { (image, []) }
    func look(stock: FilmStock, settings: RenderSettings, ctx: PluginRenderContext) throws -> (CIImage, [String])? { nil }
}

public struct PluginRenderContext {
    public let renderer: Renderer
    /// Decodes the same file with the same settings but without anything a plugin added (no EDR, no tone map).
    public let decodeBase: () throws -> CIImage
    /// The scene analysis of this render (auto only).
    public var scene: SceneContext? = nil
    /// Decodes the same file scene-linear (Apple's tone removed) with this render's colour, white balance and exposure.
    public var decodeSceneLinear: (() throws -> CIImage)? = nil
    /// Vision person mask of the analysis (any size), when the caller has one. Used by `lightLeak` (x0.4 inside it).
    /// OPEN: Developer.swift does not fill it yet, so the leak is not attenuated on people until it does.
    public var personMask: CIImage? = nil
}

public struct PluginRegistry: Sendable {
    public var available: [any DevelopPlugin]
    /// Ids that run when `RenderSettings.plugins` is nil.
    public var defaultEnabled: [String]

    public init(available: [any DevelopPlugin], defaultEnabled: [String]) {
        self.available = available; self.defaultEnabled = defaultEnabled
    }

    /// Everything shipped so far, all enabled by default.
    public static let standard = PluginRegistry(available: [HighlightRecoveryPlugin(), CameraMatchPlugin(), VignettePlugin(), LogLookPlugin(), FilmDevelopPlugin(), LightLeakPlugin(), SkyMaskPlugin()],
                                                defaultEnabled: ["highlightRecovery", "cameraMatch", "vignette", "logLook", "filmDevelop", "lightLeak", "skyMask"])
    /// Roadmap core only.
    public static let none = PluginRegistry(available: [], defaultEnabled: [])

    /// Plugins to run for these settings, in registry order. Unknown ids are an error, not silently ignored.
    public func active(for settings: RenderSettings) throws -> [any DevelopPlugin] {
        let wanted = settings.plugins ?? defaultEnabled
        let known = Set(available.map(\.id))
        if let bad = wanted.first(where: { !known.contains($0) }) {
            throw RawCoreError.invalidSettings("unknown plugin \(bad); available: \(available.map(\.id).joined(separator: ", "))")
        }
        return available.filter { wanted.contains($0.id) }
    }
}

/// Extra: local highlight recovery (EDR decode → clarity → CIToneMapHeadroom → blended only near white).
public struct HighlightRecoveryPlugin: DevelopPlugin {
    public let id = "highlightRecovery"
    public let summary = "recover highlights Apple's tone curve clips (EDR + CIToneMapHeadroom, local blend)"
    public init() {}

    public func decide(context: SceneContext, settings: inout RenderSettings) -> [String] {
        // Without CIToneMapHeadroom (iOS 17) an EDR decode would only clip harder: do not ask for it at all,
        // so the recipe stays truthful and no extra decodes are spent.
        guard CIFilter(name: "CIToneMapHeadroom") != nil else {
            var probe = settings
            let would = HighlightRecoveryRule.decide(context: context, settings: &probe)
            return probe.toneMapSourceHeadroom == nil ? would : ["would recover highlights but CIToneMapHeadroom is unavailable on this OS: skipped"]
        }
        return HighlightRecoveryRule.decide(context: context, settings: &settings)
    }

    public func afterDecode(_ image: CIImage, settings st: RenderSettings, ctx: PluginRenderContext) throws -> (CIImage, [String]) {
        guard let h = st.toneMapSourceHeadroom else { return (image, []) }
        var why: [String] = []
        var img = image
        if let c = st.highlightClarity, c > 0 {
            img = ctx.renderer.highlightClarity(img, amount: c)
            why.append(String(format: "highlight clarity %.2f before tone map", c))
        }
        let (mapped, how, applied) = ctx.renderer.toneMapHeadroomChecked(img, sourceHeadroom: h)
        guard applied else {
            // Without a tone map the EDR image would clip harder than Apple's: fall back to the SDR base.
            return (try ctx.decodeBase(), why + ["highlight tone map: \(how); fell back to the SDR decode"])
        }
        why.append("highlight tone map: \(how)")
        if st.highlightRecoveryLocal ?? true {
            img = ctx.renderer.blendRecoveredHighlights(recovered: mapped, base: try ctx.decodeBase())
            why.append("local recovery: recovered render blended over the SDR decode where its luminance > 0.80")
        } else {
            img = mapped
        }
        return (img, why)
    }
}

/// Extra: match exposure and tones to the camera's own HEIC from the same shutter press (`settings.cameraReference`).
/// Without a reference it does nothing. Stage 1 (decide): exposure offset in the CIRAWFilter decode, from the mid-tone
/// quantiles of Apple's default render (context.lumaHistogram) vs the HEIC. Stage 2 (afterDecode): the remaining tone
/// difference as a monotone luminance curve (ToneMatch), applied as a LUT before the look.
public struct CameraMatchPlugin: DevelopPlugin {
    public let id = "cameraMatch"
    public let summary = "match exposure + tones to the camera HEIC from the same press (ToneMatch)"
    public init() {}

    /// Bins of the tone-curve histogram (afterDecode).
    public static let fineBins = 256
    /// Long edge both sides of every comparison are measured at: the analysis' Apple render, our developed image and
    /// the camera HEIC (was 512 px, 2026-11-09: one size everywhere, and the analysis reuses the Vision render).
    public static let histogramLongEdge: CGFloat = 1024

    /// Display-encoded luminance histogram of the reference at `histogramLongEdge` (same measure as SceneContext.lumaHistogram).
    public static func referenceHistogram(_ path: String, renderer: Renderer, bins: Int) -> [Double]? {
        guard let img = CIImage(contentsOf: URL(fileURLWithPath: path), options: [.applyOrientationProperty: true]) else { return nil }
        return renderer.lumaHistogram(small(img), bins: bins)
    }

    public static func small(_ img: CIImage, longEdge: CGFloat = histogramLongEdge) -> CIImage {
        let e = img.extent
        let s = min(1, longEdge / max(e.width, e.height))
        return img.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY)).transformed(by: CGAffineTransform(scaleX: s, y: s))
    }

    public func decide(context: SceneContext, defaults: DecodeParameters, settings: inout RenderSettings) -> [String] {
        // The reference: histograms stored by the analysis (HEIC may be gone), else the HEIC file itself.
        let stored = context.cameraReferenceHistogram.flatMap { $0.count == context.lumaHistogram?.count ? $0 : nil }
        guard stored != nil || settings.cameraReference != nil else { return [] }
        guard let ours = context.lumaHistogram,
              let theirs = stored ?? settings.cameraReference.flatMap({ Self.referenceHistogram($0, renderer: Renderer(), bins: ours.count) }) else {
            return ["camera reference \(settings.cameraReference.map { ($0 as NSString).lastPathComponent } ?? "") unreadable or no histogram: skipped"]
        }
        let source = (stored != nil ? "stored analysis" : "HEIC file") + String(format: ", %.0f px", Self.histogramLongEdge)
        let off = ToneMatch.exposureOffsetEV(candidate: ours, reference: theirs)
        guard abs(off) >= 0.05 else { return [String(format: "camera HEIC (%@) mid-tones within %.2f EV: no exposure change", source, off)] }
        let before = settings.exposure ?? 0
        settings.exposure = before + Float(off)
        var why = [String(format: "camera HEIC (%@) mid-tones %+.2f EV vs Apple's default render -> exposure %.2f -> %.2f (bounded -1...+0.5)", source, off, before, before + Float(off))]
        // Shadows: Apple's shadow boost (0.9 on ProRAW) keeps deep shadows ~1.5 stops above the camera HEIC after the
        // exposure match, more than the curve can take back (its gain is bounded). Lower the boost in the decode, by
        // how far our shadows sit above the HEIC's (WORK_LOG 2026-11-09). Only lowers, never raises.
        let gap = ToneMatch.shadowGapEV(candidate: ours, reference: theirs, exposureOffsetEV: off)
        do {
            let d = settings.boostShadowAmount ?? defaults.boostShadowAmount
            let b = ToneMatch.shadowBoost(default: Double(d), gapEV: gap)
            if b < Double(d) - 0.01 {
                settings.boostShadowAmount = Float(b)
                why.append(String(format: "shadows %+.2f EV above camera HEIC after exposure match -> boostShadow %.2f -> %.2f", gap, d, b))
            } else {
                why.append(String(format: "shadows %+.2f EV vs camera HEIC after exposure match: boostShadow kept", gap))
            }
        }
        // highlightRecovery's tone map (decided at the old exposure) is kept: dropping it after the exposure change
        // brought clipping back from 0.3 % to 2-2.6 % (CI 42491918370), because Apple's SDR curve still clips there.
        return why
    }

    public func afterDecode(_ image: CIImage, settings st: RenderSettings, ctx: PluginRenderContext) throws -> (CIImage, [String]) {
        let stored = ctx.scene?.cameraReferenceHistogramFine
        guard stored != nil || st.cameraReference != nil else { return (image, []) }
        let bins = Self.fineBins
        guard let theirs = stored ?? st.cameraReference.flatMap({ Self.referenceHistogram($0, renderer: ctx.renderer, bins: bins) }),
              let ours = ctx.renderer.lumaHistogram(Self.small(image), bins: bins) else {
            return (image, ["camera reference unreadable: tone curve skipped"])
        }
        let c = ToneMatch.curve(candidate: ours, reference: theirs)
        let dev = ToneMatch.deviation(c)
        guard dev > 0.005 else { return (image, [String(format: "tone curve vs camera HEIC within %.3f: not applied", dev)]) }
        let strength = st.cameraMatchStrength ?? 1
        // A stock with a develop profile (RR roll stocks) keeps only part of the HEIC's tone: its Smart-HDR curve would
        // otherwise be imported into the film stock (plan §5). Exposure match (decide) is not touched.
        var curve = c
        var stockNote = ""
        if let stock = try st.resolvedStock(), let fd = stock.develop {
            let name = st.stock ?? stock.name
            curve = ToneMatch.blended(c, strength: Double(fd.cameraMatchCurveStrength))
            stockNote = String(format: "; stock %@ (%@): curve blended toward identity at %.2f (max shift %.3f -> %.3f), exposure match unchanged",
                               name, fd.profile, fd.cameraMatchCurveStrength, dev, ToneMatch.deviation(curve))
        }
        let out = try ctx.renderer.applyLook(ToneMatch.lut(curve), to: image, intensity: strength)
        let pts = stride(from: 0, to: curve.count, by: max(1, curve.count / 6)).map { String(format: "%.2f>%.2f", curve[$0].x, curve[$0].y) }.joined(separator: " ")
        return (out, [String(format: "tone curve to camera HEIC (quantile match, max shift %.3f, strength %.2f): %@%@", dev, strength, pts, stockNote)])
    }
}

/// Extra: a soft film base. Reads `settings.stock` -> `FilmStock.develop` and scales Apple's per-file sharpness (and luma NR cap,
/// highlight clarity, ProRAW detail) so a stock's look sits on a base without the phone's crunchy sharpening.
/// Registered after highlightRecovery so it can scale that plugin's clarity. No stock or no `develop` = no-op.
public struct FilmDevelopPlugin: DevelopPlugin {
    public let id = "filmDevelop"
    public let summary = "film-stock decode profile: softer sharpening, bounded luma NR, less highlight clarity (stock.develop)"
    public init() {}

    public func decide(context: SceneContext, defaults: DecodeParameters, settings: inout RenderSettings) -> [String] {
        // A stock that does not resolve is not skipped silently: `RenderSettings.validate()` throws it at decode.
        guard let stock = try? settings.resolvedStock(), let dev = stock.develop else { return [] }
        let why = dev.apply(context: context, defaults: defaults, settings: &settings)
        return why.isEmpty ? [] : why
    }
}

/// Extra: light leak from the stock's `FilmFinish.lightLeak` (spec: `.orchestration/looks/RR_LOOKS_2026-11-11.md`).
/// Needs the frame's place in the roll (`RenderSettings.rollID / rollFrameIndex / rollFrameCount`); a stock without a leak,
/// or a render without a roll position, is left untouched (the second case says so in the recipe).
/// Runs after grain/halation (the afterFinish hook): the leak is not grained. Unplugged = no leak at all.
public struct LightLeakPlugin: DevelopPlugin {
    public let id = "lightLeak"
    public let summary = "light leak from the stock's finish, drawn per roll frame (seeded, deterministic), before grain"
    public init() {}

    /// Runs before grain / halation: a leak is light on the emulsion, so the grain of the developed film covers it.
    public func beforeGrain(_ image: CIImage, settings: RenderSettings, finish: FilmFinish?, ctx: PluginRenderContext) throws -> (CIImage, [String]) {
        guard let spec = finish?.lightLeak else { return (image, []) }
        guard let frame = settings.rollFrameIndex, let count = settings.rollFrameCount else {
            return (image, ["no leak: the frame's place in the roll is not set (rollFrameIndex / rollFrameCount)"])
        }
        let roll = settings.rollID ?? ""
        guard let plan = LightLeakPlanner.plan(spec: spec, rollID: roll, frame: frame, count: count) else {
            return (image, ["no leak: frame \(frame) is outside a roll of \(count)"])
        }
        var why = [LightLeakPlanner.describe(plan, frame: frame, count: count, rollID: roll)]
        guard let leak = plan.leak else { return (image, why) }
        let out = FilmFinisher.lightLeak(image, spec: spec, leak: leak, personMask: ctx.personMask)
        why.append(String(format: "screen in linear light, peak add %.3f (%.2f x %.2f amount x %.2f strength), ceiling %.2f encoded, person mask %@",
                          spec.peakAdd * spec.amount * leak.strength, spec.peakAdd, spec.amount, leak.strength, spec.encodedCap,
                          ctx.personMask != nil ? String(format: "x%.2f", spec.personFactor) : "not available: no attenuation"))
        return (out, why)
    }
}

/// Extra: vignette. Reads `FilmFinish.vignette` (stocks carry a value); unplugged = no vignette at all.
public struct VignettePlugin: DevelopPlugin {
    public let id = "vignette"
    public let summary = "corner darkening from the stock's finish"
    public init() {}

    public func afterFinish(_ image: CIImage, settings: RenderSettings, finish: FilmFinish?, ctx: PluginRenderContext) throws -> (CIImage, [String]) {
        guard let v = finish?.vignette, v > 0 else { return (image, []) }
        return (FilmFinisher.vignette(image, v), [String(format: "vignette %.2f", v)])
    }
}
/// Extra: looks authored for log footage (`FilmStock.lookInput = .log`). Decodes the file scene-linear (Apple's tone
/// removed), scales by 1/`LogLook.headroom`, and applies one composite cube: Rec.2020 → log curve → the user's LUT →
/// Rec.709 output as Display P3. Unplugged, the core applies such a LUT to the display base and says so in the recipe.
public struct LogLookPlugin: DevelopPlugin {
    public let id = "logLook"
    public let summary = "apply LOG .cube looks on a scene-linear, log-encoded decode instead of the display base"
    public init() {}

    final class Cache: @unchecked Sendable {
        static let shared = Cache()
        private let lock = NSLock()
        private var items: [String: CubeLUT] = [:]
        func get(_ k: String, _ make: () -> CubeLUT) -> CubeLUT {
            lock.lock(); defer { lock.unlock() }
            if let c = items[k] { return c }
            let c = make(); items[k] = c; return c
        }
    }

    public func look(stock: FilmStock, settings: RenderSettings, ctx: PluginRenderContext) throws -> (CIImage, [String])? {
        guard case .log(let curve) = stock.lookInput else { return nil }
        guard let decodeSceneLinear = ctx.decodeSceneLinear else {
            return nil   // no scene-linear decode available (core render without a file): the core handles it
        }
        let lut = stock.lut()
        let cube = Cache.shared.get("\(stock.name)|\(curve.rawValue)|\(stock.logPrimaries.rawValue)") { LogLook.composite(lut, curve: curve, primaries: stock.logPrimaries) }
        let k = CGFloat(1 / LogLook.headroom)
        let scaled = try decodeSceneLinear().applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: k, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: k, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: k, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
        ])
        let out = try ctx.renderer.applyLook(cube, to: scaled, intensity: 1)
        return (out, [String(format: "%@: LUT made for log input → scene-linear decode, %@, %@, LUT (%d³ composite, headroom %.0f×)",
                             stock.name, stock.logPrimaries.rawValue, curve.rawValue, cube.size, LogLook.headroom)])
    }
}
#endif
