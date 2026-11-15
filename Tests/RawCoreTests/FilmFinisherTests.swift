#if canImport(CoreImage)
import CoreImage
import XCTest
@testable import RawCore

/// Film finishing on synthetic images (no RAW needed).
final class FilmFinisherTests: XCTestCase {
    let renderer = Renderer()

    func flat(_ w: Int, _ h: Int, _ v: CGFloat) -> CIImage {
        CIImage(color: CIColor(red: v, green: v, blue: v, colorSpace: Renderer.linearP3)!).cropped(to: CGRect(x: 0, y: 0, width: w, height: h))
    }

    func lumaStats(_ img: LinearImage) -> (mean: Double, std: Double) {
        let y = img.displayLuminance().map(Double.init)
        let m = y.reduce(0, +) / Double(y.count)
        return (m, sqrt(y.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Double(y.count)))
    }

    func testGrainIsDeterministicSeededAndMeanPreserving() throws {
        let base = flat(400, 300, 0.18)
        let f = FilmFinish(grainAmount: 0.6, grainSize: 0.5, grainSeed: 7)
        let a = try renderer.linearImage(FilmFinisher.apply(base, f))
        let b = try renderer.linearImage(FilmFinisher.apply(base, f))
        XCTAssertEqual(a.pixels, b.pixels, "same seed, same grain")
        var f2 = f; f2.grainSeed = 8
        XCTAssertNotEqual(a.pixels, try renderer.linearImage(FilmFinisher.apply(base, f2)).pixels, "other seed, other grain")
        let s = lumaStats(a)
        XCTAssertEqual(s.mean, 0.18, accuracy: 0.18 * 0.03, "grain must not shift exposure")
        XCTAssertGreaterThan(s.std, 0.002, "grain is visible")
        XCTAssertEqual(a.pixels[0], a.pixels[1], accuracy: 1e-6, "monochrome grain: r == g")
    }

    /// Regression: grain showed up as sparse black dots. The multiplier must stay within 1 ± 0.375 * amount.
    func testGrainHasNoOutlierDots() throws {
        for amount: Float in [0.45, 0.7, 1.0] {
            let out = try renderer.linearImage(FilmFinisher.apply(flat(800, 600, 0.5), FilmFinish(grainAmount: amount, grainSize: 0.3, grainSeed: 11)))
            let y = out.displayLuminance()
            let lo = Double(y.min()!) / 0.5, hi = Double(y.max()!) / 0.5
            print("[grain-range] amount \(amount): multiplier \(lo) ... \(hi)")
            let bound = 0.375 * Double(amount) * (1 - 0.8 * 0.5) + 1e-3   // w at Y 0.5 is 0.6
            XCTAssertGreaterThanOrEqual(lo, 1 - 0.375 * Double(amount) - 1e-3, "no black dots")
            XCTAssertLessThanOrEqual(hi, 1 + 0.375 * Double(amount) + 1e-3)
            _ = bound
        }
    }

    /// The point of sizing grain by the short edge: a 2x larger render, viewed at the same size, has the same grain.
    func testGrainLooksTheSameAtAnyResolution() throws {
        let f = FilmFinish(grainAmount: 0.6, grainSize: 0.4, grainSeed: 3)
        let small = try renderer.linearImage(FilmFinisher.apply(flat(600, 400, 0.18), f))
        let large = try renderer.linearImage(FilmFinisher.apply(flat(1200, 800, 0.18), f)).downsampled(by: 2)
        let s = lumaStats(small).std, l = lumaStats(large).std
        print("[grain] std at 600x400: \(s), at 1200x800 viewed at 600x400: \(l)")
        XCTAssertEqual(l / s, 1, accuracy: 0.3)
    }

    func testGrainFadesTowardWhite() throws {
        let f = FilmFinish(grainAmount: 0.6, grainSize: 0.5, grainSeed: 5)
        let dark = lumaStats(try renderer.linearImage(FilmFinisher.apply(flat(300, 300, 0.10), f)))
        let bright = lumaStats(try renderer.linearImage(FilmFinisher.apply(flat(300, 300, 0.85), f)))
        XCTAssertLessThan(bright.std / bright.mean, dark.std / dark.mean, "relative grain is weaker in highlights")
    }

    func testHalationGlowsRedAroundBrightAreas() throws {
        let lamp = CIImage(color: CIColor(red: 1, green: 1, blue: 1, colorSpace: Renderer.linearP3)!)
            .cropped(to: CGRect(x: 180, y: 130, width: 40, height: 40))
        let scene = lamp.composited(over: flat(400, 300, 0.02))
        let out = try renderer.linearImage(FilmFinisher.apply(scene, FilmFinish(halationAmount: 0.6, halationThreshold: 0.7, halationRadius: 3)))
        let before = try renderer.linearImage(scene)
        let i = (150 * 400 + 235) * 3  // 15 px right of the lamp
        XCTAssertGreaterThan(out.pixels[i], before.pixels[i] + 0.01, "glow next to the lamp")
        XCTAssertGreaterThan(out.pixels[i], out.pixels[i + 1], "red > green")
        XCTAssertGreaterThan(out.pixels[i + 1], out.pixels[i + 2], "green > blue")
        XCTAssertEqual(out.pixels[3], before.pixels[3], accuracy: 1e-4, "far corner untouched")
    }

    /// qualityGuard on synthetic frames: a finish that blows the frame up is blended back; a gentle one is untouched.
    func testQualityGuardBlendsBackOnlyWhenNeeded() throws {
        let renderer = Renderer()
        let base = flat(320, 240, 0.18)
        var ctx = PluginRenderContext(renderer: renderer, decodeBase: { base })
        ctx.lookBase = base
        let plugin = QualityGuardPlugin()
        // Gentle finish (+10 %): passes, untouched, no recipe line.
        let gentle = base.applyingFilter("CIColorMatrix", parameters: ["inputRVector": CIVector(x: 1.1, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: 1.1, z: 0, w: 0), "inputBVector": CIVector(x: 0, y: 0, z: 1.1, w: 0)])
        let (g, gWhy) = try plugin.afterFinish(gentle, settings: .explicit, finish: nil, ctx: ctx)
        XCTAssertTrue(gWhy.isEmpty)
        XCTAssertEqual(try renderer.linearImage(g).pixels[0], try renderer.linearImage(gentle).pixels[0], accuracy: 1e-4)
        // Harsh finish (x2, +1 EV): blended back, logged, ends nearer the base.
        let harsh = base.applyingFilter("CIColorMatrix", parameters: ["inputRVector": CIVector(x: 2, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: 2, z: 0, w: 0), "inputBVector": CIVector(x: 0, y: 0, z: 2, w: 0)])
        let (h, hWhy) = try plugin.afterFinish(harsh, settings: .explicit, finish: nil, ctx: ctx)
        XCTAssertEqual(hWhy.count, 1); XCTAssertTrue(hWhy[0].contains("median"), hWhy[0])
        let y = try renderer.linearImage(h).pixels[1]
        XCTAssertLessThan(y, 0.36 - 0.02); XCTAssertGreaterThan(y, 0.18)
        // Given strength (preview → final): applied without measuring.
        var st = RenderSettings.explicit; st.qualityGuardStrength = 0.5
        let (f, fWhy) = try plugin.afterFinish(harsh, settings: st, finish: nil, ctx: ctx)
        XCTAssertTrue(fWhy[0].contains("not re-measured"))
        XCTAssertEqual(try renderer.linearImage(f).pixels[1], 0.27, accuracy: 0.01, "half way between 0.18 and 0.36 (linear)")
        // Structured result: measured runs report the strength and the number of measuring renders; a given strength measures nothing.
        let r1 = QualityGuardReport(); var c1 = ctx; c1.guardReport = r1
        _ = try plugin.afterFinish(gentle, settings: .explicit, finish: nil, ctx: c1)
        XCTAssertEqual(r1.strength, 1); XCTAssertEqual(r1.measures, 2)
        let r2 = QualityGuardReport(); var c2 = ctx; c2.guardReport = r2
        _ = try plugin.afterFinish(harsh, settings: .explicit, finish: nil, ctx: c2)
        XCTAssertEqual(r2.strength, 0.5); XCTAssertGreaterThan(r2.measures, 2)
        let r3 = QualityGuardReport(); var c3 = ctx; c3.guardReport = r3
        _ = try plugin.afterFinish(harsh, settings: st, finish: nil, ctx: c3)
        XCTAssertEqual(r3.strength, 0.5); XCTAssertEqual(r3.measures, 0, "final with a given strength: zero extra renders")
        st.qualityGuardStrength = 1
        let r4 = QualityGuardReport(); var c4 = ctx; c4.guardReport = r4
        let (same, sameWhy) = try plugin.afterFinish(harsh, settings: st, finish: nil, ctx: c4)
        XCTAssertTrue(sameWhy.isEmpty); XCTAssertEqual(r4.strength, 1); XCTAssertEqual(r4.measures, 0)
        XCTAssertEqual(try renderer.linearImage(same).pixels[1], 0.36, accuracy: 0.01, "strength 1 returns the finish unchanged")
    }

    func testPluginRegistryUnplugs() throws {
        var st = RenderSettings.explicit
        let ids = try PluginRegistry.standard.active(for: st).map(\.id)
        XCTAssertEqual(Array(ids.prefix(6)), ["highlightRecovery", "headroom", "cameraMatch", "vignette", "logLook", "filmDevelop"])
        XCTAssertTrue(ids.contains("lightLeak"))
        st.plugins = []
        XCTAssertTrue(try PluginRegistry.standard.active(for: st).isEmpty)
        st.plugins = ["vignette"]
        XCTAssertEqual(try PluginRegistry.standard.active(for: st).map(\.id), ["vignette"])
        st.plugins = ["nope"]
        XCTAssertThrowsError(try PluginRegistry.standard.active(for: st))
        XCTAssertTrue(try PluginRegistry.none.active(for: .explicit).isEmpty)
        // Vignette plugin: unplugged = untouched image.
        let img = flat(200, 150, 0.5)
        let (v, why) = try VignettePlugin().afterFinish(img, settings: .explicit, finish: FilmFinish(vignette: 0.5),
                                                        ctx: PluginRenderContext(renderer: renderer, decodeBase: { img }))
        XCTAssertFalse(why.isEmpty)
        XCTAssertLessThan(try renderer.linearImage(v).pixels[0], 0.49)
    }

    func testVignetteDarkensCornersOnly() throws {
        let out = try renderer.linearImage(FilmFinisher.vignette(flat(400, 300, 0.5), 0.5))
        let centre = out.pixels[(150 * 400 + 200) * 3], corner = out.pixels[(2 * 400 + 2) * 3]
        XCTAssertEqual(Double(centre), 0.5, accuracy: 0.02)
        XCTAssertLessThan(corner, centre - 0.03)
    }
}
#endif

