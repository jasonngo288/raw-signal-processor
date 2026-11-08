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

    /// Exact match on the camera string, then on a contained model identifier.
    public func entry(for camera: String?) -> ModelCalibration? {
        guard let camera, !camera.isEmpty else { return nil }
        return models.first { $0.model == camera } ?? models.first { camera.contains($0.model) }
    }
}

/// Roadmap: "decoderVersion khóa cứng". Instead of taking whatever the OS offers as default, pick the first
/// version of a fixed preference list that the file supports. Change the list only on purpose (WORK_LOG + bench).
public enum DecoderPolicy {
    /// Newest first. RAW 9 (WWDC26) is NOT in the list yet: add it only after a bench run on that OS.
    public static let preferred = ["8", "8.dng", "7", "7.dng", "6", "6.dng"]

    public static func pick(supported: [String]) -> String? { preferred.first { supported.contains($0) } }
}
