import Foundation
#if canImport(CoreImage)
import CoreImage
#endif

/// Pipeline v2 stage 2, "fixed stock render" (MoodRoll `.orchestration/film-lab/PIPELINE_V2_CONTRACT.md`): what the film
/// *is*, applied after the stock-independent stage 1 and before the optional creative look (stage 3).
///
/// SKELETON (RSP 0.4.x, branch `feature/pipeline-v2-stage2`): types, protocol and recipe record only. The only
/// implementation, `PassThroughStockRenderer`, returns the image unchanged, so v2 pixels are those of 0.4.0. It runs only
/// with `RenderSettings.exposureModel == .v2Normalizer`; the legacy path never calls it and its recipe has no
/// `stockRender` field.
///
/// Contract rules the API encodes:
/// - **Fixed illuminant response:** the only per-frame input besides the pixels and the stock is the stage-0 illuminant
///   metadata (`IlluminantMetadata`: CCT, tint, `AsShotNeutral`). Same RAW + same stock = same result; no per-frame WB blend.
/// - **No scene classifier:** `StockRenderer.render` gets no scene label, analysis or histogram.
/// - **No global exposure offset:** stage 2 has no exposure input; a stock's `exposureBias` is never applied
///   (`StockRenderRecord.globalExposureOffsetEV` is always 0; stage 1 records the ignored caller exposure in
///   `ExposureNormalizerRecord.ignoredCallerExposureEV`).
/// - **Stock anchors warn, never fail:** `StockAnchors.check` returns warnings only.
///
/// Every stock parameter of stage 2 (curve, crosstalk, saturation by luminance, halation, illuminant response, grain spec)
/// is NOT defined here: the contract gives none, they are re-derived on the frozen golden set (contract order of work
/// step 4). TODO(provisional): parameter shapes and values come from film-lab and need User approval.
public enum StockRender {
    /// Stage-2 implementation version. 0 = skeleton (pass-through).
    public static let version = 0
    public static let parametersStatus = "skeleton: pass-through, no stage-2 stock parameters defined (provisional; PIPELINE_V2_CONTRACT stage 2, order of work step 4)"

    /// The parts of a fixed stock render named by the contract (stage 2 row). Used in the recipe to say what ran.
    public enum Component: String, Codable, CaseIterable, Sendable {
        /// H&D curve with toe and shoulder.
        case characteristicCurve
        case dyeCrosstalk
        case saturationByLuminance
        /// Stock halation (full-frame coordinates, before crop).
        case halation
        /// Stock cast as a fixed function of the stage-0 CCT / tint metadata.
        case illuminantResponse
        /// Grain spec per stock (`GrainProfile`, owned here; generated once at stage 4 on the output, cell fixed in output px).
        case grain
    }
}

/// Stage-2 grain profile, in OUTPUT pixels (film-lab `grain-order/profile/GRAIN_PROFILE_2026-11-19.md`, User-approved
/// 2026-11-19; grain order B, contract round 10 items 6-9). Stage 4 grains once, at the output (the full-resolution
/// master), with the cell fixed in output px; every smaller output is downscaled from that master (pre-filtered) and gets
/// no grain pass of its own.
///
/// Numbers are film-lab's PROVISIONAL values: they come from a Python reproduction, not from RSP output.
public struct GrainProfile: Codable, Equatable, Sendable {
    /// One knot of the density curve: display luma `l` (encoded, 0...1) and the noise weight `s` there.
    public struct Knot: Codable, Equatable, Sendable {
        public var l: Double
        public var s: Double
        public init(l: Double, s: Double) { self.l = l; self.s = s }
    }

    /// Lattice spacing of the grain in output px. The visible cell (ACF FWHM) is about 2.1 x `cellPx`.
    public var cellPx: Double
    /// Luma RMS in 8-bit code at display L = 0.5 on a flat patch, at the master.
    public var sigma50: Double
    /// Density curve s(L), piecewise linear between knots, flat outside them: sigma(L) = `sigma50` x s(L) / s(0.5).
    public var curve: [Knot]
    /// Zero-sum per-channel noise as a fraction of the luma amplitude, same cell and curve (0 = none).
    public var chroma: Double

    /// Approved curve (User 2026-11-19): shadows about x1.7, lows x1.45, mids same, highs x0.7, highlights x0.5 against the
    /// old curve.
    public static let defaultCurve: [Knot] = [(0.0, 0.0), (0.05, 0.40), (0.15, 0.75), (0.30, 1.0), (0.50, 1.0), (0.70, 0.80),
                                              (0.85, 0.50), (1.0, 0.20)].map { Knot(l: $0.0, s: $0.1) }

    /// Reference master short edge of the legacy `{amount, size%}` pair (3024 x 3780 master).
    public static let legacyReferenceShortEdge = 3024.0
    /// Legacy `amount` -> `sigma50` factor (film-lab: `sigma50 = 3.26 x amount`).
    public static let legacySigmaPerAmount = 3.26

    private enum CodingKeys: String, CodingKey { case cellPx, sigma50, curve, chroma }

    /// `{cellPx, sigma50, chroma}` is enough: a missing `curve` is the approved curve, a missing `chroma` is 0.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(cellPx: try c.decode(Double.self, forKey: .cellPx), sigma50: try c.decode(Double.self, forKey: .sigma50),
                  curve: try c.decodeIfPresent([Knot].self, forKey: .curve) ?? GrainProfile.defaultCurve,
                  chroma: try c.decodeIfPresent(Double.self, forKey: .chroma) ?? 0)
    }

    public init(cellPx: Double, sigma50: Double, curve: [Knot] = GrainProfile.defaultCurve, chroma: Double = 0) {
        self.cellPx = cellPx; self.sigma50 = sigma50; self.curve = curve; self.chroma = chroma
    }

    /// Back-compat for a catalog without the new fields: `cellPx = size% x 3024`, `sigma50 = 3.26 x amount`, the approved
    /// curve, no chroma. `size` is a percentage of the short edge (0.07 = 0.07 %).
    public static func derived(amount: Float, size: Float) -> GrainProfile {
        GrainProfile(cellPx: Double(size) / 100 * legacyReferenceShortEdge, sigma50: legacySigmaPerAmount * Double(amount))
    }

    /// Weight s(L) of the curve at encoded luma `l`, normalised so that s(0.5) = 1.
    public func weight(at l: Double) -> Double {
        let raw = GrainProfile.interpolate(curve, l)
        let mid = GrainProfile.interpolate(curve, 0.5)
        return mid > 0 ? raw / mid : 0
    }

    static func interpolate(_ k: [Knot], _ l: Double) -> Double {
        guard let first = k.first, let last = k.last else { return 0 }
        if l <= first.l { return first.s }
        if l >= last.l { return last.s }
        for i in 1..<k.count where l <= k[i].l {
            let a = k[i - 1], b = k[i]
            return b.l > a.l ? a.s + (b.s - a.s) * (l - a.l) / (b.l - a.l) : b.s
        }
        return last.s
    }

    public func validate() throws {
        guard (0.35...64).contains(cellPx) else { throw RawCoreError.invalidSettings("grain cellPx must be 0.35...64 output px") }
        guard (0...16).contains(sigma50) else { throw RawCoreError.invalidSettings("grain sigma50 must be 0...16 (8-bit code)") }
        guard (0...1).contains(chroma) else { throw RawCoreError.invalidSettings("grain chroma must be 0...1") }
        guard curve.count >= 2, curve.allSatisfy({ (0...1).contains($0.l) && $0.s >= 0 && $0.s <= 4 }),
              zip(curve, curve.dropFirst()).allSatisfy({ $0.l < $1.l }) else {
            throw RawCoreError.invalidSettings("grain curve needs 2+ knots, l strictly increasing in 0...1, s in 0...4")
        }
        guard GrainProfile.interpolate(curve, 0.5) > 0 else { throw RawCoreError.invalidSettings("grain curve must be > 0 at L = 0.5") }
    }
}

/// Stage-0 illuminant pass-through (contract WB policy): the camera's white estimate for this frame, as metadata.
/// The pixels stay neutral; stage 2 reads this to apply the stock's fixed illuminant response.
public struct IlluminantMetadata: Codable, Equatable, Sendable {
    /// Correlated colour temperature (K) and tint the camera's white balance chose (CIRAWFilter neutral defaults,
    /// `SceneContext.cct` / `tint`). nil = not analysed (render without analysis).
    public var cct: Double?
    public var tint: Double?
    /// DNG `AsShotNeutral`. TODO(stage 0): not read from the file yet, always nil in this skeleton.
    public var asShotNeutral: [Double]?
    /// Where the values came from.
    public var source: String

    public init(cct: Double?, tint: Double?, asShotNeutral: [Double]? = nil, source: String) {
        self.cct = cct; self.tint = tint; self.asShotNeutral = asShotNeutral; self.source = source
    }

    /// From the analysis' scene context (nil context = no metadata, recorded as such).
    public init(context: SceneContext?) {
        if let c = context {
            self.init(cct: c.cct, tint: c.tint, source: "analysis: CIRAWFilter neutral temperature / tint (AsShotNeutral not read)")
        } else {
            self.init(cct: nil, tint: nil, source: "none: render without analysis")
        }
    }
}

#if canImport(CoreImage)
/// Result of one stage-2 render.
public struct StockRenderResult {
    public var image: CIImage
    /// Components that changed pixels (empty for the pass-through).
    public var applied: [StockRender.Component]
    public var notes: [String]

    public init(image: CIImage, applied: [StockRender.Component] = [], notes: [String] = []) {
        self.image = image; self.applied = applied; self.notes = notes
    }
}

/// A stage-2 implementation. Inputs are deliberately limited to the stage-1 image, the stock and the stage-0 illuminant:
/// no scene label, analysis or exposure value can reach it (contract: no classifier, no exposure offset, fixed response).
/// Must be deterministic.
public protocol StockRenderer: Sendable {
    var id: String { get }
    func render(_ image: CIImage, stock: FilmStock?, illuminant: IlluminantMetadata) throws -> StockRenderResult
}

/// The skeleton implementation: returns the image unchanged (v2 pixels identical to 0.4.0).
public struct PassThroughStockRenderer: StockRenderer {
    public let id = "passThrough"
    public init() {}
    public func render(_ image: CIImage, stock: FilmStock?, illuminant: IlluminantMetadata) throws -> StockRenderResult {
        StockRenderResult(image: image, notes: ["stage 2 pass-through: no stage-2 stock parameters defined yet, pixels unchanged"])
    }
}

#endif

/// What stage 2 did in one render (`DecodeRecipe.stockRender`, only with `exposureModel = .v2Normalizer`).
public struct StockRenderRecord: Codable, Equatable, Sendable {
    public static let currentSchema = 1
    public var schema: Int = StockRenderRecord.currentSchema
    public var version: Int = StockRender.version
    public var renderer: String
    public var parametersStatus: String = StockRender.parametersStatus
    /// Stock the stage ran for (nil = no stock: nothing to render).
    public var stock: String?
    public var illuminant: IlluminantMetadata
    public var applied: [StockRender.Component] = []
    /// Contract components not applied by this render.
    public var pending: [StockRender.Component] = []
    /// Always 0: stage 2 has no global exposure offset (contract: `exposureBias` removed from stocks).
    public var globalExposureOffsetEV: Double = 0
    public var notes: [String] = []

    public init(renderer: String, stock: String?, illuminant: IlluminantMetadata, applied: [StockRender.Component], notes: [String]) {
        self.renderer = renderer; self.stock = stock; self.illuminant = illuminant; self.applied = applied
        self.pending = StockRender.Component.allCases.filter { !applied.contains($0) }
        self.notes = notes
    }
}

/// An approved anchor frame of a stock (contract regression gate, "stock anchors"): kept with its approval date.
public struct StockAnchor: Codable, Equatable, Sendable {
    public var stock: String
    /// Golden-set frame id (e.g. "GS-A01").
    public var frame: String
    /// Approval date (ISO 8601 day) and who approved it.
    public var approvedOn: String
    public var approvedBy: String?
    /// Pixel fingerprint of the approved stage-2 output (look off).
    public var fingerprint: String
    /// RSP engine / pipeline version the anchor was rendered with.
    public var pipeline: String

    public init(stock: String, frame: String, approvedOn: String, approvedBy: String? = nil, fingerprint: String, pipeline: String) {
        self.stock = stock; self.frame = frame; self.approvedOn = approvedOn; self.approvedBy = approvedBy
        self.fingerprint = fingerprint; self.pipeline = pipeline
    }
}

/// A drift warning: the stock's render of an anchor frame no longer matches the approved one. Film-lab and the User
/// decide whether to accept it and record that decision; it never fails a run.
public struct StockAnchorDrift: Codable, Equatable, Sendable {
    public var stock: String
    public var frame: String
    public var approvedOn: String
    public var expected: String
    /// nil = the anchor frame was not rendered in this run.
    public var got: String?
    public var message: String
}

public enum StockAnchors {
    /// Key of a render in `check`'s `rendered` map.
    public static func key(stock: String, frame: String) -> String { "\(stock)|\(frame)" }

    /// Compares rendered fingerprints (`key(stock:frame:)` -> fingerprint) with the approved anchors. Returns warnings
    /// only, never throws. Drift is "fingerprint differs" for now. TODO(provisional): a numeric drift metric (contract
    /// "stock fidelity") and its warn level come from film-lab at golden-set freeze and need User approval.
    public static func check(_ anchors: [StockAnchor], rendered: [String: String]) -> [StockAnchorDrift] {
        anchors.compactMap { a in
            let got = rendered[key(stock: a.stock, frame: a.frame)]
            if got == a.fingerprint { return nil }
            let msg = got == nil
                ? "warning: \(a.stock) anchor \(a.frame) (approved \(a.approvedOn)) was not rendered"
                : "warning: \(a.stock) drifted from anchor \(a.frame) (approved \(a.approvedOn)): \(got!) != \(a.fingerprint)"
            return StockAnchorDrift(stock: a.stock, frame: a.frame, approvedOn: a.approvedOn, expected: a.fingerprint, got: got, message: msg)
        }
    }
}
