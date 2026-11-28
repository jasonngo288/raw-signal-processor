#if canImport(CoreImage)
import CoreImage
import XCTest
@testable import RawCore

/// Stage 0-H (HEIC entry for selfie frames). Synthetic HEIC only: the real front-camera samples are measured with
/// `raw-bench heic-pairs`, not here.
final class HEICStage0Tests: XCTestCase {
    private func makeHEIC() throws -> URL {
        let dev = Developer()
        let size = CGRect(x: 0, y: 0, width: 640, height: 480)
        let ramp = CIFilter(name: "CILinearGradient", parameters: [
            "inputPoint0": CIVector(x: 0, y: 0), "inputPoint1": CIVector(x: 640, y: 0),
            "inputColor0": CIColor(red: 0.1, green: 0.1, blue: 0.1), "inputColor1": CIColor(red: 0.9, green: 0.8, blue: 0.7),
        ])!.outputImage!.cropped(to: size)
        let data = try XCTUnwrap(dev.renderer.context.heifRepresentation(of: ramp, format: .RGBA8, colorSpace: Renderer.displayP3, options: [:]))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("stage0h-\(UUID().uuidString).heic")
        try data.write(to: url)
        return url
    }

    func testHEICDevelopsThroughStockAndRecordsStage0H() throws {
        let url = try makeHEIC()
        defer { try? FileManager.default.removeItem(at: url) }
        let dev = Developer()
        var s = RenderSettings(mode: .explicit)
        s.stock = "PRESET_26_CPM35"
        s.outputCrop = .full
        let out = try dev.develop(heic: url, settings: s, scaleFactor: 1)
        XCTAssertEqual(Int(out.image.extent.width), 640)
        let rec = try XCTUnwrap(out.recipe.heicStage0)
        XCTAssertEqual(rec.source, "heic")
        XCTAssertEqual(rec.headroom, "none")
        XCTAssertEqual(out.recipe.decoderVersion, Developer.heicDecoderVersion)
        XCTAssertNil(out.recipe.exposureNormalizer)
    }

    func testHEICAnalysisIsOnlyUsableForHEIC() throws {
        let url = try makeHEIC()
        defer { try? FileManager.default.removeItem(at: url) }
        let a = try Developer().analyze(heic: url)
        XCTAssertEqual(a.decoderVersion, Developer.heicDecoderVersion)
        XCTAssertNil(a.staleReason(url: url, decoderVersion: Developer.heicDecoderVersion, plugins: []))
        XCTAssertNotNil(a.staleReason(url: url, decoderVersion: "1", plugins: []))
    }

    /// Stage 1 on a HEIC: the stock's exposure bias is ignored (0.8.0); the HEIC is as shot.
    /// The user's bias, `decodeHeadroomEV` and `cameraMatchStrength` change no pixel.
    func testHEICStockExposureIsIgnoredAndTheRestIsNotApplied() throws {
        let url = try makeHEIC()
        defer { try? FileManager.default.removeItem(at: url) }
        let dev = Developer()
        func base(_ configure: (inout RenderSettings) -> Void) throws -> (Double, HEICStage0Record) {
            var s = RenderSettings(mode: .explicit)
            s.outputCrop = .full
            configure(&s)
            let b = try dev.developBase(heic: url, settings: s, scaleFactor: 1)
            let lin = try dev.renderer.linearImage(b.image)
            return (ImageMetrics.measure(lin).meanY, try XCTUnwrap(b.recipe.heicStage0))
        }
        let (y0, r0) = try base { _ in }
        XCTAssertEqual(r0.stockExposureEV, 0)
        XCTAssertNil(r0.stockExposureRequestedEV)
        // 0.8.0: the stock's exposure bias is ignored on a HEIC: pixels and stockExposureEV unchanged, the request is only recorded.
        for requested: Float in [0.5, 2, -3] {
            let (y, r) = try base { $0.exposure = requested }
            XCTAssertEqual(y, y0, accuracy: 1e-6, "stock exposure \(requested) changes no pixel on a HEIC")
            XCTAssertEqual(r.stockExposureEV, 0)
            XCTAssertEqual(r.stockExposureRequestedEV, requested)
        }
        // Not applied: the user's bias (already in the pixels), the RAW decode compensation, the cameraMatch strength.
        let (yOthers, rOthers) = try base { $0.userExposureBiasEV = 1.5; $0.decodeHeadroomEV = 1; $0.cameraMatchStrength = 0.5 }
        XCTAssertEqual(yOthers, y0, accuracy: 1e-6)
        XCTAssertEqual(rOthers.stockExposureEV, 0)
        XCTAssertEqual(rOthers.userExposureBiasEV, 1.5)
    }

    func testHEICVersionsAndToneKAreBumped() {
        XCTAssertEqual(HEICToneInverse.defaultK, 0.4)
        XCTAssertEqual(Developer.heicDecoderVersion, "heic-0H-3")
        XCTAssertEqual(Developer.heicStage0Version, "0H-4")
        XCTAssertEqual(HEICToneInverse.version, "toneS-2")
    }

    /// An explicit skinProtection (the app sets 0.75 for heicSource frames) overrides the auto value (DecisionEngine.Threshold.skinProtection) on the HEIC path.
    func testExplicitSkinProtectionIsHonouredOnHEIC() throws {
        let url = try makeHEIC()
        defer { try? FileManager.default.removeItem(at: url) }
        var s = RenderSettings(mode: .explicit)
        s.outputCrop = .full
        s.skinProtection = 0.75
        let b = try Developer().developBase(heic: url, settings: s, scaleFactor: 1)
        XCTAssertEqual(b.settings.skinProtection, 0.75)
        XCTAssertEqual(b.recipe.settings.skinProtection, 0.75)
    }

    func testToneInverseIsAnInverseAndKeepsRange() {
        for k: Float in [0.1, 0.4, 0.6] {
            for e in stride(from: Float(0), through: 1, by: 0.05) {
                XCTAssertEqual(HEICToneInverse.curveInverse(HEICToneInverse.curve(e, k: k), k: k), e, accuracy: 1e-5)
            }
        }
        XCTAssertEqual(HEICToneInverse.curveInverse(0.3, k: 0), 0.3)
        let bright = HEICToneInverse.invert(encoded: SIMD3(1, 1, 1), k: HEICToneInverse.defaultK)
        XCTAssertLessThanOrEqual(max(bright.x, bright.y, bright.z), 1.0001)
        let sat = HEICToneInverse.invert(encoded: SIMD3(0.95, 0.6, 0.2), k: HEICToneInverse.defaultK)
        XCTAssertLessThanOrEqual(max(sat.x, sat.y, sat.z), 1.0001)
    }

    func testIlluminantEstimateOrderAndFallback() {
        XCTAssertEqual(HEICIlluminant.estimate(lightSource: 3, flash: 1, ev100: 14).cct, 2850, "LightSource wins")
        XCTAssertEqual(HEICIlluminant.estimate(lightSource: 0, flash: 1, ev100: 5).cct, 5500, "flash fired")
        XCTAssertEqual(HEICIlluminant.estimate(lightSource: nil, flash: 0, ev100: 13).cct, 5500, "bright scene")
        let fb = HEICIlluminant.estimate(lightSource: nil, flash: nil, ev100: nil)
        XCTAssertEqual(fb.cct, HEICIlluminant.fallbackCCT)
        XCTAssertEqual(fb.tint, 0)
        XCTAssertTrue(fb.source.hasPrefix("fallback"))
    }

    // MARK: Stage 0-H skin hold toward the camera tone (2026-11-28, film-lab selfie round)

    /// HEIC base with a synthetic left-half person mask (Vision finds nobody in a gradient).
    private func baseWithMask(_ url: URL, dev: Developer) throws -> Developer.Base {
        var a = try dev.analyze(heic: url)
        let white = CIImage(color: CIColor(red: 1, green: 1, blue: 1)).cropped(to: CGRect(x: 0, y: 0, width: 32, height: 48))
        let black = CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: CGRect(x: 32, y: 0, width: 32, height: 48))
        a.personMask = white.composited(over: black)
        var s = RenderSettings(mode: .explicit)
        s.stock = "PRESET_26_CPM35"
        s.outputCrop = .full
        s.skinProtection = 0.75
        return try dev.developBase(heic: url, settings: s, scaleFactor: 1, analysis: a)
    }

    func testHEICSkinHoldUsesTheCameraImageAndWideFeather() throws {
        let url = try makeHEIC()
        defer { try? FileManager.default.removeItem(at: url) }
        let dev = Developer()
        let base = try baseWithMask(url, dev: dev)
        let hold = try XCTUnwrap(base.heicHoldBase, "HEIC frame with skin protection and a person mask carries the camera-tone hold base")
        XCTAssertEqual(hold.extent, base.image.extent)
        let out = try dev.finish(base)
        XCTAssertTrue(out.recipe.decisions.contains { $0.contains("held toward the camera tone, feather 0.015") }, "\(out.recipe.decisions)")
        // Pixel: the camera-tone hold changes the person half and leaves the far background (outside the feather) unchanged.
        var plain = base
        plain.heicHoldBase = nil
        let outPlain = try dev.finish(plain)
        XCTAssertFalse(outPlain.recipe.decisions.contains { $0.contains("camera tone") })
        func meanY(_ img: CIImage, _ r: CGRect) throws -> Double {
            ImageMetrics.measure(try dev.renderer.linearImage(img.cropped(to: r))).meanY
        }
        let person = CGRect(x: 40, y: 100, width: 160, height: 280), background = CGRect(x: 440, y: 100, width: 160, height: 280)
        let dP = abs(try meanY(out.image, person) - meanY(outPlain.image, person))
        let dB = abs(try meanY(out.image, background) - meanY(outPlain.image, background))
        XCTAssertGreaterThan(dP, 1e-4, "person region now holds toward the camera image")
        XCTAssertLessThan(dB, 1e-4, "background is untouched by the new hold")
    }

    func testNoHoldBaseWithoutSkinProtectionOrMask() throws {
        let url = try makeHEIC()
        defer { try? FileManager.default.removeItem(at: url) }
        let dev = Developer()
        var s = RenderSettings(mode: .explicit)
        s.outputCrop = .full
        XCTAssertNil(try dev.developBase(heic: url, settings: s, scaleFactor: 1).heicHoldBase, "no skin protection requested")
        s.skinProtection = 0.75
        XCTAssertNil(try dev.developBase(heic: url, settings: s, scaleFactor: 1).heicHoldBase, "no person mask (gradient)")
    }

    /// DNG frames never go through the new branch, and the RAW call into `protectSkin` keeps the old 0.004 feather.
    func testDNGFrameHasNoHoldBase() throws {
        let dir = DevelopStagesTests.root.appendingPathComponent("originals")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        guard let n = names.filter({ $0.lowercased().hasSuffix(".dng") }).sorted().first else { throw XCTSkip("no DNGs in originals/") }
        let dev = Developer(plugins: .none)
        var s = RenderSettings(mode: .explicit)
        s.skinProtection = 0.75
        let url = dir.appendingPathComponent(n)
        let b = try dev.developBase(url: url, settings: s, auto: false, scaleFactor: try dev.decoder.scaleFactor(url: url, longEdge: 256))
        XCTAssertNil(b.heicHoldBase)
        XCTAssertFalse(b.recipe.decisions.contains { $0.contains("camera tone") })
    }

    func testProtectSkinDefaultFeatherIsTheOldOne() throws {
        let dev = Developer()
        let img = CIImage(color: CIColor(red: 0.8, green: 0.3, blue: 0.2)).cropped(to: CGRect(x: 0, y: 0, width: 64, height: 48))
        let base = CIImage(color: CIColor(red: 0.2, green: 0.4, blue: 0.6)).cropped(to: img.extent)
        let mask = CIImage(color: CIColor(red: 1, green: 1, blue: 1)).cropped(to: CGRect(x: 0, y: 0, width: 32, height: 48))
            .composited(over: CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: img.extent))
        let a = dev.renderer.protectSkin(looked: img, base: base, mask: mask, strength: 0.75)
        let b = dev.renderer.protectSkin(looked: img, base: base, mask: mask, strength: 0.75, feather: 0.004)
        let c = dev.renderer.protectSkin(looked: img, base: base, mask: mask, strength: 0.75, feather: 0.015)
        func px(_ i: CIImage, _ x: CGFloat) -> [Float] {
            var buf = [Float](repeating: 0, count: 4)
            dev.renderer.context.render(i, toBitmap: &buf, rowBytes: 16, bounds: CGRect(x: x, y: 24, width: 1, height: 1), format: .RGBAf, colorSpace: nil)
            return buf
        }
        XCTAssertEqual(px(a, 33), px(b, 33), "default feather is the old 0.004")
        XCTAssertNotEqual(px(b, 33), px(c, 33), "the wide feather really differs near the mask edge")
    }

    /// A stock's `minSkinProtection` switches the hold on while `settings.skinProtection` is nil: the hold base must exist then too.
    func testStockMinSkinProtectionGetsTheHoldBase() throws {
        let url = try makeHEIC()
        defer { try? FileManager.default.removeItem(at: url) }
        let dev = Developer()
        let name = try XCTUnwrap(FilmStock.all.first { $0.minSkinProtection != nil }?.name, "a stock with minSkinProtection")
        var a = try dev.analyze(heic: url)
        a.personMask = CIImage(color: CIColor(red: 1, green: 1, blue: 1)).cropped(to: CGRect(x: 0, y: 0, width: 64, height: 48))
        var s = RenderSettings(mode: .explicit)
        s.stock = name
        s.outputCrop = .full
        s.skinProtection = nil
        let b = try dev.developBase(heic: url, settings: s, scaleFactor: 1, analysis: a)
        XCTAssertNotNil(b.heicHoldBase)
    }

    /// A failed second decode must not fail the frame: old hold, a decision records why.
    func testSecondDecodeFailureFallsBackToTheOldHold() throws {
        let url = try makeHEIC()
        defer { try? FileManager.default.removeItem(at: url) }
        let dev = Developer()
        HEICSkinHold.failSecondDecodeForTest = true
        defer { HEICSkinHold.failSecondDecodeForTest = false }
        let b = try baseWithMask(url, dev: dev)
        XCTAssertNil(b.heicHoldBase)
        XCTAssertTrue(b.recipe.decisions.contains { $0.contains("second HEIC decode failed") })
        let out = try dev.finish(b)
        XCTAssertFalse(out.recipe.decisions.contains { $0.contains("camera tone") })
    }
}
#endif
