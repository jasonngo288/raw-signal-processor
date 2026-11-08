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
    /// Film stock (`FilmStock.all`): sets look, intensity and finish unless `look` / `finish` are given explicitly.
    public var stock: String?
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
        if let n = stock, FilmStock.named(n) == nil {
            throw RawCoreError.invalidSettings("unknown stock \(n); known: \(FilmStock.all.map(\.name).joined(separator: ", "))")
        }
        try finish?.validate()
        if let p = skinProtection, !(0...1).contains(p) { throw RawCoreError.invalidSettings("skinProtection must be in 0...1") }
        if let e = linearExposureEV, !(-4...4).contains(e) { throw RawCoreError.invalidSettings("linearExposureEV must be in -4...4") }
        if let c = highlightClarity, !(0...1).contains(c) { throw RawCoreError.invalidSettings("highlightClarity must be in 0...1") }
        if !(0...1).contains(lookIntensity) { throw RawCoreError.invalidSettings("lookIntensity must be in 0...1") }
        if mode == .appleDefault && hasOverrides {
            throw RawCoreError.invalidSettings("appleDefault mode must not carry parameter overrides; use explicit")
        }
    }

    /// True if any decode parameter is overridden.
    public var hasOverrides: Bool {
        let floats: [Float?] = [exposure, baselineExposure, shadowBias, boostAmount, boostShadowAmount, localToneMapAmount,
                                sharpnessAmount, contrastAmount, detailAmount, luminanceNoiseReductionAmount,
                                colorNoiseReductionAmount, moireReductionAmount, extendedDynamicRangeAmount,
                                neutralTemperature, neutralTint]
        return floats.contains { $0 != nil } || lensCorrection != nil || gamutMapping != nil || ccm != nil || linearExposureEV != nil || toneMapSourceHeadroom != nil || highlightClarity != nil || highlightRecoveryLocal != nil
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
    /// Plugins that ran for this render (empty = core pipeline only).
    public var plugins: [String] = []
    /// Calibration entry used ("iPhone14,3 v1"), or why none was used.
    public var calibration: String? = nil
    /// How the decoder version was chosen ("policy", "requested", "Apple default").
    public var decoderVersionSource: String? = nil

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
