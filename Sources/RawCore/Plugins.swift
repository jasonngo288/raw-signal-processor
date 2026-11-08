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
    public static let standard = PluginRegistry(available: [HighlightRecoveryPlugin(), VignettePlugin()],
                                                defaultEnabled: ["highlightRecovery", "vignette"])
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
