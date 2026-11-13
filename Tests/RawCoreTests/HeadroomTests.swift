#if canImport(CoreImage)
import CoreImage
import XCTest
@testable import RawCore

/// Plugin `headroom` and `HeadroomRestore` (RSP 0.3.0, sign-off C1-C3, C6, §5 headroom tests).
final class HeadroomTests: XCTestCase {
    static let originals = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("originals")

    // MARK: restore curve and LUT (pure)

    func testCurveMonotoneEndsAtOneAndLinearBelowTheKnee() {
        for ev in [Float(0.3), 0.7, 1.0, 1.3, 1.5] {
            let G = pow(2, ev)
            var last: Float = -1
            for i in 0...1000 {
                let y = Float(i) / 1000
                let f = HeadroomRestore.curve(y, gain: G)
                XCTAssertGreaterThanOrEqual(f, last, "Δ \(ev): not monotone at \(y)")
                last = f
            }
            XCTAssertEqual(HeadroomRestore.curve(1, gain: G), 1, accuracy: 1e-6, "f(1) = 1")
            XCTAssertEqual(HeadroomRestore.curve(0, gain: G), 0)
            // Below the knee k = c/G the curve is a straight line through 0: f(m) = G·m / raw(1). The normalisation
            // f(1) = 1 (exact port of the prototype, C6) scales the slope by 1/raw(1): ×1.026 at Δ 1, ×1.13 at Δ 0.3.
            let k = HeadroomRestore.kneeOut / G
            let slope = HeadroomRestore.curve(k * 0.5, gain: G) / (k * 0.5)
            for m in [k * 0.1, k * 0.3, k * 0.9, k] {
                XCTAssertEqual(HeadroomRestore.curve(m, gain: G), slope * m, accuracy: 1e-5)
            }
            let c = HeadroomRestore.kneeOut
            let raw1 = c + (1 - c) * (1 - exp(-G * (1 - k) / (1 - c)))
            XCTAssertEqual(slope, G / raw1, accuracy: 1e-4 * G)
            XCTAssertGreaterThanOrEqual(slope, G - 1e-4)
        }
    }

    /// Max-channel scaling: every node's three linear channels are scaled by one factor, so hue (and the chroma ratio) is kept.
    func testLUTKeepsChannelRatios() {
        let n = 17
        let lut = HeadroomRestore.make(gainEV: 1, size: n)
        var worstHue: Float = 0
        for b in 0..<n { for g in 0..<n { for r in 0..<n {
            let e = SIMD3(Float(r), Float(g), Float(b)) / Float(n - 1)
            let o4 = ((b * n + g) * n + r) * 4
            let o = SIMD3(lut.rgba[o4], lut.rgba[o4 + 1], lut.rgba[o4 + 2])
            let li = SIMD3(Preset26.decode(e.x), Preset26.decode(e.y), Preset26.decode(e.z))
            let lo = SIMD3(Preset26.decode(o.x), Preset26.decode(o.y), Preset26.decode(o.z))
            guard li.min() > 0.01 else { continue }
            let k = lo / li
            XCTAssertEqual(k.x, k.y, accuracy: 1e-3 * k.x, "\(e)")
            XCTAssertEqual(k.x, k.z, accuracy: 1e-3 * k.x, "\(e)")
            let a = OKLab.lch(encodedP3: e), c = OKLab.lch(encodedP3: o)
            if a.y > 0.02 { var d = abs(a.z - c.z); if d > 180 { d = 360 - d }; worstHue = max(worstHue, d) }
        } } }
        XCTAssertLessThan(worstHue, 0.1, "hue preserved")
        XCTAssertTrue(lut.rgba.allSatisfy { $0 >= 0 && $0 <= 1 })
        XCTAssertEqual(lut.apply(SIMD3(repeating: 1)).x, 1, accuracy: 1e-5, "white stays white")
    }

    func testGainIsQuantisedAndCachedInTwoEntries() {
        XCTAssertEqual(HeadroomRestore.quantised(1.004), 1.0)
        XCTAssertEqual(HeadroomRestore.quantised(1.296), 1.3)
        XCTAssertEqual(HeadroomRestore.lut(gainEV: 1.004, size: 9), HeadroomRestore.make(gainEV: 1.0, size: 9))
        XCTAssertEqual(HeadroomRestore.cacheCapacity, 2)
        let c = HeadroomRestoreCache(capacity: 2)
        for k in ["1.00|9", "1.30|9", "0.70|9"] { _ = c.lut(k) { HeadroomRestore.make(gainEV: 0.5, size: 2) } }
        XCTAssertEqual(c.keys, ["1.30|9", "0.70|9"])
    }

    // MARK: settings (C2)

    func testRangeAndAppleDefault() {
        var st = RenderSettings(mode: .explicit)
        for v in [Float(0), 1, 1.5] { st.decodeHeadroomEV = v; XCTAssertNoThrow(try st.validate(), "\(v)") }
        for v in [Float(-0.1), 1.51, 3] { st.decodeHeadroomEV = v; XCTAssertThrowsError(try st.validate(), "\(v)") }
        var apple = RenderSettings.appleDefault
        apple.decodeHeadroomEV = 1
        XCTAssertTrue(apple.hasOverrides)
        XCTAssertThrowsError(try apple.validate(), "appleDefault must reject decodeHeadroomEV")
        var json = RenderSettings(mode: .explicit); json.decodeHeadroomEV = 1
        XCTAssertEqual(try JSONDecoder().decode(RenderSettings.self, from: JSONEncoder().encode(json)), json)
        XCTAssertFalse(RenderSettings.explicit.compactJSON().contains("Headroom"), "nil fields stay out of the recipe JSON")
    }

    // MARK: decide order and the split (C3)

    static let defaults = DecodeParameters(exposure: 0, baselineExposure: 0, shadowBias: 0, boostAmount: 1, boostShadowAmount: 1,
                                           localToneMapAmount: 0.5, sharpnessAmount: 0.5, contrastAmount: 0, detailAmount: 0,
                                           luminanceNoiseReductionAmount: 0.2, colorNoiseReductionAmount: 0.2, moireReductionAmount: 0,
                                           extendedDynamicRangeAmount: 0, lensCorrection: true, gamutMapping: true, neutralTemperature: 5000, neutralTint: 0)
    static let support = DecoderSupport(localToneMap: true, sharpness: true, contrast: true, detail: true, luminanceNoiseReduction: true,
                                        colorNoiseReduction: true, moireReduction: true, lensCorrection: true, maxExtendedDynamicRange: 2)

    /// A scene where DecisionEngine and the highlightRecovery rule both fire.
    static func busyContext() -> SceneContext {
        var c = SceneContext(logP1: -12, logP50: -6.5, logP99: 1, dynamicRangeStops: 15, clippedFraction: 0.05, iso: 3200, faceCount: 1, labels: nil)
        c.displayClippedFraction = 0.4; c.edrHeadroom = 40; c.largestFaceArea = 0.05; c.personFraction = 0.2
        return c
    }

    func testDecisionEngineAndHighlightRecoveryLeaveExposureAlone() {
        var base = RenderSettings.explicit
        base.exposure = 0.3
        let d = DecisionEngine.decide(context: Self.busyContext(), defaults: Self.defaults, support: Self.support, base: base)
        XCTAssertGreaterThan(d.reasons.count, 3)
        XCTAssertEqual(d.settings.exposure, 0.3)
        var st = d.settings
        let why = HighlightRecoveryPlugin().decide(context: Self.busyContext(), defaults: Self.defaults, settings: &st)
        XCTAssertFalse(why.isEmpty)
        XCTAssertEqual(st.exposure, 0.3)
        var st2 = base
        _ = HighlightRecoveryRule.decide(context: Self.busyContext(), settings: &st2)
        XCTAssertNotNil(st2.toneMapSourceHeadroom, "the rule fired")
        XCTAssertEqual(st2.exposure, 0.3)
    }

    /// All decides in registry order (as `developBase` runs them) with a camera reference that moves the exposure.
    func testOrderAndSplit() throws {
        var c = Self.busyContext()
        var ours = [Double](repeating: 0, count: 64), theirs = ours
        for i in 10..<40 { ours[i] = 1.0 / 30 }
        for i in 14..<44 { theirs[i] = 1.0 / 30 }
        c.lumaHistogram = ours; c.cameraReferenceHistogram = theirs
        let off = Float(ToneMatch.exposureOffsetEV(candidate: ours, reference: theirs))
        XCTAssertGreaterThanOrEqual(abs(off), 0.05, "the reference must move the exposure for this test")
        for (bias, decode, restore) in [(Float(0.3), Float(-1.0), Float(1.3)), (-0.35, -1.35, 1.0), (0, -1.0, 1.0)] {
            var st = RenderSettings.explicit
            st.exposure = bias; st.decodeHeadroomEV = 1
            st = DecisionEngine.decide(context: c, defaults: Self.defaults, support: Self.support, base: st).settings
            let active = try PluginRegistry.standard.active(for: st)
            XCTAssertEqual(active.map(\.id).prefix(3), ["highlightRecovery", "headroom", "cameraMatch"])
            for p in active { _ = p.decide(context: c, defaults: Self.defaults, settings: &st) }
            XCTAssertEqual(st.exposure!, decode + off, accuracy: 1e-5, "bias \(bias): decode exposure = min(bias, 0) − Δ + off")
            XCTAssertEqual(st.headroomRestoreEV!, restore, accuracy: 1e-6, "bias \(bias): restore = Δ + max(bias, 0)")
        }
        // Without a reference the decode is exactly min(bias, 0) − Δ.
        var st = RenderSettings.explicit
        st.exposure = 0.3; st.decodeHeadroomEV = 1
        for p in try PluginRegistry.standard.active(for: st) { _ = p.decide(context: Self.busyContext(), defaults: Self.defaults, settings: &st) }
        XCTAssertEqual(st.exposure!, -1.0, accuracy: 1e-6)
    }

    // MARK: renders on the fixture DNG

    struct Fixture { let dev: Developer; let url: URL; let scale: Float; let an: Developer.Analysis }

    func fixture() throws -> Fixture {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: Self.originals.path)) ?? []).filter { $0.lowercased().hasSuffix(".dng") }.sorted()
        guard let n = names.first(where: { $0 == "USER_mooncake.dng" }) ?? names.first else { throw XCTSkip("no DNGs in originals/") }
        let url = Self.originals.appendingPathComponent(n)
        let dev = Developer()
        return Fixture(dev: dev, url: url, scale: try dev.decoder.scaleFactor(url: url, longEdge: 256), an: try dev.analyze(url: url))
    }

    func render(_ f: Fixture, _ st: RenderSettings, auto: Bool = true) throws -> (pixels: [Float], recipe: DecodeRecipe, base: RenderSettings) {
        let b = try f.dev.developBase(url: f.url, settings: st, auto: auto, scaleFactor: f.scale, analysis: f.an)
        let out = try f.dev.finish(b)
        return (try f.dev.renderer.linearImage(out.image).pixels, out.recipe, b.settings)
    }

    func testOffIsPixelIdenticalAndSilent() throws {
        let f = try fixture()
        var st = RenderSettings(mode: .explicit); st.stock = "goldenDay"
        let none = try render(f, st)
        st.decodeHeadroomEV = 0
        let zero = try render(f, st)
        XCTAssertTrue(none.pixels == zero.pixels, "Δ 0 = Δ nil, pixel for pixel")
        for r in [none, zero] {
            XCTAssertFalse(r.recipe.decisions.contains { $0.hasPrefix("[headroom]") || $0.contains("decodeHeadroomEV") }, "\(r.recipe.decisions)")
            XCTAssertFalse(r.recipe.plugins.contains("headroom"))
            XCTAssertTrue(r.recipe.pluginsEnabled.contains("headroom"))
            XCTAssertNil(r.base.headroomRestoreEV)
        }
        var unplugged = st
        unplugged.decodeHeadroomEV = nil
        unplugged.plugins = PluginRegistry.standard.defaultEnabled.filter { $0 != "headroom" }
        XCTAssertTrue(try render(f, unplugged).pixels == none.pixels, "enabled with Δ nil = not enabled")
    }

    func testActiveRecipeAndSplitOnARender() throws {
        let f = try fixture()
        var st = RenderSettings(mode: .explicit); st.stock = "goldenDay"
        st.exposure = 0.3; st.decodeHeadroomEV = 1
        let on = try render(f, st)
        XCTAssertEqual(on.base.exposure!, -1.0, accuracy: 1e-6, "no camera reference: decode at min(bias, 0) − Δ")
        XCTAssertEqual(on.recipe.effective.exposure, -1.0, accuracy: 1e-6)
        XCTAssertEqual(on.base.headroomRestoreEV!, 1.3, accuracy: 1e-6)
        XCTAssertTrue(on.recipe.plugins.contains("headroom"))
        XCTAssertTrue(on.recipe.decisions.contains { $0.hasPrefix("[headroom] decode exposure -1.00 EV, display restore +1.30 EV") }, "\(on.recipe.decisions)")
        XCTAssertTrue(on.recipe.decisions.contains { $0.hasPrefix("[headroom] display restore +1.30 EV") })
        var off = st; off.decodeHeadroomEV = nil
        XCTAssertFalse(try render(f, off).pixels == on.pixels, "the plugin changes the render when active")
    }

    /// C1: without `auto` nothing decides, so nothing restores (and the decode is not lowered either).
    func testNotAutoIsANoOp() throws {
        let f = try fixture()
        var st = RenderSettings(mode: .explicit); st.stock = "goldenDay"
        let plain = try render(f, st, auto: false)
        st.decodeHeadroomEV = 1
        let withDelta = try render(f, st, auto: false)
        XCTAssertTrue(plain.pixels == withDelta.pixels)
        XCTAssertNil(withDelta.base.headroomRestoreEV)
        XCTAssertFalse(withDelta.recipe.decisions.contains { $0.hasPrefix("[headroom]") })
    }

    /// C1: a restore gain the caller sets is cleared on entry.
    func testCallerSetRestoreIsIgnored() throws {
        let f = try fixture()
        var st = RenderSettings(mode: .explicit); st.stock = "goldenDay"
        let plain = try render(f, st, auto: false), plainAuto = try render(f, st)
        st.headroomRestoreEV = 1
        let a = try render(f, st, auto: false), b = try render(f, st)
        XCTAssertTrue(a.pixels == plain.pixels)
        XCTAssertTrue(b.pixels == plainAuto.pixels)
        XCTAssertNil(a.base.headroomRestoreEV); XCTAssertNil(b.base.headroomRestoreEV)
    }

    /// C2: set but unplugged = a recipe note and the same pixels.
    func testUnpluggedSaysSoAndChangesNothing() throws {
        let f = try fixture()
        var st = RenderSettings(mode: .explicit); st.stock = "goldenDay"
        st.plugins = PluginRegistry.standard.defaultEnabled.filter { $0 != "headroom" }
        let plain = try render(f, st)
        st.decodeHeadroomEV = 1
        let set = try render(f, st)
        XCTAssertTrue(plain.pixels == set.pixels)
        XCTAssertTrue(set.recipe.decisions.contains("decodeHeadroomEV set but plugin headroom is off: ignored"), "\(set.recipe.decisions)")
        XCTAssertFalse(plain.recipe.decisions.contains { $0.contains("decodeHeadroomEV") })
    }
}
#endif
