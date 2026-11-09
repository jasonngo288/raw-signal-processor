#if canImport(CoreImage)
import CoreImage
import Foundation

/// The develop pipeline of docs/ROADMAP.md, shared by the CLI and the app:
///
///   analyse (512 px stats + GPU histogram, Vision at 1024 px: scene, faces, person mask, saliency, CCT)
///   → DecisionEngine (bounded, logged) → plugins.decide
///   → CIRAWFilter (pinned decoder, explicit parameters, per-model CCM + exposure in linearSpaceFilter)
///   → plugins.afterDecode → look → skin protection (Vision mask, CIBlendWithMask) → grain / halation
///   → plugins.afterFinish → export (HEIC 10-bit P3 with recipe embedded) .
///
/// Plugins (Plugins.swift) are the extras outside the roadmap; `Developer(plugins: .none)` is the pure core.
public final class Developer: @unchecked Sendable {
    public let decoder = RawDecoder()
    public let renderer: Renderer
    public var plugins: PluginRegistry
    public var calibration: CalibrationTable

    public init(renderer: Renderer = Renderer(), plugins: PluginRegistry = .standard, calibration: CalibrationTable = .empty) {
        self.renderer = renderer; self.plugins = plugins; self.calibration = calibration
    }

    public struct Analysis: Codable, @unchecked Sendable {
        public var context: SceneContext
        public var defaults: DecodeParameters
        public var support: DecoderSupport
        public var seconds: Double
        /// Vision person mask (any size; not serialised).
        public var personMask: CIImage? = nil

        enum CodingKeys: String, CodingKey { case context, defaults, support, seconds }
    }

    public struct Output {
        public var image: CIImage
        public var recipe: DecodeRecipe
        public var context: SceneContext?
    }

    /// Same as `analyze`, off the caller's thread (roadmap: analysis runs in the background).
    public func analyzeInBackground(url: URL, decoderVersion: String? = nil) async throws -> Analysis {
        try await Task.detached(priority: .utility) { try self.analyze(url: url, decoderVersion: decoderVersion) }.value
    }

    /// Scene analysis on small renders: scene-linear 512 px (light statistics), Apple default 512 px (display clipping,
    /// GPU histogram), Apple default 1024 px for Vision (faces and people are missed at 512 px, WORK_LOG 2026-11-07),
    /// explicit EDR 512 px (highlight headroom, only when the highlightRecovery plugin is available).
    public func analyze(url: URL, decoderVersion: String? = nil) throws -> Analysis {
        let t0 = Date()
        // Measure on the same decoder version the render will use (requested, else DecoderPolicy).
        let supported = try decoder.inspect(url: url).supported
        let decoderVersion = decoderVersion ?? DecoderPolicy.pick(supported: supported)
        let s512 = try decoder.scaleFactor(url: url, longEdge: 512)
        let lin = try decoder.decode(url: url, settings: RenderSettings(mode: .sceneLinear, decoderVersion: decoderVersion), scaleFactor: s512)
        var c = SceneContext.measure(sceneLinear: try renderer.linearImage(lin.image), iso: lin.recipe.iso)
        c.exposureTime = lin.recipe.exposureTime
        c.cct = Double(lin.recipe.defaults.neutralTemperature)
        c.tint = Double(lin.recipe.defaults.neutralTint)

        let disp512 = try decoder.decode(url: url, settings: RenderSettings(mode: .appleDefault, decoderVersion: decoderVersion), scaleFactor: s512)
        c.displayClippedFraction = SceneContext.clippedFraction(try renderer.linearImage(disp512.image))
        c.lumaHistogram = renderer.lumaHistogram(disp512.image)

        var mask: CIImage?
        #if canImport(Vision)
        let s1024 = try decoder.scaleFactor(url: url, longEdge: 1024)
        let disp = try decoder.decode(url: url, settings: RenderSettings(mode: .appleDefault, decoderVersion: decoderVersion), scaleFactor: s1024)
        if let cg = renderer.cgImage(disp.image) {
            mask = VisionAnalyzer.enrich(&c, image: cg)
            if let mask { c.personFraction = renderer.areaMean(mask) }
        }
        #endif

        if plugins.defaultEnabled.contains("highlightRecovery") {   // plugin work only when the plugin is on
            var edr = RenderSettings(mode: .explicit, decoderVersion: decoderVersion)
            edr.extendedDynamicRangeAmount = 1
            let e = try decoder.decode(url: url, settings: edr, scaleFactor: s512)
            c.edrHeadroom = SceneContext.headroom(try renderer.linearImage(e.image))
        }
        return Analysis(context: c, defaults: lin.recipe.defaults, support: lin.recipe.support,
                        seconds: Date().timeIntervalSince(t0), personMask: mask)
    }

    /// Calibration keys for a file: model identifier, DNG UniqueCameraModel, "Make Model".
    public func cameraKeys(_ url: URL) throws -> [String?] {
        let props = try decoder.inspect(url: url).filter.properties
        let tiff = props[kCGImagePropertyTIFFDictionary as String] as? [String: Any]
        let dng = props[kCGImagePropertyDNGDictionary as String] as? [String: Any]
        let cam = [tiff?[kCGImagePropertyTIFFMake as String] as? String, tiff?[kCGImagePropertyTIFFModel as String] as? String]
            .compactMap { $0 }.joined(separator: " ")
        return CalibrationTable.candidates(uniqueCameraModel: dng?[kCGImagePropertyDNGUniqueCameraModel as String] as? String,
                                           camera: cam.isEmpty ? nil : cam)
    }

    /// Develop with fixed settings, or with `auto` (analysis + DecisionEngine + plugin rules on top of `settings`).
    public func develop(url: URL, settings: RenderSettings, auto: Bool, scaleFactor: Float, analysis: Analysis? = nil) throws -> Output {
        var st = settings
        var reasons: [String] = []
        var ctx: SceneContext?
        var personMask: CIImage?
        let active = try plugins.active(for: settings)
        var ran = Set<String>()   // plugins that actually did something (recipe.plugins)
        if auto {
            let a = try analysis ?? analyze(url: url, decoderVersion: settings.decoderVersion)
            // Everything the caller set is kept; DecisionEngine only adds/overrides bounded decode values.
            var base = settings
            base.mode = .explicit
            let d = DecisionEngine.decide(context: a.context, defaults: a.defaults, support: a.support, base: base)
            st = d.settings
            reasons = d.reasons
            for p in active {
                let before = st
                let why = p.decide(context: a.context, settings: &st)
                if st != before { ran.insert(p.id) }
                reasons += why.map { "[\(p.id)] " + $0 }
            }
            reasons.append(String(format: "analysis %.2fs", a.seconds))
            ctx = a.context
            personMask = a.personMask
        }

        // Per-model calibration: CCM + exposure offset inside linearSpaceFilter (scene-linear).
        var calibrationNote: String?
        if st.mode != .appleDefault, st.useCalibration ?? true, st.ccm == nil, st.linearExposureEV == nil {
            let keys = try cameraKeys(url)
            if let entry = calibration.entry(forAny: keys) {
                st.ccm = entry.ccm
                st.linearExposureEV = entry.exposureOffsetEV
                calibrationNote = "\(entry.model) \(entry.version) (\(entry.source))"
            } else {
                calibrationNote = "none for \(keys.compactMap { $0 }.joined(separator: " / ")): DNG matrices"
            }
        }

        var out = try decoder.decode(url: url, settings: st, scaleFactor: scaleFactor, decisions: reasons)
        out.recipe.pluginsEnabled = active.map(\.id)
        out.recipe.calibration = calibrationNote
        let decodedSettings = st
        let dec = decoder
        let pctx = PluginRenderContext(renderer: renderer, decodeBase: {
            var b = decodedSettings
            b.extendedDynamicRangeAmount = nil; b.toneMapSourceHeadroom = nil; b.highlightClarity = nil; b.highlightRecoveryLocal = nil
            return try dec.decode(url: url, settings: b, scaleFactor: scaleFactor).image
        })

        var image = out.image
        for p in active {
            let (img, why) = try p.afterDecode(image, settings: st, ctx: pctx)
            image = img
            if !why.isEmpty { ran.insert(p.id) }
            out.recipe.decisions += why.map { "[\(p.id)] " + $0 }
        }

        // Look (stock supplies look, intensity and finish unless set explicitly).
        let stock = st.stock.flatMap(FilmStock.named)
        let beforeLook = image
        var appliedLUT: CubeLUT?
        let off = st.lookIntensityOffset ?? 0
        func intensity(_ base: Float, _ lut: CubeLUT) -> Float {
            guard off != 0 else { return base }
            // Black and white is all or nothing: 95 % mono is just washed-out colour (CI 42492412535, mooncake).
            if lut.isMonochrome {
                out.recipe.decisions.append("look intensity offset skipped: black-and-white look stays at full strength")
                return base
            }
            let v = min(max(base + off, 0), 1)
            out.recipe.decisions.append(String(format: "look intensity %.2f %+.2f (scene) -> %.2f", base, off, v))
            return v
        }
        if let lut = try renderer.resolveLook(st.look) {
            image = try renderer.applyLook(lut, to: image, intensity: intensity(st.lookIntensity, lut)); appliedLUT = lut
        } else if let stock {
            let lut = stock.lut()
            image = try renderer.applyLook(lut, to: image, intensity: intensity(stock.lookIntensity, lut)); appliedLUT = lut
        }
        let looked = appliedLUT != nil
        // Skin / subject protection: on people, hold part of the look back — never for a black-and-white look
        // (judged from the LUT actually applied, so a mono .cube counts too).
        let stockLookUsed = st.look == nil && stock != nil
        let noProtection = (appliedLUT?.isMonochrome ?? false) || (stockLookUsed && !(stock?.allowsSkinProtection ?? true))
        // A preset with skinProtect (2026 spec) raises protection to at least its minimum.
        var skin = st.skinProtection
        if stockLookUsed, let m = stock?.minSkinProtection, (skin ?? 0) < m {
            skin = m
            out.recipe.decisions.append(String(format: "skin protection %.2f requested by %@ (skinProtect)", m, stock!.name))
        }
        if let s = skin, s > 0, looked, noProtection {
            out.recipe.decisions.append("skin protection skipped: the applied look is black and white (colour skin in a mono frame)")
        } else if let s = skin, s > 0, looked {
            if let personMask {
                image = renderer.protectSkin(looked: image, base: beforeLook, mask: personMask, strength: s)
                out.recipe.decisions.append(String(format: "skin protection %.2f through the Vision person mask (CIBlendWithMask)", s))
            } else {
                out.recipe.decisions.append("skin protection requested but no person mask (Vision unavailable or not analysed)")
            }
        }
        let finish = st.finish ?? stock?.finish
        if let finish, finish.grainAmount > 0 || finish.halationAmount > 0 {
            image = FilmFinisher.apply(image, finish)
            out.recipe.decisions.append(String(format: "film finish%@: grain %.2f @ %.3f%% short edge (seed %u), halation %.2f (Y>%.2f, r %.2f%%)",
                                               stock.map { " (\($0.name))" } ?? "", finish.grainAmount, finish.grainSize, finish.grainSeed,
                                               finish.halationAmount, finish.halationThreshold, finish.halationRadius))
        }
        for p in active {
            let (img, why) = try p.afterFinish(image, settings: st, finish: finish, ctx: pctx)
            image = img
            if !why.isEmpty { ran.insert(p.id) }
            out.recipe.decisions += why.map { "[\(p.id)] " + $0 }
        }
        out.recipe.plugins = active.map(\.id).filter { ran.contains($0) }
        return Output(image: image, recipe: out.recipe, context: ctx)
    }
}
#endif

#if canImport(Vision) && canImport(CoreImage)
import CoreGraphics
import CoreVideo
import Vision

public enum VisionAnalyzer {
    /// Faces, classification, attention saliency and person segmentation. Returns the person mask (nil if Vision
    /// could not produce one). Each request runs on its own: one failing (e.g. no ANE in CI) leaves only its fields nil.
    @discardableResult
    public static func enrich(_ ctx: inout SceneContext, image: CGImage) -> CIImage? {
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        let faces = VNDetectFaceRectanglesRequest()
        let classify = VNClassifyImageRequest()
        let saliency = VNGenerateAttentionBasedSaliencyImageRequest()
        let person = VNGeneratePersonSegmentationRequest()
        person.qualityLevel = .balanced
        person.outputPixelFormat = kCVPixelFormatType_OneComponent8

        ctx.faceCount = nil; ctx.largestFaceArea = nil; ctx.labels = nil; ctx.saliencyBox = nil
        if (try? handler.perform([faces])) != nil {
            let rects = faces.results ?? []
            ctx.faceCount = rects.count
            ctx.largestFaceArea = rects.map { Double($0.boundingBox.width * $0.boundingBox.height) }.max() ?? 0
        }
        if (try? handler.perform([classify])) != nil {
            var labels: [String: Double] = [:]
            for o in (classify.results ?? []) where o.confidence >= 0.3 { labels[o.identifier] = Double(o.confidence) }
            ctx.labels = labels
        }
        if (try? handler.perform([saliency])) != nil, let objs = saliency.results?.first?.salientObjects, let first = objs.first {
            let u = objs.dropFirst().reduce(first.boundingBox) { $0.union($1.boundingBox) }
            ctx.saliencyBox = [u.minX, u.minY, u.width, u.height].map { Double($0) }
        }
        if (try? handler.perform([person])) != nil, let buf = person.results?.first?.pixelBuffer {
            return CIImage(cvPixelBuffer: buf)
        }
        return nil
    }
}
#endif
