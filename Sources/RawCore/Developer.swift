#if canImport(CoreImage)
import CoreImage
import Foundation

/// The develop pipeline of docs/ROADMAP.md, shared by the CLI and the app, in two stages:
///
///   analyse (512 px scene-linear stats; one Apple render at 1024 px: clipping, GPU histogram, Vision faces, person mask, saliency; CCT;
///            optionally the camera HEIC's histograms) — can run at capture time and be stored (`Analysis.write`)
///   stage 1, `developBase`: DecisionEngine (bounded, logged) → plugins.decide
///            → CIRAWFilter (pinned decoder, explicit parameters, per-model CCM + exposure in linearSpaceFilter)
///            → plugins.afterDecode                                   = the base render (no look)
///   stage 2, `finish`: look → skin protection (Vision mask, CIBlendWithMask) → plugins.beforeGrain (light leak)
///            → grain / halation → plugins.afterFinish
///   → export (HEIC 10-bit P3 with recipe embedded).
///
/// `develop` = `finish(developBase(...))`. A base can be finished again with another stock (`Base.settings.stock`)
/// without decoding again. Plugins (Plugins.swift) are the extras outside the roadmap; `Developer(plugins: .none)`
/// is the pure core.
public final class Developer: @unchecked Sendable {
    public let decoder = RawDecoder()
    public let renderer: Renderer
    public var plugins: PluginRegistry
    public var calibration: CalibrationTable

    public init(renderer: Renderer = Renderer(), plugins: PluginRegistry = .standard, calibration: CalibrationTable = .empty) {
        self.renderer = renderer; self.plugins = plugins; self.calibration = calibration
    }

    /// Scene analysis of one file. Codable so it can be made at capture time and stored next to the DNG
    /// (`write(to:)` / `read(from:)`: JSON + the person mask as PNG); `develop` then uses it instead of analysing again,
    /// unless `staleReason` says it no longer fits the render.
    public struct Analysis: Codable, @unchecked Sendable {
        /// Bumped when what an analysis measures changes; an older stored analysis is re-made.
        public static let currentSchema = 4   // 4: sky mask (SkyMask.version, sky-mask.png)
        public static let fileName = "analysis.json"
        public static let maskFileName = "person-mask.png"
        public static let skyMaskFileName = "sky-mask.png"

        public var schema: Int? = Analysis.currentSchema
        public var context: SceneContext
        public var defaults: DecodeParameters
        public var support: DecoderSupport
        public var seconds: Double
        /// Decoder version the analysis decoded with (it must be the render's).
        public var decoderVersion: String? = nil
        /// Plugins enabled when it was made: decides which measurements exist (EDR headroom only with highlightRecovery).
        public var plugins: [String]? = nil
        public var sourceFile: String? = nil
        public var sourceBytes: Int64? = nil
        /// Vision person mask (any size). Not in the JSON; stored as `person-mask.png` by `write(to:)`.
        public var personMask: CIImage? = nil
        /// Heuristic sky mask (plugin `skyMask`, `SkyMask.version` in `context`), 8-bit grey. Stored as `sky-mask.png`;
        /// absent when the frame has no sky or the plugin was off (the context says which).
        public var skyMask: CIImage? = nil

        enum CodingKeys: String, CodingKey {
            case schema, context, defaults, support, seconds, decoderVersion, plugins, sourceFile, sourceBytes
        }

        /// Why this analysis cannot be used for a render of `url` with `decoderVersion` and `plugins`; nil = usable.
        public func staleReason(url: URL, decoderVersion: String, plugins: [String]) -> String? {
            if schema != Analysis.currentSchema { return "schema \(schema.map(String.init) ?? "none") != \(Analysis.currentSchema)" }
            if let n = sourceFile, n != url.lastPathComponent { return "made for \(n), not \(url.lastPathComponent)" }
            if let b = sourceBytes, let now = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value, b != now {
                return "file size changed (\(b) -> \(now) bytes)"
            }
            if let v = self.decoderVersion, v != decoderVersion { return "decoder version \(v) != render \(decoderVersion)" }
            if self.decoderVersion == nil { return "no decoder version recorded" }
            if plugins.contains("highlightRecovery"), context.edrHeadroom == nil, !(self.plugins ?? []).contains("highlightRecovery") {
                return "highlightRecovery is on but the analysis has no EDR headroom"
            }
            if plugins.contains("skyMask") {
                if context.skyMaskVersion == nil { return "skyMask is on but the analysis has no sky mask decision" }
            }
            if let v = context.skyMaskVersion, v != SkyMask.version { return "sky mask version \(v) != \(SkyMask.version)" }
            if (context.skyFraction ?? 0) >= SkyMask.minCoverage, skyMask == nil { return "sky mask image missing" }
            return nil
        }

        /// Store next to the DNG: `analysis.json` and, when there is one, `person-mask.png` (8-bit grey).
        public func write(to directory: URL, renderer: Renderer) throws {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            enc.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
            try enc.encode(self).write(to: directory.appendingPathComponent(Self.fileName), options: .atomic)
            for (mask, name) in [(personMask, Self.maskFileName), (skyMask, Self.skyMaskFileName)] {
                let url = directory.appendingPathComponent(name)
                if let m = mask {
                    guard let png = renderer.context.pngRepresentation(of: m.cropped(to: m.extent), format: .L8, colorSpace: Renderer.linearGray) else {
                        throw RawCoreError.renderFailed("\(name) failed")
                    }
                    try png.write(to: url, options: .atomic)
                } else {
                    try? FileManager.default.removeItem(at: url)
                }
            }
        }

        public static func read(from directory: URL) throws -> Analysis {
            let dec = JSONDecoder()
            dec.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
            var a = try dec.decode(Analysis.self, from: Data(contentsOf: directory.appendingPathComponent(fileName)))
            let maskURL = directory.appendingPathComponent(maskFileName)
            if FileManager.default.fileExists(atPath: maskURL.path) { a.personMask = CIImage(contentsOf: maskURL) }
            let skyURL = directory.appendingPathComponent(skyMaskFileName)
            if FileManager.default.fileExists(atPath: skyURL.path) { a.skyMask = CIImage(contentsOf: skyURL) }
            return a
        }
    }

    public struct Output {
        public var image: CIImage
        public var recipe: DecodeRecipe
        public var context: SceneContext?
    }

    /// Stage 1 result: the base render (decode + plugins.afterDecode, no look) with everything stage 2 needs.
    /// Change `settings.stock` / `look` / `lookIntensity` / `finish` before `finish(_:)` to develop it with another look;
    /// decode values in `settings` are already baked into `image`. `image` may be replaced by a stored copy of itself.
    public struct Base {
        public var image: CIImage
        public var recipe: DecodeRecipe
        public var settings: RenderSettings
        public var context: SceneContext?
        public var personMask: CIImage?
        /// Sky mask of the analysis (plugin `skyMask`); nil = none (see `context.skyFraction` / `skyGate` for why).
        public var skyMask: CIImage? = nil
        /// Develop profile the decode was made with (`FilmStock.develop.profile`, "stock: profile"); nil = none applied.
        public var developedFor: String? = nil
        var active: [any DevelopPlugin]
        var ran: Set<String>
        var pluginContext: PluginRenderContext
    }

    /// Same as `analyze`, off the caller's thread (roadmap: analysis runs in the background).
    public func analyzeInBackground(url: URL, decoderVersion: String? = nil, cameraReference: String? = nil) async throws -> Analysis {
        try await Task.detached(priority: .utility) { try self.analyze(url: url, decoderVersion: decoderVersion, cameraReference: cameraReference) }.value
    }

    /// Scene analysis on small renders: scene-linear 512 px (light statistics), one Apple default render at 1024 px for
    /// display clipping, the GPU histogram and Vision (faces and people are missed at 512 px, WORK_LOG 2026-11-07),
    /// explicit EDR 512 px (highlight headroom, only when the highlightRecovery plugin is available).
    /// With `cameraReference` (the same-press camera HEIC) its luminance histograms are stored too, so cameraMatch
    /// does not need the HEIC file at develop time.
    public func analyze(url: URL, decoderVersion: String? = nil, cameraReference: String? = nil) throws -> Analysis {
        let t0 = Date()
        // Measure on the same decoder version the render will use (requested, else DecoderPolicy).
        let decoderVersion = try decoder.pinnedVersion(url: url, requested: decoderVersion)
        let s512 = try decoder.scaleFactor(url: url, longEdge: 512)
        let lin = try decoder.decode(url: url, settings: RenderSettings(mode: .sceneLinear, decoderVersion: decoderVersion), scaleFactor: s512)
        let sceneLin = try renderer.linearImage(lin.image)
        var c = SceneContext.measure(sceneLinear: sceneLin, iso: lin.recipe.iso)
        c.exposureTime = lin.recipe.exposureTime
        c.cct = Double(lin.recipe.defaults.neutralTemperature)
        c.tint = Double(lin.recipe.defaults.neutralTint)

        // Apple's display render, once, at the size cameraMatch compares at (CameraMatchPlugin.histogramLongEdge):
        // display clipping, the luma histogram and Vision all read it (was a separate 512 px decode, 2026-11-09).
        let sDisp = try decoder.scaleFactor(url: url, longEdge: Int(CameraMatchPlugin.histogramLongEdge))
        let disp = try decoder.decode(url: url, settings: RenderSettings(mode: .appleDefault, decoderVersion: decoderVersion), scaleFactor: sDisp)
        c.displayClippedFraction = SceneContext.clippedFraction(try renderer.linearImage(disp.image))
        c.lumaHistogram = renderer.lumaHistogram(disp.image)

        var mask: CIImage?
        #if canImport(Vision)
        if let cg = renderer.cgImage(disp.image) {
            mask = VisionAnalyzer.enrich(&c, image: cg)
            if let mask { c.personFraction = renderer.areaMean(mask) }
        }
        #endif

        // Sky mask (plugin skyMask): the label gate first (Vision labels), then the heuristic on the scene-linear 512 px render.
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

        if plugins.defaultEnabled.contains("highlightRecovery") {   // plugin work only when the plugin is on
            var edr = RenderSettings(mode: .explicit, decoderVersion: decoderVersion)
            edr.extendedDynamicRangeAmount = 1
            let e = try decoder.decode(url: url, settings: edr, scaleFactor: s512)
            c.edrHeadroom = SceneContext.headroom(try renderer.linearImage(e.image))
        }
        if let ref = cameraReference {
            c.cameraReferenceHistogram = CameraMatchPlugin.referenceHistogram(ref, renderer: renderer, bins: c.lumaHistogram?.count ?? 64)
            c.cameraReferenceHistogramFine = CameraMatchPlugin.referenceHistogram(ref, renderer: renderer, bins: CameraMatchPlugin.fineBins)
        }
        let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
        return Analysis(context: c, defaults: lin.recipe.defaults, support: lin.recipe.support,
                        seconds: Date().timeIntervalSince(t0), decoderVersion: decoderVersion, plugins: plugins.defaultEnabled,
                        sourceFile: url.lastPathComponent, sourceBytes: bytes, personMask: mask, skyMask: sky)
    }

    /// Calibration keys for a file: model identifier, DNG UniqueCameraModel, "Make Model".
    public func cameraKeys(_ url: URL) throws -> [String?] {
        let props = try decoder.info(url: url).properties
        let tiff = props[kCGImagePropertyTIFFDictionary as String] as? [String: Any]
        let dng = props[kCGImagePropertyDNGDictionary as String] as? [String: Any]
        let cam = [tiff?[kCGImagePropertyTIFFMake as String] as? String, tiff?[kCGImagePropertyTIFFModel as String] as? String]
            .compactMap { $0 }.joined(separator: " ")
        return CalibrationTable.candidates(uniqueCameraModel: dng?[kCGImagePropertyDNGUniqueCameraModel as String] as? String,
                                           camera: cam.isEmpty ? nil : cam)
    }

    /// Develop with fixed settings, or with `auto` (analysis + DecisionEngine + plugin rules on top of `settings`).
    public func develop(url: URL, settings: RenderSettings, auto: Bool, scaleFactor: Float, analysis: Analysis? = nil) throws -> Output {
        try finish(developBase(url: url, settings: settings, auto: auto, scaleFactor: scaleFactor, analysis: analysis))
    }

    /// Stage 1: decisions, decode, plugins.afterDecode. With `auto`, a given `analysis` is used when it still fits
    /// (`Analysis.staleReason`); otherwise the file is analysed again and the recipe says why.
    public func developBase(url: URL, settings: RenderSettings, auto: Bool, scaleFactor: Float, analysis: Analysis? = nil) throws -> Base {
        // `headroomRestoreEV` is output only (sign-off C1): only `headroom.decide` of this render may set it.
        var settings = settings
        settings.headroomRestoreEV = nil
        var st = settings
        var reasons: [String] = []
        var ctx: SceneContext?
        var personMask: CIImage?
        var skyMask: CIImage?
        let active = try plugins.active(for: settings)
        var developedFor: String?
        var ran = Set<String>()   // plugins that actually did something (recipe.plugins)
        if (settings.decodeHeadroomEV ?? 0) > 0, !active.contains(where: { $0.id == "headroom" }) {
            reasons.append("decodeHeadroomEV set but plugin headroom is off: ignored")   // sign-off C2: no pixel changes
        }
        if auto {
            var a: Analysis
            var reused = false
            if let given = analysis {
                let version = try decoder.pinnedVersion(url: url, requested: settings.decoderVersion)
                if let why = given.staleReason(url: url, decoderVersion: version, plugins: active.map(\.id)) {
                    a = try analyze(url: url, decoderVersion: settings.decoderVersion, cameraReference: settings.cameraReference)
                    reasons.append("stored analysis not used (\(why)): analysed again")
                } else {
                    a = given
                    reused = true
                    reasons.append(String(format: "stored analysis used (made in %.2fs)", given.seconds))
                }
            } else {
                a = try analyze(url: url, decoderVersion: settings.decoderVersion)
            }
            // Everything the caller set is kept; DecisionEngine only adds/overrides bounded decode values.
            var base = settings
            base.mode = .explicit
            let d = DecisionEngine.decide(context: a.context, defaults: a.defaults, support: a.support, base: base)
            st = d.settings
            reasons += d.reasons
            for p in active {
                let before = st
                let why = p.decide(context: a.context, defaults: a.defaults, settings: &st)
                if st != before { ran.insert(p.id) }
                if p.id == "filmDevelop", let n = st.stock, let prof = try st.resolvedStock()?.develop?.profile { developedFor = "\(n): \(prof)" }
                reasons += why.map { "[\(p.id)] " + $0 }
            }
            if !reused { reasons.append(String(format: "analysis %.2fs", a.seconds)) }
            ctx = a.context
            personMask = a.personMask
            skyMask = a.skyMask
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
        }, scene: ctx, decodeSceneLinear: {
            // Same file, colour (CCM, calibration exposure), white balance, NR and lens as this render, with Apple's
            // tone removed. Exposure from cameraMatch/decisions is left out: it compensates Apple's display tone.
            var b = decodedSettings
            b.mode = .sceneLinear
            b.exposure = nil; b.baselineExposure = nil; b.shadowBias = nil; b.boostAmount = nil; b.boostShadowAmount = nil
            b.localToneMapAmount = nil; b.extendedDynamicRangeAmount = nil; b.gamutMapping = nil
            b.toneMapSourceHeadroom = nil; b.highlightClarity = nil; b.highlightRecoveryLocal = nil
            return try dec.decode(url: url, settings: b, scaleFactor: scaleFactor).image
        })

        var image = out.image
        for p in active {
            let (img, why) = try p.afterDecode(image, settings: st, ctx: pctx)
            image = img
            if !why.isEmpty { ran.insert(p.id) }
            out.recipe.decisions += why.map { "[\(p.id)] " + $0 }
        }
        return Base(image: image, recipe: out.recipe, settings: st, context: ctx, personMask: personMask, skyMask: skyMask,
                    developedFor: developedFor, active: active, ran: ran, pluginContext: pctx)
    }

    /// A look with a sky hold (`FilmStock.skyHoldAmount` > 0). With the `skyMask` plugin and a mask decision from the
    /// analysis the hold acts only inside the sky mask: the look is rendered with and without the hold (two cached LUTs)
    /// and blended by the mask (CIBlendWithMask). Otherwise the hold stays colour-only, and the recipe says so.
    func skyGatedLook(stock: FilmStock, lut: CubeLUT, image: CIImage, strength: Float, base: Base,
                      decisions: inout [String], ran: inout Set<String>) throws -> CIImage {
        func colourOnly(_ why: String) throws -> CIImage {
            decisions.append((base.active.contains { $0.id == "skyMask" } ? "[skyMask] " : "") + "sky mask unavailable (\(why)): colour-only sky hold")
            return try renderer.applyLook(lut, to: image, intensity: strength, colorSpace: stock.lookColorSpace)
        }
        guard base.active.contains(where: { $0.id == "skyMask" }) else { return try colourOnly("plugin skyMask off") }
        guard let ctx = base.context, ctx.skyMaskVersion != nil else { return try colourOnly("render not analysed, or analysis without sky mask") }
        guard let coverage = ctx.skyFraction else { return try colourOnly(ctx.skyGate ?? "no decision") }
        guard let unheld = stock.lutWithoutSkyHold(size: lut.size) else { return try colourOnly("look has no unheld variant") }
        ran.insert("skyMask")
        let tag = String(format: "sky hold %.2f of %@", stock.skyHoldAmount, stock.name)
        guard coverage >= SkyMask.minCoverage, let mask = base.skyMask else {
            decisions.append("[skyMask] \(tag) switched off: no sky in the frame (\(ctx.skyGate ?? "coverage below minimum")); non-sky pixels are not held (colour-only would have held every bright blue pixel)")
            return try renderer.applyLook(unheld, to: image, intensity: strength, colorSpace: stock.lookColorSpace)
        }
        let held = try renderer.applyLook(lut, to: image, intensity: strength, colorSpace: stock.lookColorSpace)
        let plain = try renderer.applyLook(unheld, to: image, intensity: strength, colorSpace: stock.lookColorSpace)
        decisions.append(String(format: "[skyMask] sky mask v%d: coverage %.1f%% (%@); %@ applied only inside the mask (CIBlendWithMask of the look with and without the hold)",
                                SkyMask.version, coverage * 100, ctx.skyGate ?? "", tag))
        return renderer.blend(held, over: plain, mask: mask)
    }

    /// Stage 2: look (stock supplies look, intensity and finish unless set explicitly) → skin protection → finish
    /// → plugins.afterFinish. Reads the look fields of `base.settings`.
    public func finish(_ base: Base) throws -> Output {
        let st = base.settings
        var out = base
        out.recipe.settings = st
        var ran = base.ran
        var image = base.image
        let stock = try st.resolvedStock()
        let beforeLook = image
        if let args = st.lookArguments, let look = st.stock {
            out.recipe.decisions.append("look=\(look) args=\(args.compactJSON())")
        }
        if base.active.contains(where: { $0.id == "filmDevelop" }) {
            let now = stock.flatMap { s in s.develop.map { "\(st.stock ?? s.name): \($0.profile)" } }
            if now != base.developedFor {
                out.recipe.decisions.append("[filmDevelop] base developed for \(base.developedFor ?? "no develop profile"), finished as \(now ?? "no develop profile") (decode is not redone)")
            }
        }
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
        if let declared = try renderer.resolveLookDeclared(st.look) {
            let lut = declared.lut
            if let n = declared.note { out.recipe.decisions.append(n) }
            image = try renderer.applyLook(lut, to: image, intensity: intensity(st.lookIntensity, lut), colorSpace: declared.space); appliedLUT = lut
        } else if let stock {
            let lut = stock.lut()
            let strength = intensity(stock.lookIntensity, lut)
            var pluginLook: (CIImage, [String])?
            var lookPlugin: String?
            if stock.lookInput != .display {
                for p in base.active {
                    if let r = try p.look(stock: stock, settings: st, ctx: base.pluginContext) { pluginLook = r; lookPlugin = p.id; break }
                }
            }
            if let (looked, why) = pluginLook, let id = lookPlugin {
                image = renderer.dissolve(from: image, to: looked, amount: strength)
                ran.insert(id)
                out.recipe.decisions += why.map { "[\(id)] " + $0 }
            } else {
                if case .log(let c) = stock.lookInput {
                    out.recipe.decisions.append("\(stock.name) is a \(c.rawValue) look but no plugin applied it (logLook off): LUT applied to the display base")
                }
                if stock.lookInput == .display, stock.skyHoldAmount > 0 {
                    image = try skyGatedLook(stock: stock, lut: lut, image: image, strength: strength, base: base,
                                             decisions: &out.recipe.decisions, ran: &ran)
                } else {
                    image = try renderer.applyLook(lut, to: image, intensity: strength, colorSpace: stock.lookColorSpace)
                }
            }
            appliedLUT = lut
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
            if let personMask = base.personMask {
                image = renderer.protectSkin(looked: image, base: beforeLook, mask: personMask, strength: s)
                out.recipe.decisions.append(String(format: "skin protection %.2f through the Vision person mask (CIBlendWithMask)", s))
            } else {
                out.recipe.decisions.append("skin protection requested but no person mask (Vision unavailable or not analysed)")
            }
        }
        let finish = st.finish ?? stock?.finish
        var finishCtx = base.pluginContext
        finishCtx.personMask = base.personMask   // lightLeak holds the leak back on people (spec: x personFactor)
        // Exposure-stage plugins (light leak) before grain / halation, so the grain sits on top as on film.
        for p in base.active {
            let (img, why) = try p.beforeGrain(image, settings: st, finish: finish, ctx: finishCtx)
            image = img
            if !why.isEmpty { ran.insert(p.id) }
            out.recipe.decisions += why.map { "[\(p.id)] " + $0 }
        }
        if let finish, finish.grainAmount > 0 || finish.halationAmount > 0 {
            image = FilmFinisher.apply(image, finish)
            out.recipe.decisions.append(String(format: "film finish%@: grain %.2f @ %.3f%% short edge (seed %u), halation %.2f (Y>%.2f, r %.2f%%)",
                                               stock.map { " (\($0.name))" } ?? "", finish.grainAmount, finish.grainSize, finish.grainSeed,
                                               finish.halationAmount, finish.halationThreshold, finish.halationRadius))
        }
        for p in base.active {
            let (img, why) = try p.afterFinish(image, settings: st, finish: finish, ctx: finishCtx)
            image = img
            if !why.isEmpty { ran.insert(p.id) }
            out.recipe.decisions += why.map { "[\(p.id)] " + $0 }
        }
        out.recipe.plugins = base.active.map(\.id).filter { ran.contains($0) }
        return Output(image: image, recipe: out.recipe, context: base.context)
    }
}

/// Extra: sky mask for the look's sky hold. Analysis (Developer.analyze) makes a heuristic mask, gated by the Vision
/// sky / landscape labels, and stores it as `sky-mask.png`; `Developer.finish` then applies a stock's `skyHold` only
/// inside the mask (the look rendered with and without the hold, blended by the mask). Unplugged, or without a mask
/// decision, the hold stays colour-only (`Preset26.skyWeight`) and the recipe says so. The work lives in Developer
/// (analysis and finish), this type is the registry entry that switches it on.
public struct SkyMaskPlugin: DevelopPlugin {
    public let id = "skyMask"
    public let summary = "sky hold only inside a heuristic sky mask (top-connected, smooth, bright blue / cloud) gated by Vision labels"
    public init() {}
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
