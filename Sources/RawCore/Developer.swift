#if canImport(CoreImage)
import CoreImage
import Foundation

/// The whole develop pipeline in one place, shared by the CLI and (later) the app:
/// analyse (auto only) → CIRAWFilter decode → highlight tone map → look.
public final class Developer: @unchecked Sendable {
    public let decoder = RawDecoder()
    public let renderer: Renderer

    public init(renderer: Renderer = Renderer()) { self.renderer = renderer }

    public struct Analysis: Codable, Sendable {
        public var context: SceneContext
        public var defaults: DecodeParameters
        public var support: DecoderSupport
        public var seconds: Double
    }

    public struct Output {
        public var image: CIImage
        public var recipe: DecodeRecipe
        public var context: SceneContext?
    }

    /// Scene analysis on small renders: scene-linear 512 px (light statistics), Apple default 1024 px
    /// (what the user would see + Vision), explicit EDR 512 px (highlight headroom).
    public func analyze(url: URL, decoderVersion: String? = nil) throws -> Analysis {
        let t0 = Date()
        let s512 = try decoder.scaleFactor(url: url, longEdge: 512)
        let s1024 = try decoder.scaleFactor(url: url, longEdge: 1024)
        let lin = try decoder.decode(url: url, settings: RenderSettings(mode: .sceneLinear, decoderVersion: decoderVersion), scaleFactor: s512)
        var c = SceneContext.measure(sceneLinear: try renderer.linearImage(lin.image), iso: lin.recipe.iso)
        c.exposureTime = lin.recipe.exposureTime

        let disp = try decoder.decode(url: url, settings: RenderSettings(mode: .appleDefault, decoderVersion: decoderVersion), scaleFactor: s1024)
        c.displayClippedFraction = SceneContext.clippedFraction(try renderer.linearImage(disp.image).downsampled(by: 2))
        #if canImport(Vision)
        if let cg = renderer.cgImage(disp.image) { VisionAnalyzer.enrich(&c, image: cg) }
        #endif

        var edr = RenderSettings(mode: .explicit, decoderVersion: decoderVersion)
        edr.extendedDynamicRangeAmount = 1
        let e = try decoder.decode(url: url, settings: edr, scaleFactor: s512)
        c.edrHeadroom = SceneContext.headroom(try renderer.linearImage(e.image))
        return Analysis(context: c, defaults: lin.recipe.defaults, support: lin.recipe.support, seconds: Date().timeIntervalSince(t0))
    }

    /// Develop with fixed settings, or with `auto` (analysis + DecisionEngine on top of `settings`).
    public func develop(url: URL, settings: RenderSettings, auto: Bool, scaleFactor: Float, analysis: Analysis? = nil) throws -> Output {
        var st = settings
        var reasons: [String] = []
        var ctx: SceneContext?
        if auto {
            let a = try analysis ?? analyze(url: url, decoderVersion: settings.decoderVersion)
            var base = RenderSettings(mode: .explicit, decoderVersion: settings.decoderVersion, look: settings.look, lookIntensity: settings.lookIntensity)
            base.ccm = settings.ccm
            base.stock = settings.stock
            base.finish = settings.finish
            let d = DecisionEngine.decide(context: a.context, defaults: a.defaults, support: a.support, base: base)
            st = d.settings
            reasons = d.reasons + [String(format: "analysis %.2fs", a.seconds)]
            ctx = a.context
        }
        var out = try decoder.decode(url: url, settings: st, scaleFactor: scaleFactor, decisions: reasons)
        var image = out.image
        if let h = st.toneMapSourceHeadroom {
            // 1. Highlight clarity in the EDR domain, before compression, so it cannot push pixels past white.
            if let c = st.highlightClarity, c > 0 {
                image = renderer.highlightClarity(image, amount: c)
                out.recipe.decisions.append(String(format: "highlight clarity %.2f before tone map (CIUnsharpMask r=1.2%% long edge, luminance mask 0.30-0.75)", c))
            }
            // 2. Compress the EDR headroom into SDR.
            let (mapped, how) = renderer.toneMapHeadroom(image, sourceHeadroom: h)
            image = mapped
            out.recipe.decisions.append("highlight tone map: \(how)")
            // 3. Local recovery: keep Apple's own pixels wherever Apple did not (nearly) clip, and use the
            //    recovered render only there. Avoids the grey veil a global compression puts on the whole frame.
            if st.highlightRecoveryLocal ?? true {
                var b = st
                b.extendedDynamicRangeAmount = nil; b.toneMapSourceHeadroom = nil; b.highlightClarity = nil; b.highlightRecoveryLocal = nil
                let base = try decoder.decode(url: url, settings: b, scaleFactor: scaleFactor).image
                image = renderer.blendRecoveredHighlights(recovered: image, base: base)
                out.recipe.decisions.append("local recovery: recovered render blended over the SDR decode where its luminance > 0.80 (soft mask, blur 0.4% long edge)")
            }
        }
        // Film stock: supplies look, intensity and finish unless they were set explicitly.
        let stock = st.stock.flatMap(FilmStock.named)
        if let lut = try renderer.resolveLook(st.look) {
            image = try renderer.applyLook(lut, to: image, intensity: st.lookIntensity)
        } else if let stock {
            image = try renderer.applyLook(stock.look.lut(), to: image, intensity: stock.lookIntensity)
        }
        if let finish = st.finish ?? stock?.finish, !finish.isNone {
            image = FilmFinisher.apply(image, finish)
            out.recipe.decisions.append(String(format: "film finish%@: grain %.2f @ %.3f%% short edge (seed %u), halation %.2f (Y>%.2f, r %.2f%%), vignette %.2f",
                                               stock.map { " (\($0.name))" } ?? "", finish.grainAmount, finish.grainSize, finish.grainSeed,
                                               finish.halationAmount, finish.halationThreshold, finish.halationRadius, finish.vignette))
        }
        return Output(image: image, recipe: out.recipe, context: ctx)
    }
}
#endif

#if canImport(Vision) && canImport(CoreImage)
import CoreGraphics
import Vision

public enum VisionAnalyzer {
    /// Adds faces and classification labels. Failures (e.g. no ANE/GPU in CI) leave the fields nil.
    public static func enrich(_ ctx: inout SceneContext, image: CGImage) {
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        let faces = VNDetectFaceRectanglesRequest()
        let classify = VNClassifyImageRequest()
        do {
            try handler.perform([faces, classify])
            let rects = faces.results ?? []
            ctx.faceCount = rects.count
            ctx.largestFaceArea = rects.map { Double($0.boundingBox.width * $0.boundingBox.height) }.max() ?? 0
            var labels: [String: Double] = [:]
            for o in (classify.results ?? []) where o.confidence >= 0.3 { labels[o.identifier] = Double(o.confidence) }
            ctx.labels = labels
        } catch {
            ctx.faceCount = nil; ctx.labels = nil
        }
    }
}
#endif
