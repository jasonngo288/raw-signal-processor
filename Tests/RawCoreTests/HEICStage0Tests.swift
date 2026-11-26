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
}
#endif
