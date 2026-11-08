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
    /// After CIRAWFilter decode, before the look. `ctx` can decode the plain SDR base on demand.
    func afterDecode(_ image: CIImage, settings: RenderSettings, ctx: PluginRenderContext) throws -> (CIImage, [String])
    /// After look + skin protection + grain/halation.
    func afterFinish(_ image: CIImage, settings: RenderSettings, finish: FilmFinish?, ctx: PluginRenderContext) throws -> (CIImage, [String])
}

public extension DevelopPlugin {
    func decide(context: SceneContext, settings: inout RenderSettings) -> [String] { [] }
    func afterDecode(_ image: CIImage, settings: RenderSettings, ctx: PluginRenderContext) throws -> (CIImage, [String]) { (image, []) }
    func afterFinish(_ image: CIImage, settings: RenderSettings, finish: FilmFinish?, ctx: PluginRenderContext) throws -> (CIImage, [String]) { (image, []) }
}

public struct PluginRenderContext {
    public let renderer: Renderer
    /// Decodes the same file with the same settings but without anything a plugin added (no EDR, no tone map).
    public let decodeBase: () throws -> CIImage
}

public struct PluginRegistry: Sendable {
    public var available: [any DevelopPlugin]
    /// Ids that run when `RenderSettings.plugins` is nil.
    public var defaultEnabled: [String]

    public init(available: [any DevelopPlugin], defaultEnabled: [String]) {
        self.available = available; self.defaultEnabled = defaultEnabled
    }

    /// Everything shipped so far, all enabled by default.
    public static let standard = PluginRegistry(available: [HighlightRecoveryPlugin(), CameraMatchPlugin(), VignettePlugin()],
                                                defaultEnabled: ["highlightRecovery", "cameraMatch", "vignette"])
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

    /// Display-encoded luminance histogram of the reference at ~512 px (same measure as SceneContext.lumaHistogram).
    static func referenceHistogram(_ path: String, renderer: Renderer, bins: Int) -> [Double]? {
        guard let img = CIImage(contentsOf: URL(fileURLWithPath: path), options: [.applyOrientationProperty: true]) else { return nil }
        return renderer.lumaHistogram(small(img), bins: bins)
    }

    public static func small(_ img: CIImage, longEdge: CGFloat = 512) -> CIImage {
        let e = img.extent
        let s = min(1, longEdge / max(e.width, e.height))
        return img.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY)).transformed(by: CGAffineTransform(scaleX: s, y: s))
    }

    public func decide(context: SceneContext, settings: inout RenderSettings) -> [String] {
        guard let ref = settings.cameraReference else { return [] }
        guard let ours = context.lumaHistogram, let theirs = Self.referenceHistogram(ref, renderer: Renderer(), bins: ours.count) else {
            return ["camera reference \((ref as NSString).lastPathComponent) unreadable or no histogram: skipped"]
        }
        let off = ToneMatch.exposureOffsetEV(candidate: ours, reference: theirs)
        guard abs(off) >= 0.05 else { return [String(format: "camera HEIC mid-tones within %.2f EV: no exposure change", off)] }
        let before = settings.exposure ?? 0
        settings.exposure = before + Float(off)
        return [String(format: "camera HEIC mid-tones %+.2f EV vs Apple's default render -> exposure %.2f -> %.2f (bounded -1...+0.5)", off, before, before + Float(off))]
    }

    public func afterDecode(_ image: CIImage, settings st: RenderSettings, ctx: PluginRenderContext) throws -> (CIImage, [String]) {
        guard let ref = st.cameraReference else { return (image, []) }
        let bins = 256
        guard let theirs = Self.referenceHistogram(ref, renderer: ctx.renderer, bins: bins),
              let ours = ctx.renderer.lumaHistogram(Self.small(image), bins: bins) else {
            return (image, ["camera reference unreadable: tone curve skipped"])
        }
        let c = ToneMatch.curve(candidate: ours, reference: theirs)
        let dev = ToneMatch.deviation(c)
        guard dev > 0.005 else { return (image, [String(format: "tone curve vs camera HEIC within %.3f: not applied", dev)]) }
        let strength = st.cameraMatchStrength ?? 1
        let out = try ctx.renderer.applyLook(ToneMatch.lut(c), to: image, intensity: strength)
        let pts = stride(from: 0, to: c.count, by: max(1, c.count / 6)).map { String(format: "%.2f>%.2f", c[$0].x, c[$0].y) }.joined(separator: " ")
        return (out, [String(format: "tone curve to camera HEIC (quantile match, max shift %.3f, strength %.2f): %@", dev, strength, pts)])
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
#endif
