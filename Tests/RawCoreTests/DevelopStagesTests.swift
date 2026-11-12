#if canImport(CoreImage)
import CoreImage
import XCTest
@testable import RawCore

/// Capture-time analysis stored next to the DNG, the two develop stages, and how often a file is opened.
final class DevelopStagesTests: XCTestCase {
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    func original() throws -> URL {
        let dir = Self.root.appendingPathComponent("originals")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        guard let n = names.filter({ $0.lowercased().hasSuffix(".dng") }).sorted().first else { throw XCTSkip("no DNGs in originals/") }
        return dir.appendingPathComponent(n)
    }

    func tempDir() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("rawcore-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: d) }
        return d
    }

    func maxDiff(_ a: CIImage, _ b: CIImage, _ r: Renderer) throws -> Float {
        let w = Int(min(a.extent.width, b.extent.width)), h = Int(min(a.extent.height, b.extent.height))
        let la = try r.linearImage(a, size: (w, h)), lb = try r.linearImage(b, size: (w, h))
        return zip(la.pixels, lb.pixels).map { abs($0 - $1) }.max() ?? 0
    }

    /// One filter per decode: file facts are read once and cached (was 7-9 opens for an analysis + render).
    func testOneFilterPerDecode() throws {
        let url = try original()
        let dev = Developer(plugins: .none)   // no EDR analysis decode, no highlightRecovery base decode
        let scale = try dev.decoder.scaleFactor(url: url, longEdge: 256)   // reads the file facts: 1 filter
        XCTAssertEqual(dev.decoder.filtersCreated, 1)
        _ = try dev.develop(url: url, settings: .explicit, auto: true, scaleFactor: scale)
        XCTAssertEqual(dev.decoder.filtersCreated, 1 + 2 + 1, "2 analysis decodes (scene-linear 512, Apple 1024) + 1 render, no extra inspect")
        _ = try dev.develop(url: url, settings: .explicit, auto: false, scaleFactor: scale)
        XCTAssertEqual(dev.decoder.filtersCreated, 5, "a second render of a known file opens only its own filter")
    }

    /// Stored analysis: JSON + mask round trip, used by develop as is (same pixels), re-made when it no longer fits.
    func testStoredAnalysisRoundTripAndReuse() throws {
        let url = try original()
        let dev = Developer()
        let an = try dev.analyze(url: url)
        let dir = try tempDir()
        try an.write(to: dir, renderer: dev.renderer)
        let back = try Developer.Analysis.read(from: dir)
        XCTAssertEqual(back.context, an.context)
        XCTAssertEqual(back.defaults, an.defaults)
        XCTAssertEqual(back.decoderVersion, an.decoderVersion)
        XCTAssertEqual(back.sourceFile, url.lastPathComponent)
        if let m = an.personMask {
            let stored = try XCTUnwrap(back.personMask, "mask written and read back")
            XCTAssertEqual(dev.renderer.areaMean(stored), dev.renderer.areaMean(m), accuracy: 0.01)
        }

        let scale = try dev.decoder.scaleFactor(url: url, longEdge: 256)
        var st = RenderSettings.explicit; st.stock = "warm400"
        let fresh = try dev.develop(url: url, settings: st, auto: true, scaleFactor: scale, analysis: an)
        let opens = dev.decoder.filtersCreated
        let stored = try dev.develop(url: url, settings: st, auto: true, scaleFactor: scale, analysis: back)
        XCTAssertTrue(stored.recipe.decisions.contains { $0.hasPrefix("stored analysis used") }, "\(stored.recipe.decisions)")
        XCTAssertLessThanOrEqual(dev.decoder.filtersCreated - opens, 2, "no analysis decodes when the stored one fits")
        XCTAssertLessThan(try maxDiff(stored.image, fresh.image, dev.renderer), 2e-3)

        var old = back; old.decoderVersion = "6"
        XCTAssertNotNil(old.staleReason(url: url, decoderVersion: try XCTUnwrap(an.decoderVersion), plugins: []))
        let redone = try dev.develop(url: url, settings: st, auto: true, scaleFactor: scale, analysis: old)
        XCTAssertTrue(redone.recipe.decisions.contains { $0.hasPrefix("stored analysis not used (decoder version 6") }, "\(redone.recipe.decisions)")
        var noSchema = back; noSchema.schema = nil
        XCTAssertNotNil(noSchema.staleReason(url: url, decoderVersion: try XCTUnwrap(an.decoderVersion), plugins: []))
    }

    /// The HEIC's histograms stored at analysis time replace the HEIC file: same cameraMatch decisions without it.
    func testStoredHEICHistogramsReplaceTheFile() throws {
        let docs = Self.root.appendingPathComponent("docs")
        let dirs = ((try? FileManager.default.contentsOfDirectory(atPath: docs.path)) ?? []).sorted().map { docs.appendingPathComponent($0) }
            .filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent("apple.heic").path)
                      && FileManager.default.fileExists(atPath: $0.appendingPathComponent("capture.dng").path) }
        guard let d = dirs.first else { throw XCTSkip("no device pairs in docs/") }
        let dng = d.appendingPathComponent("capture.dng"), heic = d.appendingPathComponent("apple.heic").path
        let dev = Developer()
        let scale = try dev.decoder.scaleFactor(url: dng, longEdge: 512)
        let plain = try dev.analyze(url: dng)
        var withFile = RenderSettings.explicit; withFile.cameraReference = heic
        let a = try dev.develop(url: dng, settings: withFile, auto: true, scaleFactor: scale, analysis: plain)

        let stored = try dev.analyze(url: dng, cameraReference: heic)
        XCTAssertEqual(stored.context.cameraReferenceHistogram?.count, stored.context.lumaHistogram?.count)
        XCTAssertEqual(stored.context.cameraReferenceHistogramFine?.count, CameraMatchPlugin.fineBins)
        let b = try dev.develop(url: dng, settings: .explicit, auto: true, scaleFactor: scale, analysis: stored)   // no HEIC path
        XCTAssertTrue(b.recipe.plugins.contains("cameraMatch"))
        XCTAssertTrue(b.recipe.decisions.contains { $0.contains("(stored analysis,") }, "\(b.recipe.decisions)")
        XCTAssertEqual(b.recipe.effective.exposure, a.recipe.effective.exposure, accuracy: 1e-4)
        XCTAssertEqual(b.recipe.effective.boostShadowAmount, a.recipe.effective.boostShadowAmount, accuracy: 1e-4)
        XCTAssertLessThan(try maxDiff(b.image, a.image, dev.renderer), 2e-3)
    }

    /// A base finished with another stock equals a full develop with that stock (no second decode needed).
    func testFinishBaseWithAnotherStock() throws {
        let url = try original()
        let dev = Developer()
        let an = try dev.analyze(url: url)
        let scale = try dev.decoder.scaleFactor(url: url, longEdge: 256)
        var warm = RenderSettings.explicit; warm.stock = "warm400"
        var night = RenderSettings.explicit; night.stock = "night800"
        var base = try dev.developBase(url: url, settings: warm, auto: true, scaleFactor: scale, analysis: an)
        let opens = dev.decoder.filtersCreated
        let first = try dev.finish(base)
        base.settings.stock = "night800"
        let relooked = try dev.finish(base)
        XCTAssertEqual(dev.decoder.filtersCreated, opens, "finishing never decodes")
        XCTAssertEqual(relooked.recipe.settings.stock, "night800")
        let full = try dev.develop(url: url, settings: night, auto: true, scaleFactor: scale, analysis: an)
        XCTAssertLessThan(try maxDiff(relooked.image, full.image, dev.renderer), 2e-3)
        XCTAssertGreaterThan(try maxDiff(relooked.image, first.image, dev.renderer), 0.01, "the stock really changed")
    }

    /// filmDevelop: no stock = no-op, `plugins = []` leaves the core untouched, a roll stock lowers sharpness and logs it,
    /// and finishing a base with another develop profile says so.
    func testFilmDevelopPlugin() throws {
        let url = try original()
        let dev = Developer()
        let an = try dev.analyze(url: url)
        let scale = try dev.decoder.scaleFactor(url: url, longEdge: 256)
        var plain = RenderSettings.explicit
        let none = try dev.developBase(url: url, settings: plain, auto: true, scaleFactor: scale, analysis: an)
        XCTAssertFalse(none.recipe.plugins.contains("filmDevelop"))
        XCTAssertFalse(none.recipe.decisions.contains { $0.contains("[filmDevelop]") })

        plain.stock = "rr-sao-mai-200"
        let on = try dev.developBase(url: url, settings: plain, auto: true, scaleFactor: scale, analysis: an)
        XCTAssertEqual(on.developedFor, "rr-sao-mai-200: iso<400")
        let d = on.recipe.defaults.sharpnessAmount
        if on.recipe.support.sharpness, d > 0.55 {
            XCTAssertLessThan(on.recipe.effective.sharpnessAmount, on.recipe.defaults.sharpnessAmount)
            XCTAssertTrue(on.recipe.decisions.contains { $0.hasPrefix("[filmDevelop] develop iso<400: sharpness") })
        }
        var off = plain; off.plugins = []
        let core = try dev.developBase(url: url, settings: off, auto: true, scaleFactor: scale, analysis: an)
        XCTAssertEqual(core.recipe.effective.sharpnessAmount, core.recipe.defaults.sharpnessAmount, "plugins = [] leaves Apple's sharpness")
        XCTAssertNil(core.developedFor)

        var b = on
        b.settings.stock = "rr-sao-hom-400"
        let out = try dev.finish(b)
        XCTAssertTrue(out.recipe.decisions.contains { $0.contains("base developed for rr-sao-mai-200: iso<400, finished as rr-sao-hom-400: iso400-1599") })
        let same = try dev.finish(on)
        XCTAssertFalse(same.recipe.decisions.contains { $0.contains("base developed for") })
    }

    /// Log curves put mid grey where their specs do; the composite cube is monotone on grey.
    func testLogCurvesAndComposite() throws {
        XCTAssertEqual(LogCurve.appleLog.encode(0.18), 0.488, accuracy: 0.005)
        XCTAssertEqual(LogCurve.sLog3.encode(0.18), 0.410, accuracy: 0.005)
        XCTAssertEqual(LogCurve.logC3.encode(0.18), 0.391, accuracy: 0.005)
        XCTAssertEqual(LogCurve.vLog.encode(0.18), 0.423, accuracy: 0.005)
        let lut = BuiltInLook.warmNegative.lut()
        let c = LogLook.composite(lut, curve: .appleLog, size: 17)
        var last: Float = -1
        for i in 0..<17 {
            let v = Float(i) / 16, o = c.apply(SIMD3(repeating: v))
            let y = 0.2 * o.x + 0.7 * o.y + 0.1 * o.z
            XCTAssertGreaterThanOrEqual(y, last - 1e-4, "grey ramp monotone at \(v)")
            last = y
        }
    }

    /// A LOG stock (built in code, `lookInput = .log`) goes through the logLook plugin on a scene-linear decode; a display
    /// stock never does; without a scene-linear decode the plugin leaves it to the core.
    func testLogLookPluginOnAnInCodeLogStock() throws {
        let url = try original()
        let dev = Developer()
        let scale = try dev.decoder.scaleFactor(url: url, longEdge: 256)
        var stock = FilmStock(name: "testLogLook", look: .warmNegative, lookIntensity: 1, finish: FilmFinish(), summary: "log test")
        stock.lookInput = .log(.appleLog); stock.logPrimaries = .rec2020
        let base = try dev.decoder.decode(url: url, settings: .explicit, scaleFactor: scale).image
        let linear = RenderSettings(mode: .sceneLinear)
        let ctx = PluginRenderContext(renderer: dev.renderer, decodeBase: { base }, decodeSceneLinear: {
            try dev.decoder.decode(url: url, settings: linear, scaleFactor: scale).image
        })
        let plugin = LogLookPlugin()
        let (looked, why) = try XCTUnwrap(try plugin.look(stock: stock, settings: .explicit, ctx: ctx))
        XCTAssertTrue(why.contains { $0.hasPrefix("testLogLook: LUT made for log input") }, "\(why)")
        let display = try dev.renderer.applyLook(stock.lut(), to: base, intensity: 1)
        XCTAssertGreaterThan(try maxDiff(looked, display, dev.renderer), 0.02, "log route differs from the LUT on the display base")
        var classic = stock; classic.lookInput = .display
        XCTAssertNil(try plugin.look(stock: classic, settings: .explicit, ctx: ctx), "display looks never go through logLook")
        let noLinear = PluginRenderContext(renderer: dev.renderer, decodeBase: { base })
        XCTAssertNil(try plugin.look(stock: stock, settings: .explicit, ctx: noLinear), "no scene-linear decode: left to the core")
    }

    /// MoodRoll's .mrlut format round-trips within half precision; .cube text round-trips exactly to 6 decimals.
    func testMrlutAndCubeWriterRoundTrip() throws {
        XCTAssertEqual(LUTBinaryFormat.floatToHalf(0), 0)
        XCTAssertEqual(LUTBinaryFormat.floatToHalf(1), 0x3C00)
        XCTAssertEqual(LUTBinaryFormat.floatToHalf(0.5), 0x3800)
        for v: Float in [0, 1e-6, 0.000123, 0.25, 0.333333, 0.999, 1] {
            XCTAssertEqual(LUTBinaryFormat.halfToFloat(LUTBinaryFormat.floatToHalf(v)), v, accuracy: max(v * 0.0005, 3e-8))
        }
        let lut = BuiltInLook.warmNegative.lut()
        let packed = try LUTBinaryFormat.encode(lut)
        XCTAssertEqual(packed.count, 8 + 33 * 33 * 33 * 6)
        let back = try LUTBinaryFormat.decode(packed)
        XCTAssertLessThan(zip(lut.rgba, back.rgba).map { abs($0 - $1) }.max() ?? 1, 0.00025)
        let text = try CubeLUT.parse(lut.cubeText())
        XCTAssertLessThan(zip(lut.rgba, text.rgba).map { abs($0 - $1) }.max() ?? 1, 1e-6)
        XCTAssertThrowsError(try LUTBinaryFormat.decode(Data([1, 2, 3])))
    }

    // MARK: sky mask (plugin skyMask)

    /// Deterministic noise in -1...1.
    private func noise(_ i: Int) -> Float {
        var x = UInt32(truncatingIfNeeded: i) &* 2654435761 &+ 12345
        x ^= x >> 13; x = x &* 1597334677; x ^= x >> 16
        return Float(x % 20001) / 10000 - 1
    }

    private func scene(_ w: Int, _ h: Int, _ f: (Int, Int) -> SIMD3<Float>) -> LinearImage {
        var p = [Float](repeating: 0, count: w * h * 3)
        for y in 0..<h { for x in 0..<w { let c = f(x, y); let i = (y * w + x) * 3; p[i] = c.x; p[i + 1] = c.y; p[i + 2] = c.z } }
        return LinearImage(width: w, height: h, pixels: p)
    }

    private func mean(_ r: SkyMask.Result, x: Range<Int>, y: Range<Int>) -> Float {
        var s: Float = 0
        for yy in y { for xx in x { s += r.mask[yy * r.width + xx] } }
        return s / Float(x.count * y.count)
    }

    func testSkyMaskTopConnectedBlueIsSkyAndBlueObjectBelowIsNot() {
        let w = 160, h = 120
        // Smooth blue sky gradient on the top 45 %, textured grey ground, and a smooth bright blue "car" in the lower half.
        let img = scene(w, h) { x, y in
            if y < 54 { return SIMD3(0.20 + 0.0005 * Float(y), 0.38 + 0.001 * Float(y), 0.80) }
            if (60..<100).contains(x), (80..<108).contains(y) { return SIMD3(0.15, 0.30, 0.75) }
            let n = 0.12 * self.noise(y * w + x)
            return SIMD3(0.22 + n, 0.20 + n, 0.18 + n)
        }
        let r = SkyMask.compute(sceneLinear: img)
        XCTAssertGreaterThan(mean(r, x: 10..<150, y: 4..<46), 0.9, "top-connected smooth blue is sky")
        XCTAssertLessThan(mean(r, x: 66..<94, y: 86..<102), 0.05, "a blue object in the lower half, not connected to the top, is not sky")
        XCTAssertLessThan(mean(r, x: 5..<150, y: 70..<80), 0.05, "textured ground is not sky")
        XCTAssertEqual(r.coverage, 54.0 / 120, accuracy: 0.06)
    }

    func testSkyMaskBlueCastTexturedShadeWallIsLow() {
        let w = 160, h = 120
        // A blue-cast white wall fills the frame, top included, with rough plaster / stucco texture (+-15 % per pixel).
        let img = scene(w, h) { x, y in
            let n = 0.15 * self.noise(y * w + x + 99)
            return SIMD3(0.62 + n, 0.70 + n, 0.85 + n)
        }
        let r = SkyMask.compute(sceneLinear: img)
        XCTAssertLessThan(r.coverage, 0.05, "textured shade wall must not be held like sky (coverage \(r.coverage))")
        // The same wall, perfectly smooth and top-connected, is indistinguishable from sky by pixels: only the label gate stops it.
        let smooth = scene(w, h) { _, _ in SIMD3(0.62, 0.70, 0.85) }
        XCTAssertGreaterThan(SkyMask.compute(sceneLinear: smooth).coverage, 0.5)
    }

    func testSkyMaskLabelGate() {
        XCTAssertEqual(SkyMask.gate(labels: ["sky": 0.82, "outdoor": 0.9]), .open(label: "sky", confidence: 0.82))
        XCTAssertEqual(SkyMask.gate(labels: ["mountain": 0.5, "blue_sky": 0.6]), .open(label: "blue_sky", confidence: 0.6))
        // Indoor mug / mooncake: classification exists and has no sky label -> closed with the reason.
        if case .closed(let why) = SkyMask.gate(labels: ["cup": 0.8, "indoor": 0.6]) { XCTAssertTrue(why.contains("cup 0.80"), why) } else { XCTFail("gate must be closed") }
        if case .closed = SkyMask.gate(labels: ["outdoor": 0.95, "car": 0.7]) {} else { XCTFail("outdoor alone is not a sky label") }
        if case .closed = SkyMask.gate(labels: [:]) {} else { XCTFail("empty labels = no sky label") }
        if case .unavailable = SkyMask.gate(labels: nil) {} else { XCTFail("no classification = no decision") }
    }

    func testSkyMaskBlendAndStockVariants() throws {
        // Held look applied only inside the mask: left half mask 1 -> foreground, right half 0 -> background.
        let r = Renderer()
        let fg = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: CGRect(x: 0, y: 0, width: 64, height: 32))
        let bg = CIImage(color: CIColor(red: 0, green: 0, blue: 1)).cropped(to: CGRect(x: 0, y: 0, width: 64, height: 32))
        var m = [Float](repeating: 0, count: 8 * 4)
        for y in 0..<4 { for x in 0..<4 { m[y * 8 + x] = 1 } }
        let out = try r.linearImage(r.blend(fg, over: bg, mask: r.maskImage(m, width: 8, height: 4), feather: 0.001))
        XCTAssertGreaterThan(out.pixels[(16 * 64 + 5) * 3], 0.8, "inside the mask: held look (sRGB red = 0.82 in linear P3)")
        XCTAssertLessThan(out.pixels[(16 * 64 + 5) * 3 + 2], 0.05)
        XCTAssertGreaterThan(out.pixels[(16 * 64 + 58) * 3 + 2], 0.9, "outside the mask: look without the hold")
        XCTAssertLessThan(out.pixels[(16 * 64 + 58) * 3], 0.05)
        // Stocks with a hold have an unheld variant that differs only on blue; the others have none.
        let soft = try XCTUnwrap(FilmStock.named("PRESET_26_SOFT400")), sp = try XCTUnwrap(FilmStock.named("softPortrait"))
        XCTAssertGreaterThan(soft.skyHoldAmount, 0); XCTAssertGreaterThan(sp.skyHoldAmount, 0)
        XCTAssertNil(try XCTUnwrap(FilmStock.named("goldenDay")).lutWithoutSkyHold())
        func dist(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float { let d = a - b; return (d * d).sum().squareRoot() }
        for s in [soft, sp] {
            let held = s.lut(), plain = try XCTUnwrap(s.lutWithoutSkyHold(size: s.lut().size))
            XCTAssertEqual(held.size, plain.size)
            let sky = SIMD3<Float>(0.45, 0.62, 0.92), skin = SIMD3<Float>(0.85, 0.62, 0.52)
            XCTAssertGreaterThan(dist(held.apply(sky), plain.apply(sky)), 0.02, "\(s.name): hold changes bright blue")
            XCTAssertLessThan(dist(held.apply(skin), plain.apply(skin)), 0.004, "\(s.name): hold leaves skin alone")
        }
    }

    /// A light leak is exposure on the emulsion: it is drawn before grain, so the grain sits on top (user, 2026-11-11).
    func testLightLeakRunsBeforeGrain() throws {
        let url = try original()
        let dev = Developer()
        let scale = try dev.decoder.scaleFactor(url: url, longEdge: 256)
        var st = RenderSettings(mode: .explicit)
        st.stock = "rr-la-phong-100"; st.rollID = "order-test"; st.rollFrameIndex = 1; st.rollFrameCount = 36
        let out = try dev.develop(url: url, settings: st, auto: false, scaleFactor: scale)
        let d = out.recipe.decisions
        let leak = try XCTUnwrap(d.firstIndex { $0.hasPrefix("[lightLeak]") && $0.contains("screen in linear light") }, "frame 1 always leaks")
        let grain = try XCTUnwrap(d.firstIndex { $0.hasPrefix("film finish") })
        XCTAssertLessThan(leak, grain, "leak before grain")
        XCTAssertTrue(out.recipe.plugins.contains("lightLeak"))
    }
}
#endif
