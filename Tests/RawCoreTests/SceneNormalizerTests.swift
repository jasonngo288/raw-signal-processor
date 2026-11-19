#if canImport(CoreImage)
import CoreImage
import XCTest
@testable import RawCore

/// Pipeline v2, RSP work item B (MoodRoll `.orchestration/film-lab/PIPELINE_V2_CONTRACT.md`, stage 1): the continuous
/// scene normalizer behind `RenderSettings.exposureModel = .v2Normalizer`; `.legacy` (default) keeps the 0.3.1 chain.
final class SceneNormalizerTests: XCTestCase {
    let renderer = Renderer()
    static let originals = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("originals")

    func appleDNG() throws -> URL {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: Self.originals.path)) ?? []
        let pick = names.contains("IMG_1901.DNG") ? "IMG_1901.DNG" : names.filter { $0.lowercased().hasSuffix(".dng") }.sorted().first
        guard let n = pick else { throw XCTSkip("no DNGs in originals/") }
        return Self.originals.appendingPathComponent(n)
    }

    // MARK: pure

    func testHeadroomSplitIsTheLegacyFormula() {
        for bias: Float in [-0.6, -0.25, 0, 0.05, 0.45, 0.8] {
            for d: Float in [0.5, 1.0, 1.5] {
                let (dec, res) = HeadroomSplit.split(bias: bias, headroomEV: d)
                XCTAssertEqual(dec, min(bias, 0) - d)
                XCTAssertEqual(res, d + max(bias, 0))
            }
            XCTAssertEqual(HeadroomSplit.split(bias: bias, headroomEV: 0).decodeEV, bias)
            XCTAssertNil(HeadroomSplit.split(bias: bias, headroomEV: 0).restoreEV)
        }
    }

    func inputs(anchorL: Double, ev100: Double? = 8) -> SceneNormalizer.Inputs {
        var c = SceneContext(logP1: -6, logP50: -2.5, logP99: -0.5, dynamicRangeStops: 6, clippedFraction: 0, iso: 100, faceCount: 0, labels: nil)
        c.exposureTime = 0.01
        var i = SceneNormalizer.Inputs(context: c, baselineExposureEV: 0, fNumber: 1.8)
        i.appleDefaultMedianY = SceneNormalizer.luminance(lstar: anchorL)
        i.ev100 = ev100
        return i
    }

    func testDecideIsContinuousAndKeepsKeyOrder() {
        let p = SceneNormalizer.Parameters.provisional
        var last: (anchor: Double, out: Double)?
        for a in stride(from: 20.0, through: 90.0, by: 2.5) {
            let plan = SceneNormalizer.decide(inputs(anchorL: a), p)
            let out = plan.targetMedianY!
            let anchor = SceneNormalizer.luminance(lstar: a)
            XCTAssertTrue((-p.maxCutEV...p.maxLiftEV).contains(plan.globalEV))
            if let l = last {
                XCTAssertGreaterThan(out, l.out, "a brighter metered scene must stay brighter (key intent): \(a)")
                XCTAssertLessThanOrEqual(log2(out / l.out), log2(anchor / l.anchor) + 1e-9, "never steeper than the input: no jump")
            }
            last = (anchor, out)
            XCTAssertEqual(plan.decodeExposureEV, min(plan.globalEV, 0), "no cut before the probes")
        }
        // Strength 0 = the camera's metering untouched; 1 = every median on the target (inside the bounds).
        var p0 = p; p0.strength = 0
        XCTAssertEqual(SceneNormalizer.decide(inputs(anchorL: 70), p0).globalEV, 0)
        var p1 = p; p1.strength = 1
        XCTAssertEqual(SceneNormalizer.lstar(SceneNormalizer.decide(inputs(anchorL: 60), p1).targetMedianY!), p.midTargetL, accuracy: 1e-6)
        // Night intent is a smooth function of EV100, not a branch.
        let w = [8.0, 5.0, 4.99, 4.0, 3.5, 2.0, 0.0].map { SceneNormalizer.decide(inputs(anchorL: 50, ev100: $0), p).nightWeight }
        XCTAssertEqual(w.first, 0); XCTAssertEqual(w.last, 1)
        XCTAssertLessThan(abs(w[1] - w[2]), 0.001)
        XCTAssertEqual(w, w.sorted())
        XCTAssertEqual(SceneNormalizer.decide(inputs(anchorL: 50, ev100: nil), p).nightWeight, 0)
    }

    func testInputsHaveNoAppleHEICField() throws {
        var c = SceneContext(logP1: -6, logP50: -2.5, logP99: -0.5, dynamicRangeStops: 6, clippedFraction: 0, iso: 100, faceCount: 0, labels: nil)
        c.lumaHistogram = Array(repeating: 1.0 / 64, count: 64)
        let plain = SceneNormalizer.Inputs(context: c, baselineExposureEV: 0.2, fNumber: 1.8)
        c.cameraReferenceHistogram = Array(repeating: 0, count: 63) + [1]
        c.cameraReferenceHistogramFine = Array(repeating: 0, count: 255) + [1]
        let withHEIC = SceneNormalizer.Inputs(context: c, baselineExposureEV: 0.2, fNumber: 1.8)
        XCTAssertEqual(plain, withHEIC)
        XCTAssertFalse(withHEIC.compactJSON().lowercased().contains("camera"))
        XCTAssertEqual(SceneNormalizer.decide(plain, .provisional), SceneNormalizer.decide(withHEIC, .provisional))
    }

    func testHighlightCutIsTheSmallestThatMeetsTheAllowance() throws {
        let p = SceneNormalizer.Parameters.provisional
        let plan = SceneNormalizer.decide(inputs(anchorL: 50), p)
        // Synthetic monotone clip: 10 % at the plan's exposure, falling 8 % per EV of cut; sensor 1 %.
        func clip(_ ev: Double) -> Double { max(0.01, 0.10 + 0.08 * (ev - plan.decodeExposureEV)) }
        let cut = SceneNormalizer.withHighlightCut(plan, p, sensorClippedFraction: 0.01, clipAt: clip)
        let exact = (0.10 - 0.01 - p.highlightClipAllowance) / 0.08
        XCTAssertGreaterThanOrEqual(cut.highlightCutEV, exact - 1e-9)
        XCTAssertLessThanOrEqual(cut.highlightCutEV, exact + p.maxDecodeHeadroomEV / Double(1 << p.highlightProbeSteps) + 1e-9)
        XCTAssertEqual(cut.decodeExposureEV, min(plan.globalEV, 0) - cut.highlightCutEV, accuracy: 1e-12)
        XCTAssertEqual(cut.highlightProbes.count, 2 + p.highlightProbeSteps)
        let none = SceneNormalizer.withHighlightCut(plan, p, sensorClippedFraction: 0) { _ in 0.001 }
        XCTAssertEqual(none.highlightCutEV, 0); XCTAssertEqual(none.highlightProbes.count, 1)
        let capped = SceneNormalizer.withHighlightCut(plan, p, sensorClippedFraction: 0) { _ in 0.5 }
        XCTAssertEqual(capped.highlightCutEV, p.maxDecodeHeadroomEV); XCTAssertFalse(capped.notes.isEmpty)
    }

    func testV2RestoreCurveIsContinuousInTheGain() {
        for y: Float in [0, 0.05, 0.2, 0.45, 0.7, 0.95, 1] {
            XCTAssertEqual(HeadroomRestore.curveV2(y, gain: 1), y)
            XCTAssertEqual(HeadroomRestore.curveV2(y, gain: pow(2, 0.01)), y, accuracy: 0.01, "small gain = small change (legacy curve jumps)")
        }
        for g: Float in [0.1, 0.5, 1, 2, 3] {
            let G = pow(2, g)
            XCTAssertEqual(HeadroomRestore.curveV2(1, gain: G), 1, accuracy: 1e-5)
            XCTAssertEqual(HeadroomRestore.curveV2(0.1 / G, gain: G), 0.1, accuracy: 1e-5, "exact gain below the knee")
            var prev: Float = -1
            for i in 0...200 {
                let v = HeadroomRestore.curveV2(Float(i) / 200, gain: G)
                XCTAssertGreaterThanOrEqual(v, prev); prev = v
            }
        }
    }

    // MARK: on a DNG

    func pixels(_ o: Developer.Output) throws -> [Float] { try renderer.linearImage(o.image).pixels }

    /// A same-press "camera HEIC" stand-in: Apple's default render 0.7 EV darker, written as HEIC.
    func fakeHEIC(_ url: URL, dev: Developer) throws -> URL {
        var s = RenderSettings(mode: .explicit)
        s.exposure = -0.7
        let scale = try dev.decoder.scaleFactor(url: url, longEdge: 1024)
        let img = try dev.decoder.decode(url: url, settings: s, scaleFactor: scale).image
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("scene-normalizer-\(UUID().uuidString).heic")
        try dev.renderer.export(img, format: .heic10).write(to: out)
        return out
    }

    func testLegacyIsTheDefaultAndUnchanged() throws {
        let url = try appleDNG()
        let dev = Developer()
        let heic = try fakeHEIC(url, dev: dev)
        defer { try? FileManager.default.removeItem(at: heic) }
        let analysis = try dev.analyze(url: url, cameraReference: heic.path)
        let scale = try dev.decoder.scaleFactor(url: url, longEdge: 384)
        var s = RenderSettings(mode: .explicit)
        s.stock = "rr-sao-mai-200"; s.exposure = 0.05; s.decodeHeadroomEV = 1; s.cameraMatchStrength = 0.5; s.cameraReference = heic.path
        XCTAssertEqual(s.resolvedExposureModel, .legacy)
        let implicit = try dev.develop(url: url, settings: s, auto: true, scaleFactor: scale, analysis: analysis)
        var e = s; e.exposureModel = .legacy
        let explicitLegacy = try dev.develop(url: url, settings: e, auto: true, scaleFactor: scale, analysis: analysis)
        XCTAssertEqual(try pixels(implicit), try pixels(explicitLegacy))
        XCTAssertNil(implicit.recipe.exposureNormalizer)
        XCTAssertFalse(implicit.recipe.compactJSON().contains("exposureNormalizer"), "legacy recipe JSON has no new key")
        XCTAssertFalse(implicit.recipe.settings.compactJSON().contains("exposureModel"))
        // The legacy chain still runs: headroom split of the bias and the HEIC exposure match.
        XCTAssertTrue(implicit.recipe.decisions.contains { $0.hasPrefix("[headroom] decode exposure -1.00 EV, display restore +1.05 EV") })
        XCTAssertTrue(implicit.recipe.decisions.contains { $0.hasPrefix("[cameraMatch] camera HEIC") })
    }

    func v2Settings(stock: String? = "rr-sao-mai-200") -> RenderSettings {
        var s = RenderSettings(mode: .explicit)
        s.stock = stock
        s.exposureModel = .v2Normalizer
        s.rollID = "R1"; s.rollFrameIndex = 3; s.rollFrameCount = 24
        return s
    }

    func testV2IsDeterministicAndIgnoresStockExposureAndHEIC() throws {
        let url = try appleDNG()
        let dev = Developer()
        let heic = try fakeHEIC(url, dev: dev)
        defer { try? FileManager.default.removeItem(at: heic) }
        let withRef = try dev.analyze(url: url, cameraReference: heic.path)
        let noRef = try dev.analyze(url: url)
        XCTAssertNotNil(withRef.context.cameraReferenceHistogram)
        XCTAssertNil(noRef.context.cameraReferenceHistogram)
        let scale = try dev.decoder.scaleFactor(url: url, longEdge: 384)

        let base = try dev.develop(url: url, settings: v2Settings(), auto: true, scaleFactor: scale, analysis: noRef)
        let rec = try XCTUnwrap(base.recipe.exposureNormalizer)
        print("[v2-normalizer] \(url.lastPathComponent): \(base.recipe.decisions.filter { $0.hasPrefix("[normalizer]") })")
        XCTAssertNil(rec.skipped)
        XCTAssertEqual(rec.model, .v2Normalizer)
        XCTAssertEqual(rec.parametersStatus, SceneNormalizer.parametersStatus)
        XCTAssertNotNil(rec.plan); XCTAssertNotNil(rec.inputs); XCTAssertNotNil(rec.restoreEV); XCTAssertNotNil(rec.decidedEV)
        XCTAssertNil(rec.appleDiagnosticDeltaEV, "no HEIC, no diagnostic")
        XCTAssertEqual(Double(try XCTUnwrap(base.recipe.settings.exposure)), try XCTUnwrap(rec.plan?.decodeExposureEV), accuracy: 1e-6)
        XCTAssertFalse(base.recipe.decisions.contains { $0.hasPrefix("[headroom]") })
        XCTAssertFalse(base.recipe.plugins.contains("cameraMatch"))

        // Deterministic: same RAW, same analysis, same settings.
        let again = try dev.develop(url: url, settings: v2Settings(), auto: true, scaleFactor: scale, analysis: noRef)
        XCTAssertEqual(try pixels(again), try pixels(base))
        XCTAssertEqual(again.recipe.exposureNormalizer, rec)

        // Apple HEIC present (file + stored histograms) changes no pixel; it only fills the diagnostic.
        var h = v2Settings(); h.cameraReference = heic.path
        let ref = try dev.develop(url: url, settings: h, auto: true, scaleFactor: scale, analysis: withRef)
        XCTAssertEqual(try pixels(ref), try pixels(base))
        let rr = try XCTUnwrap(ref.recipe.exposureNormalizer)
        XCTAssertNotNil(rr.appleDiagnosticDeltaEV)
        XCTAssertEqual(rr.appleDiagnosticSource, "stored analysis histogram")
        XCTAssertEqual(rr.plan, rec.plan); XCTAssertEqual(rr.restoreEV, rec.restoreEV)
        var fileOnly = v2Settings(); fileOnly.cameraReference = heic.path
        let viaFile = try dev.develop(url: url, settings: fileOnly, auto: true, scaleFactor: scale, analysis: noRef)
        XCTAssertEqual(try pixels(viaFile), try pixels(base))
        XCTAssertEqual(viaFile.recipe.exposureNormalizer?.appleDiagnosticSource, "HEIC file")

        // A stock's exposureBias (and decode headroom, cameraMatch strength) do not move the v2 exposure.
        for (bias, hr, cm) in [(Float(-0.25), Float(1.0), Float(0)), (0.8, 1.5, 1), (0.05, 0, 0.5)] {
            var b = v2Settings(); b.exposure = bias; b.decodeHeadroomEV = hr; b.cameraMatchStrength = cm
            let o = try dev.develop(url: url, settings: b, auto: true, scaleFactor: scale, analysis: noRef)
            XCTAssertEqual(try pixels(o), try pixels(base), "bias \(bias) headroom \(hr) cm \(cm)")
            XCTAssertEqual(o.recipe.exposureNormalizer?.ignoredCallerExposureEV, bias)
            XCTAssertEqual(o.recipe.exposureNormalizer?.ignoredDecodeHeadroomEV, hr)
            XCTAssertEqual(o.recipe.effective.exposure, base.recipe.effective.exposure)
        }

        // Same stage-1 decision for another stock.
        let other = try dev.develop(url: url, settings: v2Settings(stock: "rr-den-vang-800t"), auto: true, scaleFactor: scale, analysis: noRef)
        XCTAssertEqual(other.recipe.exposureNormalizer?.plan, rec.plan)
        XCTAssertEqual(other.recipe.exposureNormalizer?.restoreEV, rec.restoreEV)
    }

    /// Review M1 (2026-11-17) + User 2026-11-18: stage 1 sees no stock-dependent step, and v2 forces highlightRecovery off
    /// for every stock. A caller list with HR on gives the same pixels as one without it (recipe: forced off). Two stocks
    /// (different filmDevelop profile): same plan, same display gain, same stage-1 pixels.
    func testV2StageOneIsStockIndependentAndHighlightRecoveryIsForcedOff() throws {
        let dev = Developer()
        let url = try appleDNG()
        let analysis = try dev.analyze(url: url)
        let scale = try dev.decoder.scaleFactor(url: url, longEdge: 384)
        let on = try dev.developBase(url: url, settings: v2Settings(stock: "rr-sao-mai-200"), auto: true, scaleFactor: scale, analysis: analysis)
        var noHR = v2Settings(stock: "rr-sao-mai-200")
        noHR.plugins = PluginRegistry.standard.defaultEnabled.filter { $0 != "highlightRecovery" }
        let off = try dev.developBase(url: url, settings: noHR, auto: true, scaleFactor: scale, analysis: analysis)
        XCTAssertFalse(on.ran.contains("highlightRecovery")); XCTAssertFalse(on.recipe.pluginsEnabled.contains("highlightRecovery"))
        XCTAssertEqual(on.recipe.exposureNormalizer?.highlightRecoveryForcedOff, true)
        XCTAssertEqual(off.recipe.exposureNormalizer?.highlightRecoveryForcedOff, false)
        XCTAssertEqual(try renderer.linearImage(on.image).pixels, try renderer.linearImage(off.image).pixels)

        let other = try dev.developBase(url: url, settings: v2Settings(stock: "rr-den-vang-800t"), auto: true, scaleFactor: scale, analysis: analysis)
        let a = try XCTUnwrap(on.recipe.exposureNormalizer), b = try XCTUnwrap(other.recipe.exposureNormalizer)
        XCTAssertEqual(a.plan, b.plan); XCTAssertEqual(a.restoreEV, b.restoreEV); XCTAssertEqual(a.decodeMedianL, b.decodeMedianL)
        XCTAssertEqual(a.stage1ClippedFraction, b.stage1ClippedFraction); XCTAssertEqual(a.shortfallEV, b.shortfallEV)
        let p1 = try renderer.linearImage(XCTUnwrap(on.stage1Image)).pixels, p2 = try renderer.linearImage(XCTUnwrap(other.stage1Image)).pixels
        XCTAssertEqual(p1, p2, "stage-1 pixels differ between stocks")
        XCTAssertNotNil(a.stage1ClipLimit); XCTAssertNotNil(a.masterClippedFraction); XCTAssertNotNil(a.stage1ClipMeasure)
        XCTAssertLessThanOrEqual(try XCTUnwrap(a.stage1ClippedFraction), try XCTUnwrap(a.stage1ClipLimit) + 1e-12)
        print("[v2-stage1] \(url.lastPathComponent): gain \(a.restoreEV ?? .nan) induced \(a.stage1ClippedFraction ?? .nan) limit \(a.stage1ClipLimit ?? .nan) short \(a.shortfallEV ?? .nan) differs \(a.stage1Decode?.differsFromDelivered ?? []) notes \(a.notes)")
    }

    func testV2WithoutAutoSkipsAndStillIgnoresTheBias() throws {
        let url = try appleDNG()
        let dev = Developer()
        let scale = try dev.decoder.scaleFactor(url: url, longEdge: 256)
        var s = v2Settings(stock: nil); s.exposure = 0.8
        let o = try dev.develop(url: url, settings: s, auto: false, scaleFactor: scale)
        XCTAssertNotNil(o.recipe.exposureNormalizer?.skipped)
        XCTAssertEqual(o.recipe.exposureNormalizer?.ignoredCallerExposureEV, 0.8)
        XCTAssertEqual(o.recipe.effective.exposure, o.recipe.defaults.exposure)
    }

    func testClipTopCodeParameter() throws {
        XCTAssertEqual(SceneNormalizer.Parameters.provisional.clipTopCode8bit, 254)  // interim default (User, 2026-11-18)
        XCTAssertEqual(SceneNormalizer.Parameters.defaultClipTopCode8bit, 254)
        var nilCode = SceneNormalizer.Parameters.provisional; nilCode.clipTopCode8bit = nil
        XCTAssertEqual(nilCode.effectiveClipTopCode8bit, 254)                          // nil = the default, not 255
        XCTAssertNoThrow(try nilCode.validate())
        var bad = SceneNormalizer.Parameters.provisional; bad.clipTopCode8bit = 256
        XCTAssertThrowsError(try bad.validate())
        XCTAssertLessThan(Developer.hardClipLinear(code: 254), Developer.hardClipLinear(code: 255))
        XCTAssertTrue(Developer.inducedClipMeasure(code: 254).contains("code >= 254"))
    }

    /// JSON from before `clipTopCode8bit` existed decodes to the default 254, not 255 (User 2026-11-19, contract round 8).
    func testParametersDecodeWithoutClipTopCodeGivesDefault254() throws {
        var obj = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(SceneNormalizer.Parameters.provisional)) as? [String: Any])
        XCTAssertEqual(obj["clipTopCode8bit"] as? Int, 254)
        obj.removeValue(forKey: "clipTopCode8bit")
        let old = try JSONDecoder().decode(SceneNormalizer.Parameters.self, from: JSONSerialization.data(withJSONObject: obj))
        XCTAssertEqual(old.clipTopCode8bit, 254)
        XCTAssertEqual(old.effectiveClipTopCode8bit, 254)
        XCTAssertEqual(old, .provisional)
        XCTAssertNoThrow(try old.validate())
        // Explicit values still round-trip.
        var p255 = SceneNormalizer.Parameters.provisional; p255.clipTopCode8bit = 255
        XCTAssertEqual(try JSONDecoder().decode(SceneNormalizer.Parameters.self, from: JSONEncoder().encode(p255)), p255)
    }

    func testParametersValidate() {
        XCTAssertNoThrow(try SceneNormalizer.Parameters.provisional.validate())
        var p = SceneNormalizer.Parameters.provisional; p.strength = 1.5
        var s = v2Settings(); s.sceneNormalizer = p
        XCTAssertThrowsError(try s.validate())
        p = .provisional; p.nightEV100Full = 6
        XCTAssertThrowsError(try p.validate())
    }
}
#endif
