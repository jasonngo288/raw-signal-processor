import XCTest
@testable import RawCore

final class ColorMathTests: XCTestCase {
    func testCIEDE2000SharmaReference() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "ciede2000-reference", withExtension: "txt", subdirectory: "Fixtures"))
        let rows = try String(contentsOf: url, encoding: .utf8).split(whereSeparator: \.isNewline)
            .map { $0.split(whereSeparator: { $0 == "\t" || $0 == " " }).compactMap { Double($0) } }
            .filter { $0.count == 7 }
        XCTAssertEqual(rows.count, 34)
        for r in rows {
            XCTAssertEqual(ColorMath.deltaE2000(r[0], r[1], r[2], r[3], r[4], r[5]), r[6], accuracy: 1e-4, "\(r)")
            XCTAssertEqual(ColorMath.deltaE2000(r[3], r[4], r[5], r[0], r[1], r[2]), r[6], accuracy: 1e-4, "symmetry \(r)")
        }
    }

    func testLabWhiteAndBlack() {
        let w = ColorMath.lab(r: 1, g: 1, b: 1)
        XCTAssertEqual(w.l, 100, accuracy: 0.05)
        XCTAssertEqual(w.a, 0, accuracy: 0.05)
        XCTAssertEqual(w.b, 0, accuracy: 0.05)
        let k = ColorMath.lab(r: 0, g: 0, b: 0)
        XCTAssertEqual(k.l, 0, accuracy: 1e-9)
    }

    func testTransferRoundTrip() {
        for v in stride(from: 0.0, through: 1.0, by: 0.05) {
            XCTAssertEqual(ColorMath.decodeTransfer(ColorMath.encodeTransfer(v)), v, accuracy: 1e-9)
        }
    }

    func testLuminanceWeightsSumToOne() {
        let w = ColorMath.p3LuminanceWeights
        XCTAssertEqual(Double(w.r + w.g + w.b), 1, accuracy: 1e-5)
    }
}

final class MetricsTests: XCTestCase {
    func testFlatGreyImage() {
        let img = LinearImage(width: 64, height: 48, fill: (0.18, 0.18, 0.18))
        let m = ImageMetrics.measure(img)
        XCTAssertEqual(m.meanY, 0.18, accuracy: 1e-4)
        XCTAssertEqual(m.blackP1, 0.18, accuracy: 1e-4)
        XCTAssertEqual(m.clippedFraction, 0)
        XCTAssertEqual(m.localContrast, 0, accuracy: 1e-5)
        XCTAssertNil(m.highlightRingMeanY)
        XCTAssertEqual(m.meanChroma, 0, accuracy: 0.05)
    }

    func testClippedSquareAndRing() {
        var img = LinearImage(width: 200, height: 200, fill: (0.1, 0.1, 0.1))
        for y in 90..<110 { for x in 90..<110 { let i = (y * 200 + x) * 3; img.pixels[i] = 1; img.pixels[i + 1] = 1; img.pixels[i + 2] = 1 } }
        let m = ImageMetrics.measure(img)
        XCTAssertEqual(m.clippedFraction, 400.0 / 40000.0, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(m.highlightRingMeanY), 0.1, accuracy: 1e-4)
        XCTAssertGreaterThan(m.localContrast, 0)
    }

    func testHaloRaisesRing() {
        var img = LinearImage(width: 200, height: 200, fill: (0.05, 0.05, 0.05))
        for y in 0..<200 { for x in 0..<200 {
            let d = hypot(Double(x - 100), Double(y - 100))
            let i = (y * 200 + x) * 3
            let v: Float = d < 10 ? 1 : Float(0.05 + 0.5 * exp(-(d - 10) / 15))
            img.pixels[i] = v; img.pixels[i + 1] = v; img.pixels[i + 2] = v
        } }
        let ring = try! XCTUnwrap(ImageMetrics.measure(img).highlightRingMeanY)
        XCTAssertGreaterThan(ring, 0.1)
    }

    func testSharpnessOrdering() {
        var img = LinearImage(width: 128, height: 128, fill: (0, 0, 0))
        for y in 0..<128 { for x in 0..<128 { let v: Float = ((x / 4 + y / 4) % 2 == 0) ? 0.6 : 0.1; let i = (y * 128 + x) * 3; img.pixels[i] = v; img.pixels[i + 1] = v; img.pixels[i + 2] = v } }
        var soft = img
        for c in 0..<3 {
            let plane = (0..<(128 * 128)).map { img.pixels[$0 * 3 + c] }
            let b = gaussianBlur(plane, width: 128, height: 128, sigma: 1.5)
            for i in 0..<(128 * 128) { soft.pixels[i * 3 + c] = b[i] }
        }
        XCTAssertGreaterThan(ImageMetrics.measure(img).localContrast, ImageMetrics.measure(soft).localContrast * 1.2)
    }

    func testCompareIdenticalIsZeroAndSizeMismatchThrows() throws {
        let a = LinearImage(width: 16, height: 16, fill: (0.3, 0.2, 0.1))
        let c = try ComparisonMetrics.compare(candidate: a, reference: a)
        XCTAssertEqual(c.deltaE00Mean, 0, accuracy: 1e-9)
        XCTAssertThrowsError(try ComparisonMetrics.compare(candidate: a, reference: LinearImage(width: 8, height: 16, fill: (0, 0, 0))))
    }

    func testDownsampleAverages() {
        let img = LinearImage(width: 4, height: 2, pixels: [0, 0, 0, 1, 1, 1, 0, 0, 0, 1, 1, 1, 0, 0, 0, 1, 1, 1, 0, 0, 0, 1, 1, 1])
        let d = img.downsampled(by: 2)
        XCTAssertEqual(d.width, 2); XCTAssertEqual(d.height, 1)
        XCTAssertEqual(d.pixels, [0.5, 0.5, 0.5, 0.5, 0.5, 0.5])
    }
}

final class LookAndSettingsTests: XCTestCase {
    func testCubeParseIdentityAndDomain() throws {
        var text = "TITLE \"t\"\n# comment\nLUT_3D_SIZE 2\nDOMAIN_MIN 0 0 0\nDOMAIN_MAX 2 2 2\n"
        for b in 0..<2 { for g in 0..<2 { for r in 0..<2 { text += "\(r * 2) \(g * 2) \(b * 2)\n" } } }
        let lut = try CubeLUT.parse(text)
        XCTAssertEqual(lut.size, 2)
        XCTAssertEqual(lut.title, "t")
        let v = lut.apply(SIMD3(0.25, 0.5, 0.75))
        XCTAssertEqual(v.x, 0.25, accuracy: 1e-6); XCTAssertEqual(v.y, 0.5, accuracy: 1e-6); XCTAssertEqual(v.z, 0.75, accuracy: 1e-6)
    }

    func testCubeRejectsBadInput() {
        XCTAssertThrowsError(try CubeLUT.parse("LUT_3D_SIZE 2\n0 0 0\n"))
        XCTAssertThrowsError(try CubeLUT.parse("0 0 0\n"))
        XCTAssertThrowsError(try CubeLUT.parse("LUT_1D_SIZE 4\n"))
    }

    func testBuiltInLooksAreMonotoneOnGreyAndKeepNeutral() {
        for look in BuiltInLook.allCases {
            let lut = look.lut(size: 17)
            var last: Float = -1
            for i in 0...20 {
                let g = Float(i) / 20
                let o = lut.apply(SIMD3(repeating: g))
                let y = 0.2126 * o.x + 0.7152 * o.y + 0.0722 * o.z
                XCTAssertGreaterThanOrEqual(y, last - 1e-4, "\(look) not monotone at \(g)")
                last = y
                XCTAssertLessThan(abs(o.x - o.z), 0.08, "\(look) tints grey too much at \(g)")
            }
        }
        let id = BuiltInLook.neutral.lut(size: 9).apply(SIMD3(0.3, 0.6, 0.9))
        XCTAssertEqual(id.x, 0.3, accuracy: 1e-5)
    }

    func testSettingsValidationAndCodable() throws {
        var s = RenderSettings.appleDefault
        XCTAssertNoThrow(try s.validate())
        s.exposure = 0.3
        XCTAssertThrowsError(try s.validate())
        s.mode = .explicit
        XCTAssertNoThrow(try s.validate())
        s.ccm = [1, 0, 0]
        XCTAssertThrowsError(try s.validate())
        s.ccm = [1, 0, 0, 0, 1, 0, 0, 0, 1]
        let data = try JSONEncoder().encode(s)
        XCTAssertEqual(try JSONDecoder().decode(RenderSettings.self, from: data), s)
    }

    func testSceneLinearOverridesIntent() {
        let d = DecodeParameters(exposure: 0, baselineExposure: -1.8, shadowBias: 0.02, boostAmount: 1, boostShadowAmount: 1,
                                 localToneMapAmount: 0.5, sharpnessAmount: 0.3, contrastAmount: 0.5, detailAmount: 0.5,
                                 luminanceNoiseReductionAmount: 0.2, colorNoiseReductionAmount: 0.2, moireReductionAmount: 0.5,
                                 extendedDynamicRangeAmount: 0, lensCorrection: true, gamutMapping: true, neutralTemperature: 5000, neutralTint: 0)
        let p = d.applying(.sceneLinear)
        XCTAssertEqual(p.baselineExposure, 0); XCTAssertEqual(p.boostAmount, 0); XCTAssertEqual(p.localToneMapAmount, 0)
        XCTAssertFalse(p.gamutMapping)
        XCTAssertEqual(p.sharpnessAmount, 0.3)
        XCTAssertEqual(d.applying(.explicit), d)
    }

    func testDecisionEngineIsBoundedAndLogged() {
        let d = DecodeParameters(exposure: 0, baselineExposure: 0, shadowBias: 0, boostAmount: 1, boostShadowAmount: 1,
                                 localToneMapAmount: 0.9, sharpnessAmount: 0.05, contrastAmount: 0, detailAmount: 0,
                                 luminanceNoiseReductionAmount: 0.95, colorNoiseReductionAmount: 0, moireReductionAmount: 0,
                                 extendedDynamicRangeAmount: 0, lensCorrection: true, gamutMapping: true, neutralTemperature: 5000, neutralTint: 0)
        let s = DecoderSupport(localToneMap: true, sharpness: true, contrast: true, detail: true, luminanceNoiseReduction: true,
                               colorNoiseReduction: true, moireReduction: true, lensCorrection: true, maxExtendedDynamicRange: 0)
        let c = SceneContext(logP1: -12, logP50: -3, logP99: 1, dynamicRangeStops: 15, clippedFraction: 0.5, iso: 3200, faceCount: 1, labels: nil)
        let dec = DecisionEngine.decide(context: c, defaults: d, support: s)
        XCTAssertEqual(dec.settings.localToneMapAmount, 1)
        XCTAssertEqual(try XCTUnwrap(dec.settings.exposure), -0.3, accuracy: 1e-6)
        XCTAssertEqual(dec.settings.luminanceNoiseReductionAmount, 1)
        XCTAssertEqual(dec.settings.sharpnessAmount, 0)
        XCTAssertEqual(dec.reasons.count, 5)
        let calm = SceneContext(logP1: -6, logP50: -3, logP99: -1, dynamicRangeStops: 5, clippedFraction: 0, iso: 50, faceCount: 0, labels: nil)
        XCTAssertFalse(DecisionEngine.decide(context: calm, defaults: d, support: s).settings.hasOverrides)
    }
}
