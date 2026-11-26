import Foundation

/// Everything that decides how a RAW file is developed. Codable so a render can be reproduced
/// from its recipe. `nil` means "use the decoder's per-file default" (recorded in the recipe).
public struct RenderSettings: Codable, Equatable, Sendable {
    public enum Mode: String, Codable, Sendable, CaseIterable {
        /// Apple's own CIRAWFilter decode with every parameter left at its per-file default.
        /// This is the reference ("RAW gốc" as Photos shows it).
        case appleDefault
        /// Pinned decoder; every parameter written explicitly (defaults read from the file, then overrides).
        case explicit
        /// Pinned decoder; Apple's rendering intent removed (WWDC21 10160): baseline exposure 0,
        /// shadow bias 0, boost 0, local tone map 0, gamut mapping off. For analysis and custom looks.
        case sceneLinear
    }

    public var mode: Mode
    /// Raw value of a `CIRAWDecoderVersion` (e.g. "8", "8.dng"). nil = newest supported for the file.
    public var decoderVersion: String?

    public var exposure: Float?
    public var baselineExposure: Float?
    public var shadowBias: Float?
    public var boostAmount: Float?
    public var boostShadowAmount: Float?
    public var localToneMapAmount: Float?
    public var sharpnessAmount: Float?
    public var contrastAmount: Float?
    public var detailAmount: Float?
    public var luminanceNoiseReductionAmount: Float?
    public var colorNoiseReductionAmount: Float?
    public var moireReductionAmount: Float?
    public var extendedDynamicRangeAmount: Float?
    public var lensCorrection: Bool?
    public var gamutMapping: Bool?
    public var neutralTemperature: Float?
    public var neutralTint: Float?

    /// Optional 3x3 row-major matrix applied in scene-linear camera-neutral space (CIRAWFilter
    /// linearSpaceFilter). Used for per-model colour calibration.
    public var ccm: [Float]?

    /// If set, the decoded image (normally an EDR decode) is tone-mapped from this headroom down to
    /// SDR white (Core Image CIToneMapHeadroom). Recovers highlights that Apple's curve clips.
    public var toneMapSourceHeadroom: Float?
    /// 0...1: large-radius unsharp mask (≈1.2 % of the long edge) blended in only where the image is bright,
    /// to give back local contrast that global highlight compression takes away. Applied after the tone map.
    public var highlightClarity: Float?
    /// With a tone map: true (default) blends the recovered render only where the SDR decode is near white;
    /// false applies the tone map to the whole frame (the 2026-11-07 behaviour, kept for comparison).
    public var highlightRecoveryLocal: Bool?

    /// Look: path to a .cube file, or a built-in look name (see `BuiltInLook`).
    public var look: String?
    /// 0...1 blend of the look over the base render.
    public var lookIntensity: Float
    /// Film stock (`FilmStock.named`: a listed stock, a roll stock id, or with `lookArguments` a supported look id): sets
    /// look, intensity and finish unless `look` / `finish` are given explicitly. Resolve it with `resolvedStock()`.
    public var stock: String?
    /// Layer-1 arguments merged onto the look named in `stock` (`FilmStock.resolve(look:arguments:)`). Needs `stock` to be
    /// a `SupportedLooks` id; cannot be combined with `finish` (the arguments set the finish).
    public var lookArguments: LookArguments?
    /// Explicit finishing (grain, halation, vignette); overrides the stock's finish.
    public var finish: FilmFinish?
    /// 0...1: how much of the look is held back on people (Vision person mask). nil/0 = off.
    public var skinProtection: Float?
    /// Exposure offset (EV) applied inside CIRAWFilter's linearSpaceFilter, i.e. scene-linear, together with the CCM.
    /// Normally filled from the per-model calibration table.
    public var linearExposureEV: Float?
    /// Use the per-model calibration table (CCM + exposure offset) when an entry exists. nil = yes.
    public var useCalibration: Bool?
    /// Plugins to run (ids from `PluginRegistry`). nil = the developer's default set, [] = none.
    public var plugins: [String]?
    /// Added to the look's intensity (stock or explicit look), clamped to 0...1. Set by DecisionEngine from the
    /// scene (dark, people, landscape), bounded -0.15...+0.10. The preset itself never changes per photo (one roll,
    /// one stock); 0 = lock the intensity exactly.
    public var lookIntensityOffset: Float?
    /// 0.5...1: strength of the finish found by `qualityGuard` on a preview; given, the guard applies it without
    /// measuring (preview and final use the same parameter). nil = the guard measures this render.
    public var qualityGuardStrength: Float?
    /// Path of the camera's own HEIC from the same shutter press (CaptureKit `apple.heic`). With the cameraMatch
    /// plugin, our exposure and tones are matched to it. Not a decode override by itself.
    public var cameraReference: String?
    /// 0...1 strength of the cameraMatch tone curve (nil = 1). The exposure offset is always applied in full.
    public var cameraMatchStrength: Float?
    /// Decode headroom (plugin `headroom`, RSP 0.3.0): decode this many stops lower than the render's exposure and restore
    /// them in display space with a max-channel shoulder (`HeadroomRestore`), so channels Apple's curve would clip keep
    /// their chroma (the sky). 0...1.5; nil or 0 = off, bit-identical. A decode parameter of the RAW file, not a look
    /// argument (sign-off D2). The caller states only the exposure bias in `exposure`; RSP splits it.
    public var decodeHeadroomEV: Float?
    /// OUTPUT ONLY (sign-off C1): the display restore gain in EV that `headroom.decide` chose (Δ + the positive part of the
    /// exposure bias). `Developer.developBase` clears it on entry, so a value the caller sets is ignored; the restore
    /// reads only this field, so a render without `auto` (no decide) never restores.
    public var headroomRestoreEV: Float?

    /// Roll position, for per-frame effects (plugin `lightLeak`). `rollID` is part of the seed; frame index is 1-based.
    /// nil index or count = the frame's place in the roll is unknown: no roll effect is drawn (and the recipe says so).
    public var rollID: String?
    public var rollFrameIndex: Int?
    public var rollFrameCount: Int?

    /// Pipeline v2 stage 4 (MoodRoll PIPELINE_V2_CONTRACT, coordinate rule): the host's framing crop, done INSIDE
    /// `Developer.finish`. Light leak, halation and vignette run on the full frame, then this crop, then grain sized on
    /// the CROPPED short edge (same seed, same size %), then `qualityGuard` (on the cropped frame and cropped base).
    /// The output starts at origin 0,0. nil = no crop: the 0.3.1 finish order and pixels, unchanged.
    public var outputCrop: OutputCrop?

    /// Pipeline v2 stage 1 (MoodRoll PIPELINE_V2_CONTRACT): which exposure model sets the scene exposure.
    /// - `legacy` (nil = legacy, the default): the 0.3.1 chain, unchanged pixels: caller `exposure` (the stock bias) →
    ///   `headroom` split of `decodeHeadroomEV` → `cameraMatch` HEIC exposure offset, shadow boost and tone curve.
    /// - `v2Normalizer`: `SceneNormalizer` decides one exposure from the analysis, the same for every stock. The caller's
    ///   `exposure` (stock bias), `decodeHeadroomEV` and `cameraMatchStrength` are ignored (recorded as ignored); the
    ///   camera HEIC is only a diagnostic ΔEV in `DecodeRecipe.exposureNormalizer`, it never changes a pixel. Needs `auto`.
    public enum ExposureModel: String, Codable, Sendable, CaseIterable {
        case legacy
        case v2Normalizer
    }
    public var exposureModel: ExposureModel?
    /// Parameters of the v2 normalizer (nil = `SceneNormalizer.Parameters.provisional`). Only read with `v2Normalizer`.
    /// For lab runs; every default is provisional until the User approves the numbers.
    public var sceneNormalizer: SceneNormalizer.Parameters?
    /// The user's exposure compensation (EV) at the press, recorded by the host. Read ONLY by the HEIC entry (stage 0-H), and
    /// only to record it: the bias is already inside the HEIC pixels, so nothing re-applies or cancels it. No RAW path reads it.
    /// nil = unknown (omitted from the JSON).
    public var userExposureBiasEV: Double?

    /// CALA M1-01: record the protection trace in `DecodeRecipe.lookAdaptation`. Record only: pixels are identical with it on or off.
    /// nil/false = off (the recipe gets no `lookAdaptation` key; nil is omitted from the settings JSON).
    public var traceLookAdaptation: Bool?

    /// The model in effect (nil = legacy).
    public var resolvedExposureModel: ExposureModel { exposureModel ?? .legacy }

    public init(mode: Mode = .appleDefault, decoderVersion: String? = nil, look: String? = nil, lookIntensity: Float = 1) {
        self.mode = mode
        self.decoderVersion = decoderVersion
        self.look = look
        self.lookIntensity = lookIntensity
    }

    public static let appleDefault = RenderSettings(mode: .appleDefault)
    public static let explicit = RenderSettings(mode: .explicit)
    public static let sceneLinear = RenderSettings(mode: .sceneLinear)

    public func validate() throws {
        if let ccm, ccm.count != 9 { throw RawCoreError.invalidSettings("ccm must have 9 values, got \(ccm.count)") }
        if let h = toneMapSourceHeadroom, !(1...64).contains(h) { throw RawCoreError.invalidSettings("toneMapSourceHeadroom must be in 1...64") }
        _ = try resolvedStock()
        try finish?.validate()
        if let p = skinProtection, !(0...1).contains(p) { throw RawCoreError.invalidSettings("skinProtection must be in 0...1") }
        if let e = linearExposureEV, !(-4...4).contains(e) { throw RawCoreError.invalidSettings("linearExposureEV must be in -4...4") }
        if let c = highlightClarity, !(0...1).contains(c) { throw RawCoreError.invalidSettings("highlightClarity must be in 0...1") }
        if let g = qualityGuardStrength, !(0.5...1).contains(g) { throw RawCoreError.invalidSettings("qualityGuardStrength must be in 0.5...1") }
        if let o = lookIntensityOffset, !(-0.5...0.5).contains(o) { throw RawCoreError.invalidSettings("lookIntensityOffset must be in -0.5...0.5") }
        if let m = cameraMatchStrength, !(0...1).contains(m) { throw RawCoreError.invalidSettings("cameraMatchStrength must be in 0...1") }
        if let h = decodeHeadroomEV, !(0...1.5).contains(h) { throw RawCoreError.invalidSettings("decodeHeadroomEV must be in 0...1.5") }
        if let n = rollFrameCount, n < 1 { throw RawCoreError.invalidSettings("rollFrameCount must be >= 1") }
        if let i = rollFrameIndex {
            guard i >= 1, i <= (rollFrameCount ?? Int.max) else { throw RawCoreError.invalidSettings("rollFrameIndex must be 1...rollFrameCount") }
        }
        if !(0...1).contains(lookIntensity) { throw RawCoreError.invalidSettings("lookIntensity must be in 0...1") }
        try outputCrop?.validate()
        try sceneNormalizer?.validate()
        if mode == .appleDefault && hasOverrides {
            throw RawCoreError.invalidSettings("appleDefault mode must not carry parameter overrides; use explicit")
        }
    }

    /// The stock this render uses: `stock` + `lookArguments` merged (`FilmStock.resolve`), else `FilmStock.named(stock)`.
    /// nil = no stock. Every reader of the stock goes through here, so a look + arguments and the same roll stock id give
    /// the same `FilmStock`. Throws `invalidSettings`: unknown stock, arguments without a stock, arguments with an
    /// explicit `finish`, or arguments RSP cannot merge.
    public func resolvedStock() throws -> FilmStock? {
        guard let n = stock else {
            if lookArguments != nil { throw RawCoreError.invalidSettings("lookArguments need stock = <supported look id>") }
            return nil
        }
        if let args = lookArguments {
            if finish != nil { throw RawCoreError.invalidSettings("lookArguments and finish cannot be combined: the arguments set the finish") }
            return try FilmStock.resolve(look: n, arguments: args)
        }
        guard let s = FilmStock.named(n) else {
            throw RawCoreError.invalidSettings("unknown stock \(n); known: \(FilmStock.all.map(\.name).joined(separator: ", "))")
        }
        return s
    }

    /// True if any decode parameter is overridden.
    public var hasOverrides: Bool {
        let floats: [Float?] = [exposure, baselineExposure, shadowBias, boostAmount, boostShadowAmount, localToneMapAmount,
                                sharpnessAmount, contrastAmount, detailAmount, luminanceNoiseReductionAmount,
                                colorNoiseReductionAmount, moireReductionAmount, extendedDynamicRangeAmount,
                                neutralTemperature, neutralTint]
        return floats.contains { $0 != nil } || lensCorrection != nil || gamutMapping != nil || ccm != nil || linearExposureEV != nil || toneMapSourceHeadroom != nil || highlightClarity != nil || highlightRecoveryLocal != nil
            || decodeHeadroomEV != nil
    }
}

/// Normalized crop rectangle, origin TOP-LEFT (x right, y down), in the frame `develop` renders (upright, as decoded).
/// `Developer.finish` turns it into whole pixels (`.integral`, clipped to the frame). Pure value type.
public struct OutputCrop: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }

    /// The whole frame (a no-op crop; still runs the v2 finish order).
    public static let full = OutputCrop(x: 0, y: 0, width: 1, height: 1)

    /// A capture zoom (centre crop of 1/zoom, applied when zoom > 1.01, as MoodRoll's `framed`) followed by a framing
    /// `cropRect` [x, y, w, h] measured from the top-left INSIDE the zoomed frame, composed into one rect of the full
    /// frame. nil when neither applies.
    public static func framing(zoom: Double?, cropRect: [Double]?) -> OutputCrop? {
        var c = OutputCrop.full
        var any = false
        if let z = zoom, z > 1.01 {
            c = OutputCrop(x: (1 - 1 / z) / 2, y: (1 - 1 / z) / 2, width: 1 / z, height: 1 / z)
            any = true
        }
        if let r = cropRect, r.count == 4 {
            c = OutputCrop(x: c.x + r[0] * c.width, y: c.y + r[1] * c.height, width: r[2] * c.width, height: r[3] * c.height)
            any = true
        }
        return any ? c : nil
    }

    public func validate() throws {
        let eps = 1e-9
        guard [x, y, width, height].allSatisfy({ $0.isFinite }), x >= -eps, y >= -eps, width > 0, height > 0,
              x + width <= 1 + eps, y + height <= 1 + eps else {
            throw RawCoreError.invalidSettings("outputCrop must be a normalized rect inside 0...1 with positive size, got \(x),\(y),\(width),\(height)")
        }
    }
}

/// The decode parameters actually used for a render (defaults resolved), plus what the file supports.
public struct DecodeParameters: Codable, Equatable, Sendable {
    public var exposure: Float
    public var baselineExposure: Float
    public var shadowBias: Float
    public var boostAmount: Float
    public var boostShadowAmount: Float
    public var localToneMapAmount: Float
    public var sharpnessAmount: Float
    public var contrastAmount: Float
    public var detailAmount: Float
    public var luminanceNoiseReductionAmount: Float
    public var colorNoiseReductionAmount: Float
    public var moireReductionAmount: Float
    public var extendedDynamicRangeAmount: Float
    public var lensCorrection: Bool
    public var gamutMapping: Bool
    public var neutralTemperature: Float
    public var neutralTint: Float

    /// Apply the overrides in `settings` on top of these values.
    public func applying(_ s: RenderSettings) -> DecodeParameters {
        var p = self
        if s.mode == .sceneLinear {
            p.baselineExposure = 0; p.shadowBias = 0; p.boostAmount = 0; p.boostShadowAmount = 0
            p.localToneMapAmount = 0; p.gamutMapping = false
        }
        if let v = s.exposure { p.exposure = v }
        if let v = s.baselineExposure { p.baselineExposure = v }
        if let v = s.shadowBias { p.shadowBias = v }
        if let v = s.boostAmount { p.boostAmount = v }
        if let v = s.boostShadowAmount { p.boostShadowAmount = v }
        if let v = s.localToneMapAmount { p.localToneMapAmount = v }
        if let v = s.sharpnessAmount { p.sharpnessAmount = v }
        if let v = s.contrastAmount { p.contrastAmount = v }
        if let v = s.detailAmount { p.detailAmount = v }
        if let v = s.luminanceNoiseReductionAmount { p.luminanceNoiseReductionAmount = v }
        if let v = s.colorNoiseReductionAmount { p.colorNoiseReductionAmount = v }
        if let v = s.moireReductionAmount { p.moireReductionAmount = v }
        if let v = s.extendedDynamicRangeAmount { p.extendedDynamicRangeAmount = v }
        if let v = s.lensCorrection { p.lensCorrection = v }
        if let v = s.gamutMapping { p.gamutMapping = v }
        if let v = s.neutralTemperature { p.neutralTemperature = v }
        if let v = s.neutralTint { p.neutralTint = v }
        return p
    }
}

public struct DecoderSupport: Codable, Equatable, Sendable {
    public var localToneMap: Bool
    public var sharpness: Bool
    public var contrast: Bool
    public var detail: Bool
    public var luminanceNoiseReduction: Bool
    public var colorNoiseReduction: Bool
    public var moireReduction: Bool
    public var lensCorrection: Bool
    public var maxExtendedDynamicRange: Float
}

/// Written next to every render: enough to reproduce it bit-for-bit on the same OS build.
public struct DecodeRecipe: Codable, Equatable, Sendable {
    public var file: String
    public var settings: RenderSettings
    public var decoderVersion: String
    public var supportedDecoderVersions: [String]
    public var defaults: DecodeParameters
    public var effective: DecodeParameters
    public var support: DecoderSupport
    public var nativeSize: [Int]
    public var scaleFactor: Float
    public var camera: String?
    public var iso: Double?
    public var exposureTime: Double?
    public var osVersion: String
    public var decisions: [String]
    /// Plugins that actually changed something in this render (empty = core pipeline result).
    public var plugins: [String] = []
    /// Plugins that were enabled for this render (whether or not they had anything to do).
    public var pluginsEnabled: [String] = []
    /// LEGACY (<= 0.3.1): free-text calibration note. No longer written (nil, so absent from new JSON); kept so
    /// old recipes still decode. Read `colorSource` instead.
    public var calibration: String? = nil
    /// Stage-0 colour source (pipeline v2): DNG baseline or custom calibration, the file's key, and why custom was
    /// skipped. Old recipes lack it (nil).
    public var colorSource: ColorSourceRecord? = nil
    /// How the decoder version was chosen ("policy", "requested", "Apple default").
    public var decoderVersionSource: String? = nil
    /// Output of the `qualityGuard` plugin: 1 = the finish passed untouched (or 1 was given), 0.5...< 1 = blended back,
    /// nil = the guard was off. Feed it to the final render as `RenderSettings.qualityGuardStrength`. Old recipes lack it (nil).
    public var qualityGuardStrength: Float? = nil
    /// Pipeline v2 stage 1: what the scene normalizer read, decided and delivered, plus the Apple HEIC diagnostic ΔEV.
    /// nil with the legacy exposure model (absent from the JSON, as in 0.3.1).
    public var exposureNormalizer: ExposureNormalizerRecord? = nil
    /// Pipeline v2 stage 2 (fixed stock render): renderer, stock, stage-0 illuminant metadata, components applied / pending.
    /// nil with the legacy exposure model (absent from the JSON, as in 0.4.0). Skeleton: pass-through, pixels unchanged.
    public var stockRender: StockRenderRecord? = nil
    /// Stage 0-H (HEIC entry for selfie / front-camera frames): what was read and decided. nil on RAW frames (omitted from the JSON).
    public var heicStage0: HEICStage0Record? = nil
    /// Film border applied after development (FilmBorderRenderer), nil = no border. Old recipes lack it.
    public var border: FilmBorderRecord? = nil
    /// CALA M1-01 protection trace (what skin protection, look offset, sky hold, highlight/exposure owners, guard and light leak
    /// decided for this frame). nil = trace off (omitted from the JSON); old recipes lack it. Record only.
    public var lookAdaptation: LookAdaptationTrace? = nil

    public init(file: String, settings: RenderSettings, decoderVersion: String, supportedDecoderVersions: [String],
                defaults: DecodeParameters, effective: DecodeParameters, support: DecoderSupport, nativeSize: [Int],
                scaleFactor: Float, camera: String?, iso: Double?, exposureTime: Double?, decisions: [String] = []) {
        self.file = file; self.settings = settings; self.decoderVersion = decoderVersion
        self.supportedDecoderVersions = supportedDecoderVersions; self.defaults = defaults; self.effective = effective
        self.support = support; self.nativeSize = nativeSize; self.scaleFactor = scaleFactor; self.camera = camera
        self.iso = iso; self.exposureTime = exposureTime
        self.osVersion = ProcessInfo.processInfo.operatingSystemVersionString
        self.decisions = decisions
    }
}

public extension Encodable {
    func compactJSON() -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        enc.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return (try? String(decoding: enc.encode(self), as: UTF8.self)) ?? "{}"
    }

    func prettyJSON() -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return (try? String(decoding: enc.encode(self), as: UTF8.self)) ?? "{}"
    }
}
