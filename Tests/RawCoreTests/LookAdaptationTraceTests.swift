#if canImport(CoreImage)
import CoreImage
import XCTest
@testable import RawCore

/// CALA M1-01 protection trace: record only. Present and correct, round-trips, omitted when off, pixels identical on or off.
final class LookAdaptationTraceTests: XCTestCase {
    typealias T = LookAdaptationTrace

    /// A synthetic frame: flat colour image, hand-made context and person mask, no file and no Vision.
    func syntheticBase(_ st: RenderSettings, capture: LookAdaptationDecideCapture? = nil, personMask: Bool = true) throws -> (Developer, Developer.Base) {
        let dev = Developer()
        let image = CIImage(color: CIColor(red: 0.4, green: 0.35, blue: 0.3)).cropped(to: CGRect(x: 0, y: 0, width: 96, height: 64))
        var c = SceneContext(logP1: -12, logP50: -6.5, logP99: 1, dynamicRangeStops: 15, clippedFraction: 0.05, iso: 3200, faceCount: 1, labels: nil)
        c.largestFaceArea = 0.05; c.personFraction = 0.2
        var diag = PersonMaskDiagnostics(status: .ok)
        diag.pixelsAtLeast128 = 100; diag.width = 96; diag.height = 64; diag.maxValue = 255; diag.nonZeroPixels = 120; diag.source = .balanced
        c.personMaskDiag = diag
        let recipe = DecodeRecipe(file: "synthetic", settings: st, decoderVersion: "synthetic", supportedDecoderVersions: [],
                                  defaults: HeadroomTests.defaults, effective: HeadroomTests.defaults, support: HeadroomTests.support,
                                  nativeSize: [96, 64], scaleFactor: 1, camera: nil, iso: nil, exposureTime: nil)
        let mask = CIImage(color: CIColor(red: 1, green: 1, blue: 1)).cropped(to: CGRect(x: 0, y: 0, width: 96, height: 64))
        let active = try dev.plugins.active(for: st)
        let pctx = PluginRenderContext(renderer: dev.renderer, decodeBase: { image }, scene: c, decodeSceneLinear: nil)
        var base = Developer.Base(image: image, recipe: recipe, settings: st, context: c, personMask: personMask ? mask : nil,
                                  developedFor: nil, active: active, ran: [], pluginContext: pctx)
        base.adaptationCapture = capture
        return (dev, base)
    }

    func settings(trace: Bool?) -> RenderSettings {
        var st = RenderSettings(mode: .explicit); st.stock = "goldenDay"; st.skinProtection = 0.75; st.lookIntensityOffset = -0.05
        st.traceLookAdaptation = trace
        return st
    }

    func testTracePresentAndCorrectOnASyntheticFrame() throws {
        let capture = LookAdaptationDecideCapture(callerSkin: 0.75, callerOffset: -0.05, bias: 0.3, autoFired: false, terms: nil, sum: nil, clamped: nil)
        let (dev, base) = try syntheticBase(settings(trace: true), capture: capture)
        let out = try dev.finish(base)
        let t = try XCTUnwrap(out.recipe.lookAdaptation)
        XCTAssertEqual(t.version, 1)
        XCTAssertEqual(t.mode, "traceOnly")
        XCTAssertEqual(t.frame.kind, .raw)
        XCTAssertEqual(t.frame.finishOrder, .noCrop)
        XCTAssertEqual(t.frame.look, "goldenDay")
        XCTAssertTrue(t.frame.analysed)
        // Skin: caller 0.75, mask ok -> applied; effective = what protectSkin received.
        XCTAssertEqual(t.skin.callerSkin, 0.75)
        XCTAssertEqual(t.skin.autoFired, false)
        XCTAssertEqual(t.skin.effective, 0.75)
        XCTAssertEqual(t.skin.maskValidity, .ok)
        XCTAssertEqual(t.skin.outcome, .applied)
        XCTAssertEqual(t.skin.status, .applied)
        XCTAssertEqual(t.skin.thresholdPersonFraction, DecisionEngine.Threshold.personFraction)
        XCTAssertEqual(t.skin.personFraction, 0.2)
        XCTAssertTrue(out.recipe.decisions.contains { $0.hasPrefix("skin protection 0.75 through the Vision person mask") })
        // Look offset: caller lock -0.05; applied intensity = min(max(base + off, 0), 1), same as the decision line.
        XCTAssertEqual(t.lookOffset.callerLock, -0.05)
        XCTAssertEqual(t.lookOffset.offset, -0.05)
        let b = try XCTUnwrap(t.lookOffset.baseIntensity), a = try XCTUnwrap(t.lookOffset.appliedIntensity)
        XCTAssertEqual(a, min(max(b - 0.05, 0), 1), accuracy: 1e-6)
        XCTAssertEqual(t.lookOffset.skip, .none)
        XCTAssertEqual(t.lookOffset.status, .applied)
        XCTAssertEqual(t.lookOffset.rangeLower, DecisionEngine.Threshold.lookIntensityRange.lowerBound)
        XCTAssertNotEqual(t.lookOffset.usedBy, .none)
        // Exposure and guard: bias copied, final equals the recipe, guard off by default.
        XCTAssertEqual(t.exposure.bias, 0.3)
        XCTAssertEqual(t.exposure.finalDecodeEV, out.recipe.effective.exposure)
        XCTAssertEqual(t.qualityGuard.source, .off)
        XCTAssertEqual(t.qualityGuard.reason, .guardOff)
        XCTAssertEqual(t.qualityGuard.strengthFinal, out.recipe.qualityGuardStrength)
        // Light leak: goldenDay has no leak spec; the rule still appears with a reason.
        XCTAssertFalse(t.lightLeak.specPresent)
        XCTAssertEqual(t.lightLeak.status, .notApplicable)
        // Sky hold: the rule is present with a status either way; the hold amount is the stock's.
        XCTAssertEqual(t.skyHold.holdAmount, try dev.finishStock(base).skyHoldAmount)
        XCTAssertEqual(t.skyHold.minCoverage, SkyMask.minCoverage)
    }

    func testSkinSkippedWithoutMaskCarriesAReason() throws {
        let (dev, base) = try syntheticBase(settings(trace: true), personMask: false)
        let t = try XCTUnwrap(try dev.finish(base).recipe.lookAdaptation)
        XCTAssertEqual(t.skin.outcome, .skippedNoMask)
        XCTAssertEqual(t.skin.status, .skipped)
        XCTAssertEqual(t.skin.reason, .noMaskUnavailable)   // diag says ok but no image: treated as unavailable (M1_02 3.1)
        XCTAssertEqual(t.skin.maskValidity, .unavailable)
    }

    func testMonoLookSkipsSkinAndOffsetWithReasons() throws {
        var st = settings(trace: true); st.stock = "monoSoft"
        let (dev, base) = try syntheticBase(st)
        let t = try XCTUnwrap(try dev.finish(base).recipe.lookAdaptation)
        XCTAssertEqual(t.skin.outcome, .skippedMono)
        XCTAssertEqual(t.skin.reason, .monoLook)
        XCTAssertEqual(t.lookOffset.skip, .monoLook)
        XCTAssertEqual(t.lookOffset.appliedIntensity, t.lookOffset.baseIntensity)
    }

    /// T3: the trace recomputes `LightLeakPlanner.plan`; its numbers must match the plugin's own decision line for the same frame.
    func testLightLeakTraceMatchesThePluginDecisionLine() throws {
        for frame in [1, 2, 7, 18, 36] {
            var st = RenderSettings(mode: .explicit)
            st.stock = "rr-la-phong-100"; st.rollID = "trace-match"; st.rollFrameIndex = frame; st.rollFrameCount = 36
            st.traceLookAdaptation = true
            let (dev, base) = try syntheticBase(st)
            let out = try dev.finish(base)
            let t = try XCTUnwrap(out.recipe.lookAdaptation).lightLeak
            let line = try XCTUnwrap(out.recipe.decisions.first { $0.hasPrefix("[lightLeak] frame ") }, "frame \(frame)")
            XCTAssertTrue(t.specPresent)
            XCTAssertEqual(t.frame, frame); XCTAssertEqual(t.count, 36)
            XCTAssertTrue(line.contains("(\(try XCTUnwrap(t.frameClass)))"), line)
            XCTAssertTrue(line.contains(String(format: "draw %.3f", try XCTUnwrap(t.chanceDraw))), line)
            XCTAssertTrue(line.contains(String(format: "chance %.2f", try XCTUnwrap(t.chance))), line)
            if t.drawn == true {
                XCTAssertEqual(t.status, .applied)
                XCTAssertTrue(line.contains("leak (draw"), line)
                XCTAssertTrue(line.contains("edge \(try XCTUnwrap(t.edge))"), line)
                XCTAssertTrue(line.contains(String(format: "strength %.2f", try XCTUnwrap(t.strength))), line)
                XCTAssertTrue(line.contains(String(format: "position %.2f", try XCTUnwrap(t.position))), line)
                XCTAssertTrue(line.contains(String(format: "hue %.0f > %.0f", try XCTUnwrap(t.coreHue), try XCTUnwrap(t.outerHue))), line)
            } else {
                XCTAssertEqual(t.status, .skipped); XCTAssertEqual(t.reason, .noLeakDrawn)
                XCTAssertTrue(line.contains(": no leak (draw"), line)
            }
        }
    }

    func testRecipeRoundTripAndOmittedWhenOff() throws {
        let (dev, onBase) = try syntheticBase(settings(trace: true))
        let on = try dev.finish(onBase).recipe
        let data = try JSONEncoder().encode(on)
        XCTAssertEqual(try JSONDecoder().decode(DecodeRecipe.self, from: data), on)
        XCTAssertTrue(on.compactJSON().contains("\"lookAdaptation\""))
        let (dev2, offBase) = try syntheticBase(settings(trace: nil))
        let off = try dev2.finish(offBase).recipe
        XCTAssertNil(off.lookAdaptation)
        XCTAssertFalse(off.compactJSON().contains("lookAdaptation"), "nil trace is omitted from the JSON")
        XCTAssertFalse(off.compactJSON().contains("traceLookAdaptation"))
        // A recipe from before the key decodes.
        var obj = try JSONSerialization.jsonObject(with: JSONEncoder().encode(off)) as! [String: Any]
        obj.removeValue(forKey: "lookAdaptation")
        XCTAssertNoThrow(try JSONDecoder().decode(DecodeRecipe.self, from: JSONSerialization.data(withJSONObject: obj)))
    }

    func testSameInputSameTrace() throws {
        let (dev, base) = try syntheticBase(settings(trace: true))
        let a = try dev.finish(base).recipe.lookAdaptation
        let b = try dev.finish(base).recipe.lookAdaptation
        XCTAssertEqual(a, b)
        XCTAssertEqual(a?.compactJSON(), b?.compactJSON())
    }

    /// The gate: the pre-encode pixel buffer with the trace on equals the one with it off (pattern of HeadroomTests, `[Float]` ==).
    func testPixelsAreBitIdenticalWithTraceOnAndOffOnASyntheticFrame() throws {
        for stock in ["goldenDay", "monoSoft"] {
            var on = settings(trace: true); on.stock = stock
            var off = settings(trace: nil); off.stock = stock
            let (dev, onBase) = try syntheticBase(on)
            let (_, offBase) = try syntheticBase(off)
            let pOn = try dev.renderer.linearImage(try dev.finish(onBase).image).pixels
            let pOff = try dev.renderer.linearImage(try dev.finish(offBase).image).pixels
            XCTAssertFalse(pOn.isEmpty)
            XCTAssertTrue(pOn == pOff, "\(stock): trace on vs off must be pixel-identical")
        }
    }

    // MARK: renders on the fixture DNG (skipped without originals/)

    func testDNGDecideCaptureAndBitIdenticalPixels() throws {
        let f = try HeadroomTests().fixture()
        var st = RenderSettings(mode: .explicit); st.stock = "goldenDay"
        var on = st; on.traceLookAdaptation = true
        func render(_ s: RenderSettings) throws -> (pixels: [Float], recipe: DecodeRecipe, base: Developer.Base) {
            let b = try f.dev.developBase(url: f.url, settings: s, auto: true, scaleFactor: f.scale, analysis: f.an)
            let out = try f.dev.finish(b)
            return (try f.dev.renderer.linearImage(out.image).pixels, out.recipe, b)
        }
        let a = try render(st), b = try render(on)
        XCTAssertTrue(a.pixels == b.pixels, "trace on vs off: pre-encode pixels identical")
        XCTAssertNil(a.recipe.lookAdaptation)
        let t = try XCTUnwrap(b.recipe.lookAdaptation)
        // decide-time capture equals what decide wrote.
        XCTAssertNil(t.skin.callerSkin)
        XCTAssertEqual(t.skin.autoFired, b.base.settings.skinProtection != nil)
        XCTAssertEqual(t.lookOffset.offset, b.base.settings.lookIntensityOffset)
        if let off = b.base.settings.lookIntensityOffset {
            XCTAssertEqual(t.lookOffset.clamped, off)
            XCTAssertEqual(Float(t.lookOffset.terms?.map(\.value).reduce(0, +) ?? 0), t.lookOffset.sum ?? 0, accuracy: 1e-6)
        }
        XCTAssertEqual(t.exposure.finalDecodeEV, b.recipe.effective.exposure)
        XCTAssertEqual(t.qualityGuard.strengthFinal, b.recipe.qualityGuardStrength)
    }
}

extension Developer {
    /// Test helper: the stock `finish` resolves for a base.
    func finishStock(_ base: Base) throws -> FilmStock {
        try XCTUnwrap(try base.settings.resolvedStock())
    }
}
#endif
