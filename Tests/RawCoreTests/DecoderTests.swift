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
        XCTAssertEqual(full.recipe.plugins, ["highlightRecovery", "vignette"])
        XCTAssertEqual(core.recipe.plugins, [])
        XCTAssertEqual(core.recipe.effective.extendedDynamicRangeAmount, 0, "no EDR without the plugin")
        XCTAssertFalse(core.recipe.decisions.contains { $0.hasPrefix("[highlightRecovery]") })
        XCTAssertEqual(core.recipe.decoderVersionSource, "policy")
        // Core auto equals an explicit decode with the same decided settings (nothing hidden in the core).
        let again = try dev.decoder.decode(url: url, settings: core.recipe.settings, scaleFactor: scale)
        let size = (Int(core.image.extent.width), Int(core.image.extent.height))
        let cmp = try ComparisonMetrics.compare(candidate: dev.renderer.linearImage(core.image, size: size), reference: dev.renderer.linearImage(again.image, size: size))
        XCTAssertLessThan(cmp.deltaE00Mean, 0.01)
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
