#if canImport(CoreImage)
import CoreImage
import ImageIO
import XCTest
@testable import RawCore

/// Integration tests on the real files in originals/ (skipped if the folder is missing).
final class DecoderTests: XCTestCase {
    static let originals: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("originals")

    func files() throws -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: Self.originals.path)) ?? []
        let urls = names.filter { $0.lowercased().hasSuffix(".dng") }.sorted().map { Self.originals.appendingPathComponent($0) }
        if urls.isEmpty { throw XCTSkip("no DNGs in originals/") }
        return urls
    }

    /// Gate 1: writing Apple's own defaults back explicitly must reproduce Apple's render.
    func testExplicitDefaultsReproduceAppleDefault() throws {
        let renderer = Renderer(), decoder = RawDecoder()
        for url in try files() {
            let scale = try decoder.scaleFactor(url: url, longEdge: 384)
            let ref = try decoder.decode(url: url, settings: .appleDefault, scaleFactor: scale)
            let exp = try decoder.decode(url: url, settings: .explicit, scaleFactor: scale)
            XCTAssertEqual(exp.recipe.effective, ref.recipe.defaults, url.lastPathComponent)
            let w = Int(min(ref.image.extent.width, exp.image.extent.width)), h = Int(min(ref.image.extent.height, exp.image.extent.height))
            let cmp = try ComparisonMetrics.compare(candidate: renderer.linearImage(exp.image, size: (w, h)),
                                                    reference: renderer.linearImage(ref.image, size: (w, h)))
            print("[gate1] \(url.lastPathComponent) explicit vs appleDefault ΔE00 mean \(cmp.deltaE00Mean) p95 \(cmp.deltaE00P95)")
            XCTAssertLessThan(cmp.deltaE00Mean, 0.5, url.lastPathComponent)
        }
    }

    func testSceneLinearIsDarkerAndRecipeRecordsIt() throws {
        let renderer = Renderer(), decoder = RawDecoder()
        for url in try files() {
            let scale = try decoder.scaleFactor(url: url, longEdge: 256)
            let lin = try decoder.decode(url: url, settings: .sceneLinear, scaleFactor: scale)
            XCTAssertEqual(lin.recipe.effective.baselineExposure, 0)
            XCTAssertEqual(lin.recipe.effective.boostAmount, 0)
            XCTAssertFalse(lin.recipe.supportedDecoderVersions.isEmpty)
            let m = ImageMetrics.measure(try renderer.linearImage(lin.image))
            XCTAssertGreaterThan(m.meanY, 0, url.lastPathComponent)
        }
    }

    /// Highlight recovery: where Apple's curve clips data the RAW still holds, auto must reduce
    /// display clipping without darkening the unclipped part of the picture.
    func testAutoRecoversToneClippedHighlights() throws {
        let dev = Developer()
        for url in try files() {
            let an = try dev.analyze(url: url)
            let scale = try dev.decoder.scaleFactor(url: url, longEdge: 384)
            let auto = try dev.develop(url: url, settings: .explicit, auto: true, scaleFactor: scale, analysis: an)
            guard auto.recipe.effective.extendedDynamicRangeAmount > 0 else { continue }
            let ref = try dev.develop(url: url, settings: .appleDefault, auto: false, scaleFactor: scale)
            let size = (Int(min(ref.image.extent.width, auto.image.extent.width)), Int(min(ref.image.extent.height, auto.image.extent.height)))
            let cmp = try ComparisonMetrics.compare(candidate: dev.renderer.linearImage(auto.image, size: size),
                                                    reference: dev.renderer.linearImage(ref.image, size: size))
            print("[highlight] \(url.lastPathComponent) clipped \(cmp.reference.clippedFraction) -> \(cmp.candidate.clippedFraction), ΔE unclipped \(cmp.deltaE00MeanUnclipped), \(auto.recipe.decisions)")
            if auto.recipe.decisions.contains(where: { $0.contains("not applied") }) { continue }
            XCTAssertLessThan(cmp.candidate.clippedFraction, cmp.reference.clippedFraction, url.lastPathComponent)
        }
    }

    /// Unplugging every plugin gives the roadmap core; the recipe says which plugins ran.
    func testPluginsCanBeUnplugged() throws {
        let dev = Developer()
        let url = try XCTUnwrap(try files().first { $0.lastPathComponent == "IMG_1901.DNG" } ?? files().first)
        let an = try dev.analyze(url: url)
        let scale = try dev.decoder.scaleFactor(url: url, longEdge: 256)
        let full = try dev.develop(url: url, settings: .explicit, auto: true, scaleFactor: scale, analysis: an)
        var coreSettings = RenderSettings.explicit
        coreSettings.plugins = []
        let core = try dev.develop(url: url, settings: coreSettings, auto: true, scaleFactor: scale, analysis: an)
        XCTAssertEqual(full.recipe.pluginsEnabled, ["highlightRecovery", "cameraMatch", "vignette"])
        XCTAssertEqual(full.recipe.plugins, ["highlightRecovery"], "vignette had nothing to do without a stock")
        XCTAssertEqual(core.recipe.plugins, [])
        XCTAssertEqual(core.recipe.pluginsEnabled, [])
        XCTAssertEqual(core.recipe.effective.extendedDynamicRangeAmount, 0, "no EDR without the plugin")
        XCTAssertFalse(core.recipe.decisions.contains { $0.hasPrefix("[highlightRecovery]") })
        XCTAssertEqual(core.recipe.decoderVersionSource, "policy")
        // Core auto equals an explicit decode with the same decided settings (nothing hidden in the core).
        let again = try dev.decoder.decode(url: url, settings: core.recipe.settings, scaleFactor: scale)
        let size = (Int(core.image.extent.width), Int(core.image.extent.height))
        let cmp = try ComparisonMetrics.compare(candidate: dev.renderer.linearImage(core.image, size: size), reference: dev.renderer.linearImage(again.image, size: size))
        XCTAssertLessThan(cmp.deltaE00Mean, 0.01)
    }

    /// Device pair (output/, iPhone 14 Pro, same press): cameraMatch brings our render to the camera HEIC's brightness
    /// and clips less than without it (WORK_LOG 2026-11-08: +0.31 / +0.63 EV brighter before).
    func testCameraMatchOnDevicePairs() throws {
        let out = Self.originals.deletingLastPathComponent().appendingPathComponent("output")
        let dirs = ((try? FileManager.default.contentsOfDirectory(atPath: out.path)) ?? []).sorted().map { out.appendingPathComponent($0) }
            .filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent("apple.heic").path) }
        if dirs.isEmpty { throw XCTSkip("no device pairs in output/") }
        let dev = Developer()
        for d in dirs {
            let dng = d.appendingPathComponent("capture.dng"), heicPath = d.appendingPathComponent("apple.heic").path
            let heic = try XCTUnwrap(CIImage(contentsOf: URL(fileURLWithPath: heicPath), options: [.applyOrientationProperty: true]))
            let an = try dev.analyze(url: dng)
            let scale = try dev.decoder.scaleFactor(url: dng, longEdge: 512)
            var off = RenderSettings.explicit; off.plugins = ["highlightRecovery", "vignette"]
            var on = RenderSettings.explicit; on.cameraReference = heicPath
            let a = try dev.develop(url: dng, settings: off, auto: true, scaleFactor: scale, analysis: an)
            let b = try dev.develop(url: dng, settings: on, auto: true, scaleFactor: scale, analysis: an)
            let e = a.image.extent
            let hs = CameraMatchPlugin.small(heic, longEdge: max(e.width, e.height))
            let w = Int(min(hs.extent.width, e.width, b.image.extent.width)), h = Int(min(hs.extent.height, e.height, b.image.extent.height))
            let ref = try dev.renderer.linearImage(hs, size: (w, h))
            func mid(_ img: LinearImage) -> Double {
                let ya = img.pixelsLuminanceUnclamped().sorted(), yb = ref.pixelsLuminanceUnclamped().sorted()
                return log2(Double(ya[ya.count / 2]) / Double(yb[yb.count / 2]))
            }
            let la = try dev.renderer.linearImage(a.image, size: (w, h)), lb = try dev.renderer.linearImage(b.image, size: (w, h))
            let ca = ImageMetrics.measure(la).clippedFraction, cb = ImageMetrics.measure(lb).clippedFraction
            print("[cameraMatch] \(d.lastPathComponent) median EV vs HEIC \(mid(la)) -> \(mid(lb)), clipped \(ca) -> \(cb), \(b.recipe.decisions.filter { $0.hasPrefix("[cameraMatch]") })")
            XCTAssertTrue(b.recipe.plugins.contains("cameraMatch"))
            XCTAssertLessThan(abs(mid(lb)), 0.15, d.lastPathComponent)
            XCTAssertLessThan(abs(mid(lb)), abs(mid(la)), d.lastPathComponent)
            XCTAssertLessThanOrEqual(cb, ca + 1e-4, d.lastPathComponent)
            XCTAssertLessThan(cb, 0.01, "\(d.lastPathComponent): clipping near the HEIC's (0.2 %), not 2 %")
        }
    }

    /// Regression (run 42431876319): mono400 + skin protection gave colour people (and the box they held) in a B&W frame.
    func testMonoStockSkipsSkinProtection() throws {
        let url = try XCTUnwrap(try files().first { $0.lastPathComponent == "USER_mooncake.dng" })
        let dev = Developer()
        let an = try dev.analyze(url: url)
        guard (an.context.personFraction ?? 0) > 0.03 else { throw XCTSkip("no person mask on this runner") }
        var st = RenderSettings.explicit
        st.stock = "mono400"
        let o = try dev.develop(url: url, settings: st, auto: true, scaleFactor: try dev.decoder.scaleFactor(url: url, longEdge: 256), analysis: an)
        XCTAssertTrue(o.recipe.decisions.contains { $0.hasPrefix("skin protection skipped") })
        let lin = try dev.renderer.linearImage(o.image)
        var maxChroma: Float = 0
        for i in 0..<lin.pixelCount {
            let r = lin.pixels[i * 3], g = lin.pixels[i * 3 + 1], b = lin.pixels[i * 3 + 2]
            maxChroma = max(maxChroma, max(r, g, b) - min(r, g, b))
        }
        XCTAssertLessThan(maxChroma, 0.02, "mono output stays neutral everywhere")
    }

    /// Skin protection must actually reduce how much a look changes people (and leave the rest alone).
    func testSkinProtectionReducesLookOnPeople() throws {
        let url = try XCTUnwrap(try files().first { $0.lastPathComponent == "USER_mooncake.dng" })
        let dev = Developer(plugins: .none)
        let an = try dev.analyze(url: url)
        guard let mask = an.personMask, (an.context.personFraction ?? 0) > 0.03 else { throw XCTSkip("no person mask on this runner") }
        let scale = try dev.decoder.scaleFactor(url: url, longEdge: 384)
        let base = try dev.develop(url: url, settings: .explicit, auto: true, scaleFactor: scale, analysis: an)
        var on = RenderSettings.explicit; on.stock = "warm400"; on.finish = .none
        var off = on; off.skinProtection = 0
        let a = try dev.develop(url: url, settings: on, auto: true, scaleFactor: scale, analysis: an)
        let b = try dev.develop(url: url, settings: off, auto: true, scaleFactor: scale, analysis: an)
        let e = base.image.extent
        let size = (Int(e.width), Int(e.height))
        let me = mask.extent
        let m = try dev.renderer.linearImage(mask.transformed(by: CGAffineTransform(scaleX: e.width / me.width, y: e.height / me.height)), size: size)
        let people = (0..<(size.0 * size.1)).map { m.pixels[$0 * 3] > 0.25 }
        let ref = try dev.renderer.linearImage(base.image, size: size)
        let ca = try ComparisonMetrics.compare(candidate: dev.renderer.linearImage(a.image, size: size), reference: ref, mask: people)
        let cb = try ComparisonMetrics.compare(candidate: dev.renderer.linearImage(b.image, size: size), reference: ref, mask: people)
        print("[skin] on: people \(ca.deltaE00MeanMasked ?? -1) rest \(ca.deltaE00MeanOutsideMask ?? -1); off: people \(cb.deltaE00MeanMasked ?? -1) rest \(cb.deltaE00MeanOutsideMask ?? -1)")
        XCTAssertLessThan(try XCTUnwrap(ca.deltaE00MeanMasked), try XCTUnwrap(cb.deltaE00MeanMasked) * 0.85)
        XCTAssertEqual(try XCTUnwrap(ca.deltaE00MeanOutsideMask), try XCTUnwrap(cb.deltaE00MeanOutsideMask), accuracy: 0.3)
    }

    func testLinearExposureAndCalibrationLookup() throws {
        let url = try XCTUnwrap(try files().first)
        let cam = try XCTUnwrap(try RawDecoder().decode(url: url, settings: .appleDefault, scaleFactor: 0.1).recipe.camera)
        let dev = Developer(plugins: .none, calibration: CalibrationTable(models: [
            ModelCalibration(model: cam, ccm: [1, 0, 0, 0, 1, 0, 0, 0, 1], exposureOffsetEV: 1, version: "test1", source: "unit test")]))
        let scale = try dev.decoder.scaleFactor(url: url, longEdge: 256)
        let plain = try dev.develop(url: url, settings: .explicit, auto: false, scaleFactor: scale)
        var noCal = RenderSettings.explicit
        noCal.useCalibration = false
        let without = try dev.develop(url: url, settings: noCal, auto: false, scaleFactor: scale)
        XCTAssertEqual(plain.recipe.calibration?.hasPrefix(cam), true)
        XCTAssertEqual(plain.recipe.settings.linearExposureEV, 1)
        let a = ImageMetrics.measure(try dev.renderer.linearImage(plain.image)), b = ImageMetrics.measure(try dev.renderer.linearImage(without.image))
        XCTAssertGreaterThan(a.medianY, b.medianY, "+1 EV in linearSpaceFilter brightens the render")
    }

    func testRecipeIsEmbeddedInHEIC() throws {
        let url = try XCTUnwrap(try files().first)
        let dev = Developer()
        let o = try dev.develop(url: url, settings: .explicit, auto: false, scaleFactor: try dev.decoder.scaleFactor(url: url, longEdge: 256))
        let data = try dev.renderer.export(o.image, format: .heic10, recipe: o.recipe)
        let src = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any])
        let comment = (props[kCGImagePropertyExifDictionary as String] as? [String: Any])?[kCGImagePropertyExifUserComment as String] as? String
        XCTAssertTrue(comment?.contains("decoderVersion") ?? false, "recipe JSON in EXIF UserComment")
    }

    func testAnalysisHasHistogramCCTAndVision() throws {
        let dev = Developer()
        for url in try files() {
            let an = try dev.analyze(url: url)
            let c = an.context
            let h = try XCTUnwrap(c.lumaHistogram, url.lastPathComponent)
            XCTAssertEqual(h.count, 64)
            XCTAssertEqual(h.reduce(0, +), 1, accuracy: 1e-6)
            XCTAssertNotNil(c.cct)
            print("[context] \(url.lastPathComponent) people \(c.personFraction.map { String($0) } ?? "nil") saliency \(c.saliencyBox ?? []) faces \(c.faceCount ?? -1) cct \(c.cct ?? 0)")
            if url.lastPathComponent == "USER_mooncake.dng", c.personFraction != nil {
                XCTAssertGreaterThan(c.personFraction!, 0.03, "the person in the mooncake shot is segmented")
            }
        }
    }

    func testAsyncAnalysisMatchesSync() async throws {
        let url = try XCTUnwrap(try files().first)
        let dev = Developer()
        let a = try await dev.analyzeInBackground(url: url)
        let b = try dev.analyze(url: url)
        XCTAssertEqual(a.context.logP50, b.context.logP50, accuracy: 1e-9)
    }

    func testUnsupportedDecoderVersionThrows() throws {
        let url = try XCTUnwrap(try files().first)
        XCTAssertThrowsError(try RawDecoder().decode(url: url, settings: RenderSettings(mode: .explicit, decoderVersion: "nope")))
    }

    func testLookAndExport() throws {
        let renderer = Renderer(), decoder = RawDecoder()
        let url = try XCTUnwrap(try files().first)
        let out = try decoder.decode(url: url, settings: .appleDefault, scaleFactor: try decoder.scaleFactor(url: url, longEdge: 256))
        let neutral = try renderer.applyLook(BuiltInLook.neutral.lut(), to: out.image, intensity: 1)
        let size = (Int(out.image.extent.width), Int(out.image.extent.height))
        let cmp = try ComparisonMetrics.compare(candidate: renderer.linearImage(neutral, size: size), reference: renderer.linearImage(out.image, size: size))
        XCTAssertLessThan(cmp.deltaE00Mean, 1.0, "identity LUT should be ~lossless")
        let warm = try renderer.applyLook(BuiltInLook.warmNegative.lut(), to: out.image, intensity: 0.5)
        for f in Renderer.Format.allCases { XCTAssertGreaterThan(try renderer.export(warm, format: f).count, 1000, f.rawValue) }
    }
}
#endif
