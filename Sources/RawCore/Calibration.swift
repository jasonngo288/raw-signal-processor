import Foundation

/// Per-model colour calibration (roadmap: CCM in linearSpaceFilter). Measured from ColorChecker shots under
/// D65 / A for each iPhone model; until a model is measured it has no entry and Apple's DNG matrices are used.
/// Pipeline v2 stage 0 (MoodRoll PIPELINE_V2_CONTRACT): calibration is OPTIONAL future data; the default colour source
/// is the DNG metadata Apple ships per model. An entry is keyed by model + lens + RAW format and is used by `develop`
/// only on an exact match of all three (`CalibrationTable.lookup`).
public struct ModelCalibration: Codable, Equatable, Sendable {
    /// Camera string as CIRAWFilter reports it ("Apple iPhone 13 Pro Max") or a model identifier ("iPhone14,3").
    public var model: String
    /// EXIF LensModel of the file ("iPhone 13 Pro Max back camera 5.7mm f/1.5"). nil = entry without a lens key
    /// (pre-v2 tables): never used by `develop`, which needs the full key.
    public var lens: String?
    /// `CalibrationKey.RawFormat` raw value ("bayer" | "linearRaw"). nil = entry without a format key: never used by `develop`.
    public var rawFormat: String?
    /// Row-major 3x3 matrix in the decoder's scene-linear space. Identity = no colour change.
    public var ccm: [Float]
    /// Exposure offset (EV) so that a grey card lands at the same level on every model.
    public var exposureOffsetEV: Float
    /// Calibration version, written into the recipe.
    public var version: String
    /// Where the numbers came from (lab session, chart, illuminant) — "unmeasured" for placeholders.
    public var source: String

    public init(model: String, lens: String? = nil, rawFormat: String? = nil, ccm: [Float], exposureOffsetEV: Float, version: String, source: String) {
        self.model = model; self.lens = lens; self.rawFormat = rawFormat
        self.ccm = ccm; self.exposureOffsetEV = exposureOffsetEV; self.version = version; self.source = source
    }

    public func validate() throws {
        guard ccm.count == 9 else { throw RawCoreError.invalidSettings("calibration \(model): ccm needs 9 values") }
        guard (-4...4).contains(exposureOffsetEV) else { throw RawCoreError.invalidSettings("calibration \(model): exposure offset out of range") }
    }

    /// CCM and exposure as one matrix (exposure is a uniform scale in linear light).
    public var linearMatrix: [Float] { ccm.map { $0 * Float(pow(2.0, Double(exposureOffsetEV))) } }
}

public struct CalibrationTable: Codable, Equatable, Sendable {
    public var schema: Int
    public var models: [ModelCalibration]

    public init(schema: Int = 1, models: [ModelCalibration] = []) { self.schema = schema; self.models = models }

    public static let empty = CalibrationTable()

    public static func load(_ url: URL) throws -> CalibrationTable {
        let t = try JSONDecoder().decode(CalibrationTable.self, from: Data(contentsOf: url))
        for m in t.models { try m.validate() }
        return t
    }

    /// MODEL-ONLY lookup (pre-v2; lens and RAW format are ignored). `Developer` no longer uses it: develop goes through
    /// `lookup(_:)`, which needs the full model + lens + format key. Kept for tools and old callers.
    /// Exact match only (no substring guessing: an "iPhone 13 Pro" entry must never serve a Pro Max).
    /// Candidates, in order: model identifier ("iPhone14,3"), DNG UniqueCameraModel, "Make Model" camera string.
    public func entry(forAny candidates: [String?]) -> ModelCalibration? {
        for c in candidates.compactMap({ $0 }).filter({ !$0.isEmpty }) {
            if let m = models.first(where: { $0.model == c }) { return m }
        }
        return nil
    }

    public func entry(for camera: String?) -> ModelCalibration? { entry(forAny: [camera]) }

    /// Candidate keys for a file: identifier token of UniqueCameraModel ("iPhone14,3 back camera" → "iPhone14,3"),
    /// the full UniqueCameraModel, then "Make Model".
    public static func candidates(uniqueCameraModel: String?, camera: String?) -> [String?] {
        [uniqueCameraModel.flatMap { $0.split(separator: " ").first.map(String.init) }, uniqueCameraModel, camera]
    }

    /// Pipeline v2 stage-0 lookup: exact match on model (any candidate, in candidate order) AND lens AND RAW format.
    /// No partial fallback: a model-only entry, or the same model with another lens or format, is never used.
    /// Every miss says why (`ColorSourceRecord.SkipReason` + detail), so the recipe never falls back silently.
    public func lookup(_ key: CalibrationKey) -> CalibrationLookup {
        guard !models.isEmpty else { return .missing(.emptyTable, "calibration table is empty: DNG metadata") }
        var unknown: [String] = []
        if key.models.isEmpty { unknown.append("model") }
        if key.lens == nil { unknown.append("lens") }
        if key.rawFormat == nil { unknown.append("RAW format") }
        guard unknown.isEmpty else {
            return .missing(.keyIncomplete, "file \(unknown.joined(separator: ", ")) unknown: no exact calibration key, DNG metadata")
        }
        for c in key.models {
            if let m = models.first(where: { $0.model == c && $0.lens == key.lens && $0.rawFormat == key.rawFormat?.rawValue }) {
                return .found(m)
            }
        }
        let sameModel = models.filter { key.models.contains($0.model) }
        if sameModel.isEmpty {
            return .missing(.noEntry, "no entry for \(key.models.joined(separator: " / ")): DNG metadata")
        }
        let have = sameModel.map { "\($0.model) [\($0.lens ?? "no lens") | \($0.rawFormat ?? "no format")] \($0.version)" }
        return .missing(.keyMismatch, "entries for this model do not match lens \"\(key.lens ?? "")\" + \(key.rawFormat?.rawValue ?? ""): "
                        + have.joined(separator: "; ") + ": DNG metadata")
    }
}

/// Stage-0 calibration key of one file: device model + lens + RAW format (MoodRoll PIPELINE_V2_CONTRACT, stage 0).
public struct CalibrationKey: Codable, Equatable, Sendable {
    /// How the mosaic is stored: DNG PhotometricInterpretation 32803 (CFA) = Bayer RAW, 34892 (LinearRaw) = a demosaiced
    /// linear DNG such as Apple ProRAW.
    public enum RawFormat: String, Codable, Sendable, CaseIterable {
        case bayer, linearRaw

        public init?(photometricInterpretation p: Int?) {
            switch p {
            case 32803: self = .bayer
            case 34892: self = .linearRaw
            default: return nil
            }
        }
    }

    /// Model candidates in lookup order (`CalibrationTable.candidates`: identifier, UniqueCameraModel, "Make Model").
    public var models: [String]
    /// EXIF LensModel ("iPhone 14 Pro back camera 6.86mm f/1.78"); nil = the file does not say.
    public var lens: String?
    /// nil = the file does not say (or a PhotometricInterpretation other than CFA / LinearRaw).
    public var rawFormat: RawFormat?

    public init(models: [String?], lens: String?, rawFormat: RawFormat?) {
        self.models = models.compactMap { $0 }.filter { !$0.isEmpty }
        self.lens = (lens?.isEmpty ?? true) ? nil : lens
        self.rawFormat = rawFormat
    }
}

public enum CalibrationLookup: Equatable, Sendable {
    case found(ModelCalibration)
    case missing(ColorSourceRecord.SkipReason, String)
}

/// Stage-0 colour source of a render, structured (replaces the free-text `DecodeRecipe.calibration`).
/// `source == .dngBaseline` always carries a `skipReason`; `.customCalibration` carries the profile fields.
public struct ColorSourceRecord: Codable, Equatable, Sendable {
    public static let currentSchema = 1

    public enum Source: String, Codable, Sendable {
        /// Apple's DNG metadata only (ColorMatrix1/2, AsShotNeutral, BaselineExposure, opcodes): the v2 default.
        case dngBaseline
        /// A `ModelCalibration` entry matched the full key and its CCM + exposure offset went into linearSpaceFilter.
        case customCalibration
    }

    /// Why custom calibration was not used. Checked in this order.
    public enum SkipReason: String, Codable, Sendable {
        /// `RenderSettings.mode == .appleDefault`: the reference decode never takes a calibration.
        case appleDefaultMode
        /// `RenderSettings.useCalibration == false`.
        case calibrationDisabled
        /// The caller set `RenderSettings.ccm`; it is applied on top of the DNG matrices, the table is not read.
        case explicitCCM
        /// The caller set `RenderSettings.linearExposureEV`; the table is not read.
        case explicitLinearExposure
        /// The developer's table has no entries (the shipped default).
        case emptyTable
        /// The file does not give model, lens or RAW format, so there is no exact key.
        case keyIncomplete
        /// No entry for this model.
        case noEntry
        /// Entries exist for this model but none with this lens and RAW format (no partial fallback).
        case keyMismatch
    }

    public var schema: Int? = ColorSourceRecord.currentSchema
    public var source: Source
    /// The file's key (always read, also when the table is not consulted).
    public var key: CalibrationKey?
    /// Custom only: entry model string, version and provenance (`ModelCalibration.model / version / source`).
    public var profileID: String?
    public var profileVersion: String?
    public var profileSource: String?
    /// dngBaseline only: why the custom calibration was skipped, and a human-readable detail.
    public var skipReason: SkipReason?
    public var detail: String?

    public init(source: Source, key: CalibrationKey?, profileID: String? = nil, profileVersion: String? = nil,
                profileSource: String? = nil, skipReason: SkipReason? = nil, detail: String? = nil) {
        self.source = source; self.key = key; self.profileID = profileID; self.profileVersion = profileVersion
        self.profileSource = profileSource; self.skipReason = skipReason; self.detail = detail
    }

    public static func dngBaseline(_ key: CalibrationKey?, _ reason: SkipReason, _ detail: String) -> ColorSourceRecord {
        ColorSourceRecord(source: .dngBaseline, key: key, skipReason: reason, detail: detail)
    }

    public static func custom(_ key: CalibrationKey, _ entry: ModelCalibration) -> ColorSourceRecord {
        ColorSourceRecord(source: .customCalibration, key: key, profileID: entry.model, profileVersion: entry.version, profileSource: entry.source)
    }
}

/// Roadmap: "decoderVersion khóa cứng". Instead of taking whatever the OS offers as default, pick the first
/// version of a fixed preference list that the file supports. Change the list only on purpose (WORK_LOG + bench).
public enum DecoderPolicy {
    /// Newest first. RAW 9 (WWDC26) is NOT in the list yet: add it only after a bench run on that OS.
    /// A newer generic `.dng` decoder is preferred over an older camera-specific one (e.g. iPhone SE: `8.dng` over
    /// Apple's default `7`); kept on purpose (user, 2026-11-09), so Gate 1 on such files compares two versions.
    public static let preferred = ["8", "8.dng", "7", "7.dng", "6", "6.dng"]

    public static func pick(supported: [String]) -> String? { preferred.first { supported.contains($0) } }
}
