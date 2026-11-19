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
///            With `RenderSettings.outputCrop` (pipeline v2 stage 4): light leak → halation → afterFinish plugins that
///            are not `runsAfterCrop` (vignette) on the full frame → crop → qualityGuard (ungrained) → grain once on the cropped master (cell fixed in output px).
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
    /// Pipeline v2 stage 2 (fixed stock render), run by `finish` only with `exposureModel == .v2Normalizer`.
    /// Default = the skeleton pass-through (pixels unchanged). Set once in `init` (a `let`, so no develop can see it change).
    public let stockRenderer: any StockRenderer

    public init(renderer: Renderer = Renderer(), plugins: PluginRegistry = .standard, calibration: CalibrationTable = .empty,
                stockRenderer: any StockRenderer = PassThroughStockRenderer()) {
        self.renderer = renderer; self.plugins = plugins; self.calibration = calibration; self.stockRenderer = stockRenderer
    }

    /// Scene analysis of one file. Codable so it can be made at capture time and stored next to the DNG
    /// (`write(to:)` / `read(from:)`: JSON + the person mask as PNG); `develop` then uses it instead of analysing again,
    /// unless `staleReason` says it no longer fits the render.
    public struct Analysis: Codable, @unchecked Sendable {
        /// Bumped when what an analysis measures changes; an older stored analysis is re-made.
        public static let currentSchema = 5   // 5: displayClippedFraction on the camera HEIC (old value -> appleDecodeClippedFraction), ev100 + fNumber; 4: sky mask
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
        /// v2 only: the stage-1 output at the measuring size (`CameraMatchPlugin.histogramLongEdge`): the stock-independent
        /// decode with the display gain applied. Same for every stock; nil in legacy or when the normalizer did not run.
        var stage1Image: CIImage? = nil
    }

    /// Long edge of the v2 highlight probe decodes.
    static let probeLongEdge = 512
    /// Hard clip in the restored stage-1 image: a channel that encodes (8-bit, display-encoded) to `code` or above,
    /// i.e. >= (code - 0.5)/255 encoded. `SceneNormalizer.Parameters.clipTopCode8bit` (255 = top code only).
    static func hardClipLinear(code: Int) -> Float { Float(ColorMath.decodeTransfer((Double(code) - 0.5) / 255)) }
    static func inducedClipMeasure(code: Int) -> String {
        String(format: "induced clip: master (scene-linear stage 0) max channel < %.2f and restored stage-1 any channel at 8-bit code >= %d (>= %.1f/255 encoded), 1024 px; no specular/sun/window exclusion (no mask)",
               SceneContext.clipLevel, code, Double(code) - 0.5)
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
        c.appleDecodeClippedFraction = SceneContext.clippedFraction(try renderer.linearImage(disp.image))
        c.fNumber = try? fNumber(url)
        c.ev100 = SceneNormalizer.ev100(fNumber: c.fNumber, exposureTime: c.exposureTime, iso: c.iso)
        c.ev100Version = c.ev100 == nil ? nil : SceneContext.ev100FormulaVersion
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
            c.displayClippedFraction = c.cameraReferenceHistogramFine.flatMap { SceneContext.histogramFraction($0, atOrAboveLinear: SceneContext.clipLevel) }
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

    /// Stage-0 calibration key of a file: model candidates (`cameraKeys`), EXIF LensModel, RAW format from the DNG
    /// PhotometricInterpretation. Read from the decoder's cached file facts (no extra filter).
    public func calibrationKey(_ url: URL) throws -> CalibrationKey {
        let props = try decoder.info(url: url).properties
        let tiff = props[kCGImagePropertyTIFFDictionary as String] as? [String: Any]
        let exif = props[kCGImagePropertyExifDictionary as String] as? [String: Any]
        let aux = props[kCGImagePropertyExifAuxDictionary as String] as? [String: Any]
        let lens = (exif?[kCGImagePropertyExifLensModel as String] as? String) ?? (aux?[kCGImagePropertyExifAuxLensModel as String] as? String)
        let pi = (tiff?[kCGImagePropertyTIFFPhotometricInterpretation as String] as? NSNumber)?.intValue
        return CalibrationKey(models: try cameraKeys(url), lens: lens, rawFormat: CalibrationKey.RawFormat(photometricInterpretation: pi))
    }

    /// Develop with fixed settings, or with `auto` (analysis + DecisionEngine + plugin rules on top of `settings`).
    public func develop(url: URL, settings: RenderSettings, auto: Bool, scaleFactor: Float, analysis: Analysis? = nil) throws -> Output {
        try finish(developBase(url: url, settings: settings, auto: auto, scaleFactor: scaleFactor, analysis: analysis))
    }

    /// Settings with the `qualityGuard` plugin switched on (added to the explicit list, or to the developer's default set).
    public func guardEnabled(_ settings: RenderSettings) -> RenderSettings {
        var s = settings
        let ids = settings.plugins ?? plugins.defaultEnabled
        if !ids.contains("qualityGuard") { s.plugins = ids + ["qualityGuard"] }
        return s
    }

    /// Preview -> final in one call, so a host does not hand-roll it. The guard MEASURES on a small preview
    /// (`previewScaleFactor`, default 0.25; the guard itself measures on 384 px renders of it) and the full-resolution
    /// final reuses that strength through `RenderSettings.qualityGuardStrength`: the final makes no measuring render
    /// (`recipe.qualityGuardStrength` is the same value, `QualityGuardReport.measures` = 0), and a strength of 1 is a
    /// no-op. If `scaleFactor <= previewScaleFactor` the render itself is already small, so it develops once and
    /// measures itself. `settings.qualityGuardStrength` set by the caller skips the preview (it is the strength).
    /// Returns the final output; `output.recipe.qualityGuardStrength` is the chosen strength (1 = passed untouched).
    public func developGuarded(url: URL, settings: RenderSettings, auto: Bool, scaleFactor: Float,
                               previewScaleFactor: Float = 0.25, analysis: Analysis? = nil) throws -> Output {
        var s = guardEnabled(settings)
        if s.qualityGuardStrength != nil || scaleFactor <= previewScaleFactor {
            return try develop(url: url, settings: s, auto: auto, scaleFactor: scaleFactor, analysis: analysis)
        }
        let strength = try previewGuardStrength(url: url, settings: settings, auto: auto, previewScaleFactor: previewScaleFactor, analysis: analysis)
        s.qualityGuardStrength = strength
        return try develop(url: url, settings: s, auto: auto, scaleFactor: scaleFactor, analysis: analysis)
    }

    /// Step 1 of preview -> final when the host wants the two steps itself: develop at `previewScaleFactor` with the guard
    /// and return the strength it chose (0.5...1, 1 = passed untouched). Step 2: develop the final with
    /// `settings.qualityGuardStrength = strength` and the guard enabled (`guardEnabled`); that final does not measure.
    public func previewGuardStrength(url: URL, settings: RenderSettings, auto: Bool, previewScaleFactor: Float = 0.25,
                                     analysis: Analysis? = nil) throws -> Float {
        var s = guardEnabled(settings)
        s.qualityGuardStrength = nil
        // Measured only, never shown: no grain (RSP 0.6.1). On the crop path the guard measures before grain, so the strength
        // is the same as with grain; without a crop grain sits before the guard and is kept, so the strength does not move.
        let base = try developBase(url: url, settings: s, auto: auto, scaleFactor: previewScaleFactor, analysis: analysis)
        return try finish(base, grain: false).recipe.qualityGuardStrength ?? 1
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
        let v2 = settings.resolvedExposureModel == .v2Normalizer
        var active = try plugins.active(for: settings)
        // v2 (User 2026-11-18): highlightRecovery is off for every stock; forced here, whatever the caller's plugin list.
        let hrForcedOff = v2 && active.contains { $0.id == "highlightRecovery" }
        if v2 { active.removeAll { $0.id == "highlightRecovery" } }
        var developedFor: String?
        var ran = Set<String>()   // plugins that actually did something (recipe.plugins)
        if !v2, (settings.decodeHeadroomEV ?? 0) > 0, !active.contains(where: { $0.id == "headroom" }) {
            reasons.append("decodeHeadroomEV set but plugin headroom is off: ignored")   // sign-off C2: no pixel changes
        }
        // Pipeline v2 stage 1: the caller's exposure (a stock's bias), decode headroom and cameraMatch strength never set
        // the exposure; the scene normalizer below does (auto), or the decode stays at Apple's exposure (not auto).
        var normalizer: ExposureNormalizerRecord?
        // v2 stage 1: decode settings with no stock-dependent step (DecisionEngine only; no plugin decide, no HR EDR fields),
        // used for the highlight probes and for the image the display gain is solved on (review M1, 2026-11-17).
        var stage1Settings: RenderSettings?
        var stage1Image: CIImage?
        let calKey = try calibrationKey(url)
        if v2 {
            var r = ExposureNormalizerRecord(parameters: settings.sceneNormalizer ?? .provisional)
            r.ignoredCallerExposureEV = settings.exposure
            r.ignoredDecodeHeadroomEV = settings.decodeHeadroomEV
            r.ignoredCameraMatchStrength = settings.cameraMatchStrength
            r.highlightRecoveryForcedOff = hrForcedOff
            normalizer = r
            st.exposure = nil
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
            if v2 { base.exposure = nil }
            base.mode = .explicit
            let d = DecisionEngine.decide(context: a.context, defaults: a.defaults, support: a.support, base: base)
            st = d.settings
            reasons += d.reasons
            if v2 {
                var s1 = d.settings
                s1.exposure = nil; s1.headroomRestoreEV = nil
                s1.extendedDynamicRangeAmount = nil; s1.toneMapSourceHeadroom = nil; s1.highlightClarity = nil; s1.highlightRecoveryLocal = nil
                s1.decoderVersion = try decoder.pinnedVersion(url: url, requested: settings.decoderVersion)
                _ = resolveColorSource(&s1, key: calKey)
                stage1Settings = s1
            }
            for p in active {
                let before = st
                let why = p.decide(context: a.context, defaults: a.defaults, settings: &st)
                if st != before { ran.insert(p.id) }
                if p.id == "filmDevelop", let n = st.stock, let prof = try st.resolvedStock()?.develop?.profile { developedFor = "\(n): \(prof)" }
                reasons += why.map { "[\(p.id)] " + $0 }
            }
            if !reused { reasons.append(String(format: "analysis %.2fs", a.seconds)) }
            if v2, var r = normalizer, let s1 = stage1Settings {
                // Stage 1 decision (pure, from the analysis only): the same for every stock, no HEIC input.
                let inputs = SceneNormalizer.Inputs(context: a.context, baselineExposureEV: Double(a.defaults.baselineExposure),
                                                    fNumber: try? fNumber(url))
                // Highlight probes: SDR decodes with the stage-1 settings (same colour source, WB, NR, sharpening and local tone
                // map as the stage-1 image; no stock-dependent step) + exposure, at 512 px: the cut is the same for every stock
                // and for preview and final. One autoreleasepool per probe (review M3).
                let probeScale = try decoder.scaleFactor(url: url, longEdge: Self.probeLongEdge)
                let plan = try SceneNormalizer.withHighlightCut(SceneNormalizer.decide(inputs, r.parameters), r.parameters,
                                                                sensorClippedFraction: a.context.clippedFraction) { ev in
                    try autoreleasepool {
                        var ps = s1
                        ps.exposure = Float(ev)
                        return SceneContext.clippedFraction(try renderer.linearImage(try decoder.decode(url: url, settings: ps, scaleFactor: probeScale).image))
                    }
                }
                var s1Exposed = s1
                s1Exposed.exposure = Float(plan.decodeExposureEV)
                stage1Settings = s1Exposed
                r.stage1Decode = ExposureNormalizerRecord.Stage1Decode(
                    decoderVersion: s1.decoderVersion ?? "", anchorLocalToneMapAmount: a.defaults.localToneMapAmount,
                    localToneMapAmount: s1.localToneMapAmount ?? a.defaults.localToneMapAmount,
                    probeLongEdge: Self.probeLongEdge, measureLongEdge: Int(CameraMatchPlugin.histogramLongEdge))
                st.exposure = Float(plan.decodeExposureEV)
                st.headroomRestoreEV = nil
                r.inputs = inputs
                r.plan = plan
                normalizer = r
                reasons.append(String(format: "[normalizer] v2 stage 1: anchor L* %@ (Apple default RAW median) -> target %.1f (night %.2f), global %+.2f EV (strength %.2f), highlight cut %.2f EV (%ld probes) -> decode exposure %.2f%@",
                                      plan.anchorL.map { String(format: "%.1f", $0) } ?? "n/a", plan.targetL, plan.nightWeight, plan.globalEV,
                                      r.parameters.strength, plan.highlightCutEV, plan.highlightProbes.count, plan.decodeExposureEV,
                                      plan.notes.isEmpty ? "" : "; " + plan.notes.joined(separator: "; ")))
            }
            ctx = a.context
            personMask = a.personMask
            skyMask = a.skyMask
        }

        // Stage 0 colour source (pipeline v2): DNG metadata by default; an optional custom calibration (CCM + exposure
        // offset inside linearSpaceFilter, scene-linear) only on an exact model + lens + RAW format match. Every path
        // records its source and, when custom is skipped, why. Empty table = no change to the decode (0.3.1 pixels).
        let colorSource = resolveColorSource(&st, key: calKey)

        var out = try decoder.decode(url: url, settings: st, scaleFactor: scaleFactor, decisions: reasons)
        out.recipe.pluginsEnabled = active.map(\.id)
        out.recipe.colorSource = colorSource
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
        if v2, auto == false, var r = normalizer {
            r.skipped = "render without auto (no analysis): decode at Apple's exposure, no normalizer"
            normalizer = r
        }
        // v2: the normalizer's display restore runs right after highlightRecovery (where the legacy headroom restore ran).
        var pending = v2 && normalizer?.plan != nil
        for p in active {
            if pending, p.id != "highlightRecovery" {
                image = try deliverNormalizer(image, url: url, stage1: stage1Settings!, record: &normalizer!, stage1Image: &stage1Image,
                                              personMask: personMask, scene: ctx, settings: st, decisions: &out.recipe.decisions)
                pending = false
            }
            let (img, why) = try p.afterDecode(image, settings: st, ctx: pctx)
            image = img
            if !why.isEmpty { ran.insert(p.id) }
            out.recipe.decisions += why.map { "[\(p.id)] " + $0 }
        }
        if pending {
            image = try deliverNormalizer(image, url: url, stage1: stage1Settings!, record: &normalizer!, stage1Image: &stage1Image,
                                          personMask: personMask, scene: ctx, settings: st, decisions: &out.recipe.decisions)
        }
        out.recipe.exposureNormalizer = normalizer
        var based = Base(image: image, recipe: out.recipe, settings: st, context: ctx, personMask: personMask, skyMask: skyMask,
                         developedFor: developedFor, active: active, ran: ran, pluginContext: pctx)
        based.stage1Image = stage1Image
        return based
    }

    /// Decode fields (RenderSettings JSON keys) whose value differs between the v2 stage-1 decode and the delivered decode,
    /// `exposure` excluded (the same on both). Recorded so a recipe says what the stage-1 measurement did not see.
    static func decodeFieldsDiffering(_ a: RenderSettings, _ b: RenderSettings) -> [String] {
        func dict(_ s: RenderSettings) -> [String: Any] {
            (try? JSONSerialization.jsonObject(with: Data(s.compactJSON().utf8))) as? [String: Any] ?? [:]
        }
        let x = dict(a), y = dict(b)
        // exposure: the same on both; plugins: not a decode field; decoderVersion: stage 1 pins it explicitly, the delivered
        // decode resolves the same pin from nil (recorded in `Stage1Decode.decoderVersion`).
        let ignored: Set<String> = ["exposure", "plugins", "decoderVersion"]
        return Set(x.keys).union(y.keys).subtracting(ignored).filter { k in
            switch (x[k], y[k]) {
            case (nil, nil): return false
            case (let u?, let v?): return !(u as AnyObject).isEqual(v)
            default: return true
            }
        }.sorted()
    }

    /// Stage 0 colour source for `st` (fills `ccm` / `linearExposureEV` from the table on an exact key match).
    func resolveColorSource(_ st: inout RenderSettings, key calKey: CalibrationKey) -> ColorSourceRecord {
        if st.mode == .appleDefault {
            return .dngBaseline(calKey, .appleDefaultMode, "appleDefault reference decode: no calibration")
        } else if st.useCalibration == false {
            return .dngBaseline(calKey, .calibrationDisabled, "useCalibration = false")
        } else if st.ccm != nil {
            return .dngBaseline(calKey, .explicitCCM, "caller ccm on top of the DNG matrices; table not read")
        } else if st.linearExposureEV != nil {
            return .dngBaseline(calKey, .explicitLinearExposure, "caller linearExposureEV; table not read")
        }
        switch calibration.lookup(calKey) {
        case .found(let entry):
            st.ccm = entry.ccm
            st.linearExposureEV = entry.exposureOffsetEV
            return .custom(calKey, entry)
        case .missing(let why, let detail):
            return .dngBaseline(calKey, why, detail)
        }
    }

    /// EXIF FNumber of the file (for EV100), nil when absent.
    public func fNumber(_ url: URL) throws -> Double? {
        let props = try decoder.info(url: url).properties
        let exif = props[kCGImagePropertyExifDictionary as String] as? [String: Any]
        return (exif?[kCGImagePropertyExifFNumber as String] as? NSNumber)?.doubleValue
    }

    /// `image` downscaled (long edge `longEdge`) and rendered once into a float bitmap, so repeated measurements do not
    /// decode the RAW again.
    func materialized(_ image: CIImage, longEdge: CGFloat) -> CIImage? {
        let small = CameraMatchPlugin.small(image, longEdge: longEdge)
        let e = small.extent.integral
        let w = Int(e.width), h = Int(e.height)
        guard w > 0, h > 0 else { return nil }
        var data = Data(count: w * h * 16)
        data.withUnsafeMutableBytes { renderer.context.render(small, toBitmap: $0.baseAddress!, rowBytes: w * 16, bounds: e, format: .RGBAf, colorSpace: Renderer.linearP3) }
        return CIImage(bitmapData: data, bytesPerRow: w * 16, size: CGSize(width: w, height: h), format: .RGBAf, colorSpace: Renderer.linearP3)
    }

    /// Median display-linear luminance, same measure as the analysis' Apple render (`lumaHistogram`, 64 bins).
    func medianY(_ image: CIImage) -> Double? {
        renderer.lumaHistogram(image).map { ColorMath.decodeTransfer(ToneMatch.quantile($0, 0.5)) }
    }

    /// Median L* of skin-hue pixels inside the person mask (mask >= 0.5, hue 25-75°, C* 10-45, L* 20-90: the golden-set
    /// skin rule), on a 384 px render. nil = fewer than 100 such pixels.
    func skinMedianL(_ image: CIImage, mask: CIImage) throws -> (Double, Int)? {
        let img = CameraMatchPlugin.small(image, longEdge: 384)
        let e = img.extent, m = mask.extent
        guard m.width > 0, m.height > 0 else { return nil }
        let scaled = mask.transformed(by: CGAffineTransform(translationX: -m.minX, y: -m.minY))
            .transformed(by: CGAffineTransform(scaleX: e.width / m.width, y: e.height / m.height))
            .transformed(by: CGAffineTransform(translationX: e.minX, y: e.minY)).cropped(to: e)
        let px = try renderer.linearImage(img), mk = try renderer.linearImage(scaled)
        var ls: [Double] = []
        for i in 0..<min(px.pixelCount, mk.pixelCount) where mk.pixels[i * 3] >= 0.5 {
            let lab = ColorMath.lab(r: Double(max(px.pixels[i * 3], 0)), g: Double(max(px.pixels[i * 3 + 1], 0)), b: Double(max(px.pixels[i * 3 + 2], 0)))
            let c = (lab.a * lab.a + lab.b * lab.b).squareRoot()
            var hue = atan2(lab.b, lab.a) * 180 / .pi
            if hue < 0 { hue += 360 }
            if (25...75).contains(hue), (10...45).contains(c), (20...90).contains(lab.l) { ls.append(lab.l) }
        }
        guard ls.count >= 100 else { return nil }
        ls.sort()
        return (ls[ls.count / 2], ls.count)
    }

    /// Pipeline v2 stage 1, after the decode: solve the display restore (max-channel shoulder, `HeadroomRestore.curveV2`) so the
    /// median lands on the plan's target (Apple's tone curve is not linear, so a fixed +Δ restore under-delivers:
    /// ROLL_AUDIT 2026-11-17), then the skin floor, then cap the gain by the highlight rule on the restored image, then record
    /// the Apple HEIC ΔEV as a diagnostic. Everything is measured on the stage-1 image: a separate decode with `stage1`
    /// (no stock-dependent step, review M1) at `CameraMatchPlugin.histogramLongEdge`, independent of the render's scale.
    /// The gain is then applied to `image` (the delivered decode, after highlightRecovery when a stock keeps it).
    /// Deterministic: same RAW + same analysis = same gain for every stock. The HEIC is read only after the pixels are fixed.
    func deliverNormalizer(_ image: CIImage, url: URL, stage1: RenderSettings, record r: inout ExposureNormalizerRecord,
                           stage1Image: inout CIImage?, personMask: CIImage?, scene: SceneContext?,
                           settings st: RenderSettings, decisions: inout [String]) throws -> CIImage {
        r.stage1Decode?.differsFromDelivered = Self.decodeFieldsDiffering(stage1, st)
        let sc = try decoder.scaleFactor(url: url, longEdge: Int(CameraMatchPlugin.histogramLongEdge))
        let measured: CIImage? = try autoreleasepool {
            materialized(try decoder.decode(url: url, settings: stage1, scaleFactor: sc).image, longEdge: CameraMatchPlugin.histogramLongEdge)
        }
        guard let plan = r.plan, let target = plan.targetMedianY, let probe = measured, let m0 = medianY(probe) else {
            // Without a measurable target only the highlight cut is given back (fixed, as the legacy split would).
            guard let cut = r.plan?.highlightCutEV, cut > 0 else {
                r.notes.append("no target or no measurable decode: no display restore")
                return image
            }
            let q = HeadroomRestore.quantised(Float(cut))
            r.restoreEV = Double(q)
            r.notes.append(String(format: "no target or no measurable decode: fixed restore +%.2f EV (the highlight cut only)", q))
            return try renderer.applyLook(HeadroomRestore.lutV2(gainEV: q), to: image, intensity: 1)
        }
        let p0 = r.parameters
        r.decodeMedianL = SceneNormalizer.lstar(m0)
        func restored(_ g: Double) throws -> CIImage {
            let q = HeadroomRestore.quantised(Float(g))
            return q != 0 ? try renderer.applyLook(HeadroomRestore.lutV2(gainEV: q), to: probe, intensity: 1) : probe
        }
        // Stage-0 master + its recoverable mask: decoded once (the first highlight rule), reused by later passes.
        var masterCache: (master: LinearImage, recoverable: [Bool])?
        func masterRecoverable() throws -> (master: LinearImage, recoverable: [Bool]) {
            if let c = masterCache { return c }
            let master: LinearImage? = try autoreleasepool {
                var b = stage1
                b.mode = .sceneLinear
                b.exposure = nil; b.baselineExposure = nil; b.shadowBias = nil; b.boostAmount = nil; b.boostShadowAmount = nil
                b.localToneMapAmount = nil; b.extendedDynamicRangeAmount = nil; b.gamutMapping = nil
                b.toneMapSourceHeadroom = nil; b.highlightClarity = nil; b.highlightRecoveryLocal = nil
                return try materialized(try decoder.decode(url: url, settings: b, scaleFactor: sc).image,
                                        longEdge: CameraMatchPlugin.histogramLongEdge).map { try renderer.linearImage($0) }
            }
            guard let master, let probeLin = try? renderer.linearImage(probe), probeLin.width == master.width, probeLin.height == master.height else {
                throw RawCoreError.invalidSettings("v2 normalizer: stage-0 master and stage-1 image do not align (cannot measure clipping)")
            }
            let recoverable: [Bool] = (0..<master.pixelCount).map {
                max(master.pixels[$0 * 3], master.pixels[$0 * 3 + 1], master.pixels[$0 * 3 + 2]) < Float(SceneContext.clipLevel)
            }
            masterCache = (master, recoverable)
            return (master, recoverable)
        }
        // One stage-1 pass: median solve with `p`'s bounds, skin floor, then (when `rule`) the highlight rule at `topCode`.
        // Writes its record fields into `r`. With the bright-scene blend off this is the only pass (0.4.0 behaviour).
        func pass(_ p: SceneNormalizer.Parameters, topCode: Int, rule: Bool, _ r: inout ExposureNormalizerRecord) throws
            -> (g: Double, m: Double, n: Int, want: Double, delivered: Double, limit: Double, miss: Double) {
        // Fixed-point iteration on the measured median (at most 4 measurements, stop within 0.02 EV).
        func solve(_ want: Double, from g0: Double) throws -> (Double, Double, Int) {
            var g = g0, m = m0, n = 0
            for _ in 0..<4 {
                let gq = Double(HeadroomRestore.quantised(Float(g)))
                m = try medianY(restored(gq)) ?? m
                n += 1
                if abs(log2(want / max(m, 1e-6))) < 0.02 { return (gq, m, n) }
                let next = SceneNormalizer.nextRestore(gq, measured: m, target: want, maxEV: p.maxRestoreEV, minEV: p.maxCutEV)
                if abs(next - gq) < 0.005 { return (gq, m, n) }
                g = next
            }
            return (Double(HeadroomRestore.quantised(Float(g))), try medianY(restored(g)) ?? m, n + 1)
        }
        var (g, m, n) = try solve(target, from: SceneNormalizer.nextRestore(0, measured: m0, target: target, maxEV: p.maxRestoreEV, minEV: p.maxCutEV))
        var want = target
        // Skin floor: lift only, x the smooth people score, bounded.
        let people = r.inputs?.people ?? 0
        if people > 0, let mask = personMask, let (skinL, count) = try skinMedianL(restored(g), mask: mask) {
            r.skinMedianL = skinL; r.skinPixels = count
            let deficit = log2(SceneNormalizer.luminance(lstar: p.skinFloorL) / SceneNormalizer.luminance(lstar: skinL))
            let lift = min(max(deficit, 0), p.maxSkinLiftEV) * people
            r.skinLiftEV = lift
            if lift >= 0.01 {
                want = target * pow(2, lift)
                (g, m, n) = try { let s = try solve(want, from: g + lift); return (s.0, s.1, n + s.2) }()
                r.skinMedianLAfter = try skinMedianL(restored(g), mask: mask)?.0
            }
        }
        guard rule else { return (g, m, n, want, 0, 0, log2(want / max(m, 1e-6))) }
        // Highlight rule on the stage-1 OUTPUT (review M2, contract clipping definition, User 2026-11-18): pipeline-induced
        // clip = share of pixels recoverable in the stage-0 master (scene-linear, max channel < `SceneContext.clipLevel`, the
        // sensor-clip level) but hard-clipped in the restored stage-1 image (any channel at the 8-bit top code). No
        // specular / sun / window exclusion (no such mask yet): those pixels count. The gain is capped so the induced clip
        // stays <= allowance (or <= what the decode already induces at gain 0, if that is higher). The gain only goes down
        // here; bisection on the 0.01 EV quantisation grid. What the median then misses is recorded (shortfallEV).
        let (master, recoverable) = try masterRecoverable()
        let hardClip = Self.hardClipLinear(code: topCode)
        r.stage1ClipMeasure = Self.inducedClipMeasure(code: topCode)
        r.masterClippedFraction = Double(recoverable.lazy.filter { !$0 }.count) / Double(max(master.pixelCount, 1))
        func clip(_ g: Double) throws -> Double {
            try autoreleasepool {
                let img = try renderer.linearImage(restored(g))
                var c = 0
                for i in 0..<min(img.pixelCount, recoverable.count) where recoverable[i]
                    && max(img.pixels[i * 3], img.pixels[i * 3 + 1], img.pixels[i * 3 + 2]) >= hardClip { c += 1 }
                return Double(c) / Double(max(img.pixelCount, 1))
            }
        }
        let c0 = try clip(0)
        let limit = max(p.highlightClipAllowance, c0)
        r.stage1ClipLimit = limit; r.stage1ClippedBeforeRestore = c0
        var delivered = c0
        if HeadroomRestore.quantised(Float(g)) > 0 {
            delivered = try clip(g)
            if delivered - limit > 1e-12 {
                let wanted = g, clipWanted = delivered
                var lo = 0.0, hi = g
                while true {
                    let mid = Double(HeadroomRestore.quantised(Float((lo + hi) / 2)))
                    if mid <= lo || mid >= hi { break }
                    n += 1
                    if try clip(mid) <= limit { lo = mid } else { hi = mid }
                }
                g = lo
                delivered = try clip(g)
                m = try medianY(restored(g)) ?? m
                n += 1
                r.medianRestoreEV = wanted
                r.notes.append(String(format: "highlight rule on the restored image: gain %+.2f -> %+.2f EV (induced clip %.2f%% at %+.2f, limit %.2f%% = max(allowance %.2f%%, at gain 0 %.2f%%))",
                                      wanted, g, clipWanted * 100, wanted, limit * 100, p.highlightClipAllowance * 100, c0 * 100))
                if let mask = personMask, r.skinMedianL != nil { r.skinMedianLAfter = try skinMedianL(restored(g), mask: mask)?.0 }
            }
        }
        r.stage1ClippedFraction = delivered
        let miss = log2(want / max(m, 1e-6))
        r.shortfallEV = miss
        if abs(miss) >= 0.05 {
            r.notes.append(String(format: "display gain %+.2f EV (bound -%.2f...+%.2f%@) leaves the median %+.2f EV from target", g, p.maxCutEV, p.maxRestoreEV,
                                  r.medianRestoreEV == nil ? "" : ", highlight rule", miss))
        }
        return (g, m, n, want, delivered, limit, miss)
        }
        let before = r
        var res = try pass(p0, topCode: p0.effectiveClipTopCode8bit, rule: true, &r)
        // Bright-scene blend (option C, PROVISIONAL; nil = off, nothing below runs). w from the EV100 of `inputs`.
        if let b = p0.brightSceneBlend {
            let ev = r.inputs?.ev100
            let w = b.weight(ev100: ev)
            var rec = ExposureNormalizerRecord.BrightSceneBlendRecord(ev100: ev, weight: w, applied: false,
                                                                      effectiveClipTopCode8bit: p0.effectiveClipTopCode8bit,
                                                                      effectiveMaxRestoreEV: p0.maxRestoreEV)
            if ev == nil { rec.notes.append("EV100 unknown (ISO, shutter or aperture missing): w = 0") }
            if w > 0 {
                let g254 = res.g
                var scratch = before
                var pw = p0; pw.maxRestoreEV = b.maxRestoreEV
                let wanted = try pass(pw, topCode: b.clipTopCode8bit, rule: false, &scratch)
                let bound = SceneNormalizer.Parameters.BrightSceneBlend.restoreBound(today: g254, wanted: wanted.g, weight: w)
                var pc = p0; pc.maxRestoreEV = bound
                var blended = before
                let out = try pass(pc, topCode: b.clipTopCode8bit, rule: true, &blended)
                rec.todayRestoreEV = g254; rec.wantedRestoreEV = wanted.g
                rec.blendedRestoreEV = out.g
                if SceneNormalizer.Parameters.BrightSceneBlend.keepsToday(blended: out.g, today: g254) {
                    // N1 (User 2026-11-19): never darker than the blend-off gain. The 255 limit max(allowance, clip at gain 0)
                    // can be stricter than the 254 one when the decode already clips at 254; then today's pass is kept as is
                    // (record, gain, pixels = blend off).
                    res.n += wanted.n + out.n
                    rec.clampedToToday = true
                    rec.notes.append(String(format: "blended gain %+.2f EV under code %d < today's %+.2f EV: today's pass kept (N1 clamp)", out.g, b.clipTopCode8bit, g254))
                } else {
                    r = blended
                    res = (out.g, out.m, res.n + wanted.n + out.n, out.want, out.delivered, out.limit, out.miss)
                    rec.applied = true
                    rec.clampedToToday = false
                    rec.effectiveClipTopCode8bit = b.clipTopCode8bit; rec.effectiveMaxRestoreEV = bound
                }
            }
            r.brightSceneBlend = rec
            decisions.append(String(format: "[normalizer] bright-scene blend (provisional): EV100 %@ -> w %.3f (ramp %.1f...%.1f), clip code %d, restore bound %.2f EV%@",
                                    ev.map { String(format: "%.2f", $0) } ?? "n/a", w, b.ev100None, b.ev100Full,
                                    rec.effectiveClipTopCode8bit, rec.effectiveMaxRestoreEV,
                                    rec.todayRestoreEV == nil ? "" : String(format: " (g254 %+.2f, wanted %+.2f, blended %+.2f%@)", rec.todayRestoreEV ?? 0,
                                                                            rec.wantedRestoreEV ?? 0, rec.blendedRestoreEV ?? 0,
                                                                            rec.clampedToToday == true ? ", clamped to today" : "")))
        }
        let (g, m, n, want, delivered, limit, miss) = res
        r.restoreEV = g; r.restoreIterations = n
        stage1Image = try restored(g)
        r.deliveredMedianL = SceneNormalizer.lstar(m)
        if let y0 = r.inputs?.appleDefaultMedianY, y0 > 1e-6 { r.decidedEV = log2(want / y0); r.deliveredEV = log2(max(m, 1e-6) / y0) }
        let out = HeadroomRestore.quantised(Float(g)) != 0 ? try renderer.applyLook(HeadroomRestore.lutV2(gainEV: Float(g)), to: image, intensity: 1) : image

        // Diagnostic only, after the pixels are fixed: Apple HEIC mid-tones vs this stage-1 output.
        let stored = scene?.cameraReferenceHistogram
        if let ours = try renderer.lumaHistogram(restored(g)) {
            if let theirs = stored, theirs.count == ours.count {
                r.appleDiagnosticDeltaEV = ToneMatch.exposureOffsetEV(candidate: ours, reference: theirs, range: -8...8)
                r.appleDiagnosticSource = "stored analysis histogram"
            } else if let path = st.cameraReference, let theirs = CameraMatchPlugin.referenceHistogram(path, renderer: renderer, bins: ours.count) {
                r.appleDiagnosticDeltaEV = ToneMatch.exposureOffsetEV(candidate: ours, reference: theirs, range: -8...8)
                r.appleDiagnosticSource = "HEIC file"
            }
        }
        decisions.append(String(format: "[normalizer] stage-1 median L* %.1f -> display gain %+.2f EV (%d measure%@) -> median L* %.1f (target %.1f, short %+.2f EV), induced clip %.2f%% (limit %.2f%%)%@%@",
                                r.decodeMedianL ?? 0, g, n, n == 1 ? "" : "s", r.deliveredMedianL ?? 0, SceneNormalizer.lstar(want), miss,
                                delivered * 100, limit * 100,
                                r.skinMedianL.map { String(format: ", skin L* %.1f lift %+.2f EV", $0, r.skinLiftEV ?? 0) } ?? "",
                                r.appleDiagnosticDeltaEV.map { String(format: "; Apple HEIC %+.2f EV (diagnostic only)", $0) } ?? ""))
        return out
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
        try finish(base, grain: true)
    }

    /// `grain: false` skips the crop-path grain (guard preview only, `previewGuardStrength`); the no-crop path keeps it.
    func finish(_ base: Base, grain: Bool) throws -> Output {
        let st = base.settings
        var out = base
        out.recipe.settings = st
        var ran = base.ran
        var image = base.image
        let stock = try st.resolvedStock()
        if st.resolvedExposureModel == .v2Normalizer {
            // Pipeline v2 stage 2, fixed stock render: stage-1 image + stock + stage-0 illuminant only (no scene label, no
            // exposure input). Before the look, so skin protection and qualityGuard compare against the stage-2 output.
            // TODO(stage 2): the stock LUT below still mixes stock identity (stage 2) and look (stage 3); split when the
            // stage-2 parameters exist.
            let illuminant = IlluminantMetadata(context: base.context)
            let r = try stockRenderer.render(image, stock: stock, illuminant: illuminant)
            image = r.image
            out.recipe.stockRender = StockRenderRecord(renderer: stockRenderer.id, stock: st.stock, illuminant: illuminant,
                                                       applied: r.applied, notes: r.notes)
        }
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
        finishCtx.lookBase = beforeLook            // qualityGuard compares the finished frame with the frame before the look
        let guardReport = base.active.contains(where: { $0.id == "qualityGuard" }) ? QualityGuardReport() : nil
        finishCtx.guardReport = guardReport
        // Exposure-stage plugins (light leak) before grain / halation, so the grain sits on top as on film.
        for p in base.active {
            let (img, why) = try p.beforeGrain(image, settings: st, finish: finish, ctx: finishCtx)
            image = img
            if !why.isEmpty { ran.insert(p.id) }
            out.recipe.decisions += why.map { "[\(p.id)] " + $0 }
        }
        func afterFinish(_ plugins: [any DevelopPlugin]) throws {
            for p in plugins {
                let (img, why) = try p.afterFinish(image, settings: st, finish: finish, ctx: finishCtx)
                image = img
                if !why.isEmpty { ran.insert(p.id) }
                out.recipe.decisions += why.map { "[\(p.id)] " + $0 }
            }
        }
        if let crop = st.outputCrop {
            // Pipeline v2 stage 4: halation and full-frame afterFinish plugins (vignette) → crop → plugins that run after
            // the crop (qualityGuard, on a cropped, ungrained base) → grain once on the cropped master (cell fixed in output px).
            let stockTag = stock.map { " (\($0.name))" } ?? ""
            if let finish, finish.halationAmount > 0 {
                image = FilmFinisher.applyHalation(image, finish)
                out.recipe.decisions.append(String(format: "film finish%@: halation %.2f (Y>%.2f, r %.2f%%) on the full frame",
                                                   stockTag, finish.halationAmount, finish.halationThreshold, finish.halationRadius))
            }
            try afterFinish(base.active.filter { !$0.runsAfterCrop })
            let full = image.extent
            let rect = FilmFinisher.pixelRect(crop, in: full)
            image = FilmFinisher.crop(image, to: rect)
            finishCtx.lookBase = finishCtx.lookBase.map { FilmFinisher.crop($0, to: rect) }
            out.recipe.decisions.append(String(format: "output crop %.4f,%.4f %.4fx%.4f (top-left) of %.0fx%.0f -> %.0fx%.0f px at %.0f,%.0f",
                                               crop.x, crop.y, crop.width, crop.height, full.width, full.height,
                                               rect.width, rect.height, rect.minX - full.minX, full.maxY - rect.maxY))
            try afterFinish(base.active.filter { $0.runsAfterCrop })   // qualityGuard measures the ungrained cropped frame
            if !grain, let finish, finish.resolvedGrain != nil {
                out.recipe.decisions.append("film finish\(stockTag): grain skipped (guard preview, measured only; seed \(finish.grainSeed))")
            } else if let finish, let g = finish.resolvedGrain {
                image = FilmFinisher.applyGrain(image, finish)
                out.recipe.decisions.append(String(format: "film finish%@: grain once on the cropped master, after the guard, cell %.2f px, sigma50 %.2f, chroma %.2f (seed %u)",
                                                   stockTag, g.cellPx, g.sigma50, g.chroma, finish.grainSeed))
            }
        } else {
            if let finish, finish.resolvedGrain != nil || finish.halationAmount > 0 {
                image = FilmFinisher.apply(image, finish)
                let g = finish.resolvedGrain
                out.recipe.decisions.append(String(format: "film finish%@: grain cell %.2f px, sigma50 %.2f, chroma %.2f (seed %u), halation %.2f (Y>%.2f, r %.2f%%)",
                                                   stock.map { " (\($0.name))" } ?? "", g?.cellPx ?? 0, g?.sigma50 ?? 0, g?.chroma ?? 0, finish.grainSeed,
                                                   finish.halationAmount, finish.halationThreshold, finish.halationRadius))
            }
            try afterFinish(base.active)
        }
        out.recipe.plugins = base.active.map(\.id).filter { ran.contains($0) }
        out.recipe.qualityGuardStrength = guardReport?.strength
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
