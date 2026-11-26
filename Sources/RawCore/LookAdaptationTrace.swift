import Foundation

/// CALA M1-01 protection trace: what the existing rules decided for one frame. RECORD ONLY: building it reads values the
/// render already computed and never changes a setting, a mask, a LUT or a pixel. Typed (enums and numbers), deterministic
/// (no timing, no paths, no roll id), privacy-safe (Vision error as `domain code` only). Off = nil = key omitted from the
/// recipe JSON (`DecodeRecipe.lookAdaptation`), switched on with `RenderSettings.traceLookAdaptation`.
/// Design: `.orchestration/film-lab/cala/m1/M1_01_PROTECTION_TRACE.md`.
public struct LookAdaptationTrace: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public enum Status: String, Codable, Sendable { case applied, skipped, notApplicable }

    /// Closed list (design section 3). `noMask*` flatten `noMask(unavailable|failed|empty)`.
    public enum Reason: String, Codable, Sendable {
        case ok, callerSet, belowGate, monoLook, stockDisallows
        case noMaskUnavailable, noMaskFailed, noMaskEmpty
        case zeroValue, pluginOff, noAnalysis, noDecision, noSkyInFrame, noRollPosition, outsideRoll, noLeakDrawn
        case givenFromPreview, guardOff, guardPassed, noStrength, noLook, noLeakSpec, notReached, noUnheldVariant
    }

    /// Validity of a context feature (M1_02 section 3), derived from data that already exists.
    public enum Validity: String, Codable, Sendable { case unavailable, failed, empty, ok }

    public var version: Int
    /// "traceOnly" in M1 (no lever exists).
    public var mode: String
    public var frame: Frame
    public var skin: Skin
    public var lookOffset: LookOffset
    public var skyHold: SkyHold
    public var highlightRecovery: HighlightRecovery
    public var exposure: Exposure
    public var qualityGuard: QualityGuard
    public var lightLeak: LightLeak

    public struct Frame: Codable, Equatable, Sendable {
        public enum Kind: String, Codable, Sendable { case raw, heicOnly }
        public enum FinishOrder: String, Codable, Sendable { case crop, noCrop }
        public var kind: Kind
        public var finishOrder: FinishOrder
        /// x, y, width, height of `settings.outputCrop` (top-left, fractions), nil without a crop.
        public var outputCrop: [Double]?
        /// A scene analysis was available to the rules (`base.context != nil`).
        public var analysed: Bool
        /// A stored analysis was handed in and used (not analysed again). nil = no capture (no decide on this base).
        public var analysisReused: Bool?
        public var exposureModel: String
        /// RSP look id (`settings.stock`) or explicit look name; nil when neither is set.
        public var look: String?
        /// `lookArguments.depth`, read only (DD 61: depth is a fixed stock property).
        public var depth: Float?
    }

    public struct Skin: Codable, Equatable, Sendable {
        public enum Outcome: String, Codable, Sendable {
            case applied, skippedMono, skippedStockDisallows, skippedNoMask, skippedZero, notRequested, noLook
        }
        public var status: Status
        public var reason: Reason
        /// `settings.skinProtection` as the caller set it, before `DecisionEngine.decide`. nil on a base made without decide-time capture.
        public var callerSkin: Float?
        /// decide set it from person / face (caller left it nil). nil when decide did not run for this base.
        public var autoFired: Bool?
        public var personFraction: Double?
        public var largestFaceArea: Double?
        public var faceCount: Int?
        /// Constants in force (`DecisionEngine.Threshold`).
        public var thresholdPersonFraction: Double
        public var thresholdFaceArea: Double
        public var autoStrength: Float
        public var stockMin: Float?
        public var stockAllows: Bool
        /// `max(caller or auto, stockMin)` as `Developer.finish` used it.
        public var effective: Float?
        public var maskValidity: Validity
        public var maskDiag: PersonMaskDiagnostics?
        public var outcome: Outcome
    }

    public struct LookOffset: Codable, Equatable, Sendable {
        public enum Skip: String, Codable, Sendable { case none, zeroOffset, monoLook }
        public enum UsedBy: String, Codable, Sendable { case none, plainLook, skyGatedLook, pluginLook, declaredLook }
        public struct Term: Codable, Equatable, Sendable {
            public var id: String          // night, highISO, people, landscape
            public var score: Double
            public var weight: Float
            public var value: Float
        }
        public var status: Status
        public var reason: Reason
        public var callerLock: Float?
        public var terms: [Term]?
        public var sum: Float?
        public var clamped: Float?
        public var rangeLower: Float
        public var rangeUpper: Float
        /// `settings.lookIntensityOffset` in effect at finish.
        public var offset: Float?
        public var skip: Skip
        public var baseIntensity: Float?
        public var appliedIntensity: Float?
        public var usedBy: UsedBy
    }

    public struct SkyHold: Codable, Equatable, Sendable {
        public enum Path: String, Codable, Sendable { case notApplicable, colourOnly, unheldNoSky, blendedByMask }
        public var status: Status
        public var reason: Reason
        public var holdAmount: Float
        public var pluginOn: Bool
        public var maskVersion: Int?
        public var fraction: Double?
        /// The existing `skyGate` text (the only label recorded).
        public var gate: String?
        public var minCoverage: Double
        public var path: Path
    }

    public struct HighlightRecovery: Codable, Equatable, Sendable {
        public var pluginOn: Bool
        public var headroomPluginOn: Bool
        public var displayClipped: Double?
        public var recoverable: Double?
        public var edrHeadroom: Double?
        public var fired: Bool
        public var toneMapSourceHeadroom: Float?
        public var clarity: Float?
        public var decodeHeadroomEV: Float?
        public var headroomRestoreEV: Float?
    }

    public struct Exposure: Codable, Equatable, Sendable {
        /// `settings.exposure` as the caller set it, before decide (the stock bias). nil = not captured / none.
        public var bias: Float?
        /// `recipe.effective.exposure`: the decode EV after headroom split and cameraMatch.
        public var finalDecodeEV: Float
        public var cameraMatchPluginOn: Bool
        public var cameraMatchStrength: Float?
    }

    public struct QualityGuard: Codable, Equatable, Sendable {
        public enum Source: String, Codable, Sendable { case off, given, measured }
        public var status: Status
        public var reason: Reason
        public var source: Source
        public var strengthGiven: Float?
        public var strengthFinal: Float?
        public var measures: Int?
        public var maxClipIncrease: Double
        public var maxExposureDriftEV: Double
    }

    public struct LightLeak: Codable, Equatable, Sendable {
        public enum PersonMask: String, Codable, Sendable { case attenuated, noMask, factorIs1 }
        public var status: Status
        public var reason: Reason
        public var specPresent: Bool
        public var frame: Int?
        public var count: Int?
        public var frameClass: String?
        public var chance: Float?
        public var chanceDraw: Float?
        public var drawn: Bool?
        public var edge: String?
        public var strength: Float?
        public var position: Float?
        public var sigma: Float?
        public var coreHue: Float?
        public var outerHue: Float?
        public var personFactor: Float?
        public var personMaskUsed: PersonMask?
        public var encodedCap: Float?

        public init(status: Status, reason: Reason, specPresent: Bool) {
            self.status = status; self.reason = reason; self.specPresent = specPresent
        }
    }
}

/// Decide-time values `Developer.developBase` copies when the trace is on (before `DecisionEngine.decide` changes them).
struct LookAdaptationDecideCapture: Sendable {
    var callerSkin: Float?
    var callerOffset: Float?
    var bias: Float?
    var autoFired: Bool
    var terms: [LookAdaptationTrace.LookOffset.Term]?
    var sum: Float?
    var clamped: Float?
    var analysisReused: Bool? = nil
}
