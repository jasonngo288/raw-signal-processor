import Foundation

/// Per-model colour calibration (roadmap: CCM in linearSpaceFilter). Measured from ColorChecker shots under
/// D65 / A for each iPhone model; until a model is measured it has no entry and Apple's DNG matrices are used.
public struct ModelCalibration: Codable, Equatable, Sendable {
    /// Camera string as CIRAWFilter reports it ("Apple iPhone 13 Pro Max") or a model identifier ("iPhone14,3").
    public var model: String
    /// Row-major 3x3 matrix in the decoder's scene-linear space. Identity = no colour change.
    public var ccm: [Float]
    /// Exposure offset (EV) so that a grey card lands at the same level on every model.
    public var exposureOffsetEV: Float
    /// Calibration version, written into the recipe.
    public var version: String
    /// Where the numbers came from (lab session, chart, illuminant) — "unmeasured" for placeholders.
    public var source: String

    public init(model: String, ccm: [Float], exposureOffsetEV: Float, version: String, source: String) {
        self.model = model; self.ccm = ccm; self.exposureOffsetEV = exposureOffsetEV; self.version = version; self.source = source
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
