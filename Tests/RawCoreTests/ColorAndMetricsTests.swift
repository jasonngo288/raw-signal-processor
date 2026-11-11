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

    /// DOMAIN is the input range: outputs are never rescaled (regression: they were divided by the domain).
    func testCubeDomainIsInputRange() throws {
        func cube(_ header: String, _ f: (Int, Int, Int) -> String) -> String {
            var t = "LUT_3D_SIZE 2\n" + header
            for b in 0..<2 { for g in 0..<2 { for r in 0..<2 { t += f(r, g, b) + "\n" } } }
            return t
        }
        // Constant output 0.3 over domain 0.5…1: every input gives 0.3 (was (0.3 − 0.5)/0.5 = −0.4).
        let flat = try CubeLUT.parse(cube("DOMAIN_MIN 0.5 0.5 0.5\nDOMAIN_MAX 1 1 1\n") { _, _, _ in "0.3 0.3 0.3" })
        XCTAssertEqual(flat.apply(SIMD3(0.2, 0.7, 1)), SIMD3(repeating: 0.3))
        // output = 0.4·input + 0.1 over domain 0…2 (nodes 0.1 and 0.9): input 0.5 → 0.3 (was 0.25).
        let off = try CubeLUT.parse(cube("DOMAIN_MAX 2 2 2\n") { r, g, b in "\(Double(r) * 0.8 + 0.1) \(Double(g) * 0.8 + 0.1) \(Double(b) * 0.8 + 0.1)" })
        XCTAssertEqual(off.apply(SIMD3(repeating: 0.5)).x, 0.3, accuracy: 1e-5)
        XCTAssertThrowsError(try CubeLUT.parse(cube("DOMAIN_MIN 1 1 1\nDOMAIN_MAX 1 1 1\n") { _, _, _ in "0 0 0" }))
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
                if look != .tungstenNight {  // tungsten-balanced: daylight grey goes cool by design
                    XCTAssertLessThan(abs(o.x - o.z), 0.08, "\(look) tints grey too much at \(g)")
                }
                if look == .mono { XCTAssertEqual(o.x, o.z, accuracy: 1e-5); XCTAssertEqual(o.x, o.y, accuracy: 1e-5) }
            }
        }
        let id = BuiltInLook.neutral.lut(size: 9).apply(SIMD3(0.3, 0.6, 0.9))
        XCTAssertEqual(id.x, 0.3, accuracy: 1e-5)
    }

    /// Regression: warmNegative turned dark, slightly coloured pixels into saturated blue/red blotches.
    func testLooksDoNotBlowUpShadowChroma() {
        for look in BuiltInLook.allCases {
            let lut = look.lut(size: 33)
            for c in [SIMD3<Float>(0.02, 0.004, 0.004), SIMD3<Float>(0.003, 0.003, 0.03), SIMD3<Float>(0.05, 0.03, 0.02)] {
                let o = lut.apply(c)
                let spreadIn = c.max() - c.min(), spreadOut = o.max() - o.min()
                XCTAssertLessThan(spreadOut, spreadIn * 2.5 + 0.03, "\(look) \(c) -> \(o)")
            }
        }
    }

    func testFilmStocksAndFinishValidation() throws {
        XCTAssertEqual(Set(FilmStock.all.map(\.name)).count, FilmStock.all.count, "unique stock names")
        for stock in FilmStock.all { XCTAssertNoThrow(try stock.finish.validate(), stock.name) }
        XCTAssertTrue(FilmFinish.none.isNone)
        XCTAssertEqual(FilmStock.named("mono400")?.allowsSkinProtection, false, "no colour skin in black and white")
        XCTAssertEqual(FilmStock.named("warm400")?.allowsSkinProtection, true)
        XCTAssertTrue(BuiltInLook.mono.lut(size: 17).isMonochrome)
        XCTAssertFalse(BuiltInLook.warmNegative.lut(size: 17).isMonochrome)
        XCTAssertFalse(BuiltInLook.neutral.lut(size: 17).isMonochrome)
        XCTAssertThrowsError(try FilmFinish(grainAmount: 1.5).validate())
        XCTAssertThrowsError(try FilmFinish(grainSize: 0).validate())
        XCTAssertThrowsError(try FilmFinish(halationThreshold: 1).validate())
        var s = RenderSettings(mode: .explicit)
        s.stock = "warm400"
        XCTAssertNoThrow(try s.validate())
        s.stock = "Portra400"
        XCTAssertThrowsError(try s.validate(), "unknown stock names are rejected")
        s.stock = nil
        s.finish = FilmFinish(grainAmount: 0.3)
        XCTAssertNoThrow(try s.validate())
        XCTAssertFalse(s.hasOverrides, "finishing is not a decode override")
        let data = try JSONEncoder().encode(s)
        XCTAssertEqual(try JSONDecoder().decode(RenderSettings.self, from: data), s)
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

    /// Roadmap 13: the look's strength follows the scene, bounded; the stock never changes.
    func testLookIntensityFollowsSceneBounded() {
        func ctx(p50: Double, iso: Double = 100, people: Double = 0, labels: [String: Double]? = nil) -> SceneContext {
            var c = SceneContext(logP1: -8, logP50: p50, logP99: 0, dynamicRangeStops: 6, clippedFraction: 0, iso: iso, faceCount: 0, labels: labels)
            c.personFraction = people; return c
        }
        XCTAssertEqual(DecisionEngine.lookIntensityOffset(context: ctx(p50: -3)).0, 0, "ordinary daylight: no change")
        XCTAssertEqual(DecisionEngine.lookIntensityOffset(context: ctx(p50: -6.4)).0, -0.10, accuracy: 1e-6, "night (NIGHT01 median)")
        // Threshold from tuning files only: CAFE01 (−6.13) is dark, MTN01 (−4.57) is not.
        XCTAssertEqual(DecisionEngine.lookIntensityOffset(context: ctx(p50: -6.13)).0, -0.10, accuracy: 1e-6, "CAFE01")
        XCTAssertEqual(DecisionEngine.lookIntensityOffset(context: ctx(p50: -4.57)).0, 0, "MTN01")
        XCTAssertEqual(DecisionEngine.lookIntensityOffset(context: ctx(p50: -6.1, iso: 3200, people: 0.2)).0, -0.15, accuracy: 1e-6, "clamped at -0.15")
        XCTAssertEqual(DecisionEngine.lookIntensityOffset(context: ctx(p50: -1, labels: ["sky": 0.95, "outdoor": 0.98])).0, 0.05, accuracy: 1e-6)
        XCTAssertEqual(DecisionEngine.lookIntensityOffset(context: ctx(p50: -1, people: 0.3, labels: ["sky": 0.95])).0, -0.05, accuracy: 1e-6, "people win over landscape")
        XCTAssertEqual(DecisionEngine.lookIntensityOffset(context: ctx(p50: -1, labels: ["sky": 0.3])).0, 0, "low-confidence label ignored")
        // A caller lock (0) is respected.
        let d = DecodeParameters(exposure: 0, baselineExposure: 0, shadowBias: 0, boostAmount: 1, boostShadowAmount: 1, localToneMapAmount: 0,
                                 sharpnessAmount: 0.5, contrastAmount: 0, detailAmount: 0, luminanceNoiseReductionAmount: 0.2, colorNoiseReductionAmount: 0.2,
                                 moireReductionAmount: 0, extendedDynamicRangeAmount: 0, lensCorrection: true, gamutMapping: true, neutralTemperature: 5000, neutralTint: 0)
        let sup = DecoderSupport(localToneMap: false, sharpness: true, contrast: true, detail: true, luminanceNoiseReduction: true,
                                 colorNoiseReduction: true, moireReduction: true, lensCorrection: false, maxExtendedDynamicRange: 2)
        var locked = RenderSettings.explicit; locked.lookIntensityOffset = 0
        XCTAssertEqual(DecisionEngine.decide(context: ctx(p50: -6.4), defaults: d, support: sup, base: locked).settings.lookIntensityOffset, 0)
        XCTAssertEqual(DecisionEngine.decide(context: ctx(p50: -6.4), defaults: d, support: sup).settings.lookIntensityOffset!, -0.10, accuracy: 1e-6)
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
                                 luminanceNoiseReductionAmount: 0.95, colorNoiseReductionAmount: 0.95, moireReductionAmount: 0,
                                 extendedDynamicRangeAmount: 0, lensCorrection: false, gamutMapping: true, neutralTemperature: 5000, neutralTint: 0)
        let s = DecoderSupport(localToneMap: true, sharpness: true, contrast: true, detail: true, luminanceNoiseReduction: true,
                               colorNoiseReduction: true, moireReduction: true, lensCorrection: true, maxExtendedDynamicRange: 2)
        var c = SceneContext(logP1: -12, logP50: -3, logP99: 1, dynamicRangeStops: 15, clippedFraction: 0.05, iso: 3200, faceCount: 1, labels: nil)
        c.displayClippedFraction = 0.40; c.edrHeadroom = 40; c.largestFaceArea = 0.05; c.personFraction = 0.2
        let dec = DecisionEngine.decide(context: c, defaults: d, support: s)
        XCTAssertNil(dec.settings.toneMapSourceHeadroom, "highlight recovery is a plugin, not core")
        XCTAssertEqual(dec.settings.localToneMapAmount, 1)
        XCTAssertEqual(dec.settings.luminanceNoiseReductionAmount, 1)
        XCTAssertEqual(dec.settings.colorNoiseReductionAmount, 1)
        XCTAssertEqual(dec.settings.sharpnessAmount, 0)
        XCTAssertNil(dec.settings.detailAmount, "detail default 0: the face rule lowers sharpness instead (above)")
        XCTAssertEqual(dec.settings.lensCorrection, true)
        XCTAssertEqual(dec.settings.skinProtection, DecisionEngine.Threshold.skinProtection)
        XCTAssertEqual(dec.reasons.count, 9, "7 decode rules + 2 look-intensity reasons (ISO 3200, people)")
        XCTAssertEqual(dec.settings.lookIntensityOffset!, -0.10, accuracy: 1e-6)
        XCTAssertNoThrow(try dec.settings.validate())

        // An explicit skinProtection (e.g. 0 = off) is respected.
        var off = RenderSettings.explicit
        off.skinProtection = 0
        XCTAssertEqual(DecisionEngine.decide(context: c, defaults: d, support: s, base: off).settings.skinProtection, 0)

        // Unsupported local tone map is reported; tiny faces keep detail; a missing face area is not a big face.
        var tiny = c
        tiny.largestFaceArea = 0.001; tiny.personFraction = 0
        let noLTM = DecoderSupport(localToneMap: false, sharpness: true, contrast: true, detail: true, luminanceNoiseReduction: true,
                                   colorNoiseReduction: true, moireReduction: true, lensCorrection: false, maxExtendedDynamicRange: 2)
        let dt = DecisionEngine.decide(context: tiny, defaults: d, support: noLTM)
        XCTAssertNil(dt.settings.localToneMapAmount)
        XCTAssertNil(dt.settings.detailAmount)
        XCTAssertNil(dt.settings.skinProtection)
        XCTAssertTrue(dt.reasons.contains { $0.contains("unsupported") })
        var unknownArea = tiny
        unknownArea.largestFaceArea = nil
        XCTAssertNil(DecisionEngine.decide(context: unknownArea, defaults: d, support: s).settings.detailAmount)

        let calm = SceneContext(logP1: -6, logP50: -3, logP99: -1, dynamicRangeStops: 5, clippedFraction: 0, iso: 50, faceCount: 0, labels: nil)
        let dLens = DecodeParameters(exposure: 0, baselineExposure: 0, shadowBias: 0, boostAmount: 1, boostShadowAmount: 1,
                                     localToneMapAmount: 0, sharpnessAmount: 0.5, contrastAmount: 0, detailAmount: 0,
                                     luminanceNoiseReductionAmount: 0, colorNoiseReductionAmount: 0, moireReductionAmount: 0,
                                     extendedDynamicRangeAmount: 0, lensCorrection: true, gamutMapping: true, neutralTemperature: 5000, neutralTint: 0)
        XCTAssertFalse(DecisionEngine.decide(context: calm, defaults: dLens, support: s).settings.hasOverrides)
    }

    func testHighlightRecoveryRule() {
        var c = SceneContext(logP1: -6, logP50: -2, logP99: 1, dynamicRangeStops: 7, clippedFraction: 0.05, iso: 50, faceCount: 0, labels: nil)
        c.displayClippedFraction = 0.40; c.edrHeadroom = 40
        var st = RenderSettings.explicit
        let why = HighlightRecoveryRule.decide(context: c, settings: &st)
        XCTAssertEqual(st.extendedDynamicRangeAmount, 1)
        XCTAssertEqual(st.toneMapSourceHeadroom, 16, "headroom is capped")
        XCTAssertEqual(st.highlightClarity, HighlightRecoveryRule.clarity)
        XCTAssertEqual(why.count, 1)
        var sensor = c
        sensor.clippedFraction = 0.39
        var st2 = RenderSettings.explicit
        let why2 = HighlightRecoveryRule.decide(context: sensor, settings: &st2)
        XCTAssertNil(st2.toneMapSourceHeadroom)
        XCTAssertTrue(why2.first?.contains("cannot be recovered") ?? false)
    }

    func testCalibrationTableAndDecoderPolicy() throws {
        let entry = ModelCalibration(model: "iPhone 13 Pro Max", ccm: [1, 0, 0, 0, 1, 0, 0, 0, 1], exposureOffsetEV: 1, version: "v0", source: "test")
        let t = CalibrationTable(models: [entry])
        XCTAssertNil(t.entry(for: "Apple iPhone 13 Pro Max"), "no substring guessing")
        let byId = CalibrationTable(models: [ModelCalibration(model: "iPhone14,3", ccm: [1, 0, 0, 0, 1, 0, 0, 0, 1], exposureOffsetEV: 0, version: "v1", source: "t"),
                                             ModelCalibration(model: "iPhone14,2", ccm: [1, 0, 0, 0, 1, 0, 0, 0, 1], exposureOffsetEV: 0, version: "v2", source: "t")])
        let keys = CalibrationTable.candidates(uniqueCameraModel: "iPhone14,3 back camera", camera: "Apple iPhone 13 Pro Max")
        XCTAssertEqual(keys.first ?? nil, "iPhone14,3")
        XCTAssertEqual(byId.entry(forAny: keys)?.version, "v1", "model identifier from UniqueCameraModel")
        XCTAssertEqual(t.entry(for: "iPhone 13 Pro Max")?.version, "v0", "exact match")
        XCTAssertNil(t.entry(for: "Apple iPhone 8"))
        XCTAssertNil(t.entry(for: nil))
        XCTAssertEqual(entry.linearMatrix[0], 2, accuracy: 1e-6, "+1 EV doubles the matrix")
        XCTAssertThrowsError(try ModelCalibration(model: "x", ccm: [1], exposureOffsetEV: 0, version: "", source: "").validate())
        XCTAssertEqual(DecoderPolicy.pick(supported: ["6.dng", "7.dng", "8.dng", "8"]), "8")
        XCTAssertEqual(DecoderPolicy.pick(supported: ["6.dng", "7.dng", "8.dng"]), "8.dng")
        XCTAssertEqual(DecoderPolicy.pick(supported: ["9", "8"]), "8", "versions not in the policy are not picked silently")
        XCTAssertNil(DecoderPolicy.pick(supported: ["9"]))
    }

    func testMaskedDeltaE() throws {
        let a = LinearImage(width: 4, height: 1, fill: (0.3, 0.3, 0.3))
        var b = a
        b.pixels[0] = 0.6
        let c = try ComparisonMetrics.compare(candidate: b, reference: a, mask: [true, false, false, false])
        XCTAssertGreaterThan(try XCTUnwrap(c.deltaE00MeanMasked), 1)
        XCTAssertEqual(try XCTUnwrap(c.deltaE00MeanOutsideMask), 0, accuracy: 1e-9)
        XCTAssertThrowsError(try ComparisonMetrics.compare(candidate: b, reference: a, mask: [true]))
    }

    func testContextHelpers() {
        var img = LinearImage(width: 10, height: 10, fill: (0.2, 0.2, 0.2))
        for i in 0..<10 { img.pixels[i * 3] = 4 }  // 10 % of pixels at 4x white in red
        XCTAssertEqual(SceneContext.clippedFraction(img), 0.1, accuracy: 1e-9)
        XCTAssertEqual(SceneContext.headroom(img), 4, accuracy: 1e-6)
        XCTAssertEqual(SceneContext.headroom(LinearImage(width: 4, height: 4, fill: (0.1, 0.1, 0.1))), 1)
        var c = SceneContext.measure(sceneLinear: img, iso: 100)
        c.displayClippedFraction = 0.3
        XCTAssertEqual(try XCTUnwrap(c.recoverableClippedFraction), 0.2, accuracy: 1e-9)
    }

    /// Regression: recovering a clipped highlight must not read as "halo" just because the ring moved.
    func testRingOnReferenceMaskComparesSamePixels() throws {
        var ref = LinearImage(width: 120, height: 120, fill: (0.1, 0.1, 0.1))
        for y in 40..<80 { for x in 40..<80 { let i = (y * 120 + x) * 3; ref.pixels[i] = 1; ref.pixels[i + 1] = 1; ref.pixels[i + 2] = 1 } }
        var cand = ref
        // Candidate recovers the outer part of the highlight (now 0.9, below the clip threshold).
        for y in 40..<80 { for x in 40..<80 where x < 50 || x >= 70 || y < 50 || y >= 70 {
            let i = (y * 120 + x) * 3; cand.pixels[i] = 0.9; cand.pixels[i + 1] = 0.9; cand.pixels[i + 2] = 0.9 } }
        let c = try ComparisonMetrics.compare(candidate: cand, reference: ref)
        XCTAssertGreaterThan(try XCTUnwrap(c.candidate.highlightRingMeanY), try XCTUnwrap(c.reference.highlightRingMeanY) + 0.05,
                             "own-mask ring moves onto the recovered highlight")
        XCTAssertEqual(try XCTUnwrap(c.candidateRingOnReferenceMask), try XCTUnwrap(c.reference.highlightRingMeanY), accuracy: 1e-6)
    }

    func testUnclippedDeltaEIgnoresClippedReferencePixels() throws {
        var ref = LinearImage(width: 10, height: 10, fill: (0.3, 0.3, 0.3))
        for i in 0..<50 { ref.pixels[i * 3] = 1; ref.pixels[i * 3 + 1] = 1; ref.pixels[i * 3 + 2] = 1 }
        var cand = ref
        for i in 0..<50 { cand.pixels[i * 3] = 0.8; cand.pixels[i * 3 + 1] = 0.8; cand.pixels[i * 3 + 2] = 0.8 }
        let c = try ComparisonMetrics.compare(candidate: cand, reference: ref)
        XCTAssertGreaterThan(c.deltaE00Mean, 1)
        XCTAssertEqual(c.deltaE00MeanUnclipped, 0, accuracy: 1e-9)
        XCTAssertEqual(c.referenceUnclippedFraction, 0.5, accuracy: 1e-9)
    }
}

final class SharpnessMetricsTests: XCTestCase {
    private func gray(_ y: [Float], _ w: Int, _ h: Int) -> LinearImage {
        var p = [Float](repeating: 0, count: w * h * 3)
        for i in 0..<(w * h) { p[i * 3] = y[i]; p[i * 3 + 1] = y[i]; p[i * 3 + 2] = y[i] }
        return LinearImage(width: w, height: h, pixels: p)
    }
    /// Deterministic roughly-Gaussian noise (sum of 4 uniforms), unit variance.
    private func noise(_ n: Int, seed: UInt32 = 7) -> [Float] {
        var s = seed
        func u() -> Float { s = s &* 1664525 &+ 1013904223; return Float(s >> 8) / Float(1 << 24) - 0.5 }
        return (0..<n).map { _ in (u() + u() + u() + u()) * 1.7320508 }
    }
    private func step(_ w: Int, _ h: Int, sigma: Double = 1) -> [Float] {
        let s = (0..<(w * h)).map { Float($0 % w < w / 2 ? 0.15 : 0.6) }
        return gaussianBlur(s, width: w, height: h, sigma: sigma)
    }

    func testSharpenedStepShowsOvershoot() {
        let w = 128, h = 128
        let soft = step(w, h)
        let blur2 = gaussianBlur(soft, width: w, height: h, sigma: 2)
        let sharp = zip(soft, blur2).map { $0 + 1.0 * ($0 - $1) }   // unsharp mask
        let a = SharpnessMetrics.measure(gray(soft, w, h)), b = SharpnessMetrics.measure(gray(sharp, w, h), reference: gray(soft, w, h))
        XCTAssertGreaterThan(a.edgeCount, 50)
        XCTAssertLessThan(a.edgeOvershootPercent ?? 100, 3, "a plain blurred step has no overshoot")
        XCTAssertGreaterThan(b.edgeOvershootPercent ?? 0, 10, "an unsharp-masked step must overshoot")
    }

    func testOvershootDropsWhenSharpeningIsReduced() throws {
        let w = 128, h = 128
        let soft = step(w, h), blur2 = gaussianBlur(soft, width: w, height: h, sigma: 2)
        let strong = gray(zip(soft, blur2).map { $0 + 1.0 * ($0 - $1) }, w, h)
        let mild = gray(zip(soft, blur2).map { $0 + 0.5 * ($0 - $1) }, w, h)
        let c = try SharpnessComparison.compare(candidate: mild, reference: strong)
        let change = try XCTUnwrap(c.overshootChangePercent)
        XCTAssertLessThan(change, -30)
        XCTAssertGreaterThan(change, -70)
    }

    func testBlurredImageHasLowerHFRatio() throws {
        let w = 128, h = 128
        let n = noise(w * h)
        let base = gray(zip(gaussianBlur(n, width: w, height: h, sigma: 3), n).map { 0.3 + 0.05 * $0 + 0.04 * $1 }, w, h)
        let blurred = gray(gaussianBlur(base.displayLuminance(), width: w, height: h, sigma: 1.2), w, h)
        let c = try SharpnessComparison.compare(candidate: blurred, reference: base)
        XCTAssertLessThan(try XCTUnwrap(c.hfRatio), 0.6)
        let same = try SharpnessComparison.compare(candidate: base, reference: base)
        XCTAssertEqual(try XCTUnwrap(same.hfRatio), 1, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(same.overshootChangePercent ?? 0), 0, accuracy: 1e-9)
    }

    func testFlatTextureMeasuresNoiseAndScales() throws {
        let w = 128, h = 128
        let n = noise(w * h)
        let a = gray(n.map { 0.3 * (1 + 0.02 * $0) }, w, h)
        let b = gray(n.map { 0.3 * (1 + 0.04 * $0) }, w, h)
        let ma = SharpnessMetrics.measure(a)
        // log2(1 + 0.02 n) ~ 0.02 n / ln 2 = 0.0289 n; the sigma-2 high-pass keeps ~0.99 of white noise.
        XCTAssertEqual(try XCTUnwrap(ma.flatTexture), 0.0289, accuracy: 0.004)
        XCTAssertGreaterThan(ma.flatPixelFraction, 0.9)
        let c = try SharpnessComparison.compare(candidate: b, reference: a)
        XCTAssertEqual(try XCTUnwrap(c.flatTextureRatio), 2, accuracy: 0.15)
        // Waxy: smoothing the noise drops the ratio well below 0.9.
        let waxy = gray(gaussianBlur(a.displayLuminance(), width: w, height: h, sigma: 1.5), w, h)
        XCTAssertLessThan(try XCTUnwrap(SharpnessComparison.compare(candidate: waxy, reference: a).flatTextureRatio), 0.5)
    }
}
