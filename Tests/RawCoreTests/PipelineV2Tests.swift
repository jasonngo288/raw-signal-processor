#if canImport(CoreImage)
import CoreImage
import XCTest
@testable import RawCore

/// Pipeline v2, RSP work item A (MoodRoll `.orchestration/film-lab/PIPELINE_V2_CONTRACT.md`):
/// stage-0 colour source record + optional calibration keyed by model + lens + RAW format; stage-4 output crop
/// (light leak, halation, vignette full-frame → crop → grain on the cropped short edge → qualityGuard).
final class PipelineV2Tests: XCTestCase {
    let renderer = Renderer()
    static let originals = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("originals")

    func appleDNG() throws -> URL {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: Self.originals.path)) ?? []
        let pick = names.contains("IMG_1901.DNG") ? "IMG_1901.DNG" : names.filter { $0.lowercased().hasSuffix(".dng") }.sorted().first
        guard let n = pick else { throw XCTSkip("no DNGs in originals/") }
        return Self.originals.appendingPathComponent(n)
    }

    let identity: [Float] = [1, 0, 0, 0, 1, 0, 0, 0, 1]
    let key = CalibrationKey(models: ["iPhone14,3", "iPhone14,3 back camera", "Apple iPhone 13 Pro Max"],
                             lens: "iPhone 13 Pro Max back camera 5.7mm f/1.5", rawFormat: .bayer)

    // MARK: stage 0, pure

    func testLookupIsExactOnModelLensAndFormat() {
        XCTAssertEqual(CalibrationTable.empty.lookup(key), .missing(.emptyTable, "calibration table is empty: DNG metadata"))
        let exact = ModelCalibration(model: "iPhone14,3", lens: key.lens, rawFormat: "bayer", ccm: identity, exposureOffsetEV: 0, version: "v1", source: "t")
        XCTAssertEqual(CalibrationTable(models: [exact]).lookup(key), .found(exact))

        let otherLens = ModelCalibration(model: "iPhone14,3", lens: "iPhone 13 Pro Max back telephoto camera 9mm f/2.8", rawFormat: "bayer",
                                         ccm: identity, exposureOffsetEV: 0, version: "v1", source: "t")
        let otherFormat = ModelCalibration(model: "iPhone14,3", lens: key.lens, rawFormat: "linearRaw", ccm: identity, exposureOffsetEV: 0, version: "v1", source: "t")
        let modelOnly = ModelCalibration(model: "iPhone14,3", ccm: identity, exposureOffsetEV: 0, version: "v0", source: "pre-v2")
        for e in [otherLens, otherFormat, modelOnly] {
            guard case .missing(let why, let detail) = CalibrationTable(models: [e]).lookup(key) else { return XCTFail("partial match used: \(e)") }
            XCTAssertEqual(why, .keyMismatch, detail)
        }
        let otherModel = ModelCalibration(model: "iPhone14,2", lens: key.lens, rawFormat: "bayer", ccm: identity, exposureOffsetEV: 0, version: "v1", source: "t")
        guard case .missing(.noEntry, _) = CalibrationTable(models: [otherModel]).lookup(key) else { return XCTFail("other model must not match") }
        // The pre-v2 substring rule still holds: "Apple iPhone 13 Pro Max" never serves "iPhone 13 Pro".
        let pro = CalibrationKey(models: ["Apple iPhone 13 Pro"], lens: key.lens, rawFormat: .bayer)
        let proMax = ModelCalibration(model: "Apple iPhone 13 Pro Max", lens: key.lens, rawFormat: "bayer", ccm: identity, exposureOffsetEV: 0, version: "v1", source: "t")
        guard case .missing(.noEntry, _) = CalibrationTable(models: [proMax]).lookup(pro) else { return XCTFail("substring match") }
        for incomplete in [CalibrationKey(models: [], lens: key.lens, rawFormat: .bayer),
                           CalibrationKey(models: key.models, lens: nil, rawFormat: .bayer),
                           CalibrationKey(models: key.models, lens: "", rawFormat: .bayer),
                           CalibrationKey(models: key.models, lens: key.lens, rawFormat: nil)] {
            guard case .missing(.keyIncomplete, _) = CalibrationTable(models: [exact]).lookup(incomplete) else { return XCTFail("\(incomplete)") }
        }
        XCTAssertEqual(CalibrationKey.RawFormat(photometricInterpretation: 32803), .bayer)
        XCTAssertEqual(CalibrationKey.RawFormat(photometricInterpretation: 34892), .linearRaw)
        XCTAssertNil(CalibrationKey.RawFormat(photometricInterpretation: 2))
        XCTAssertNil(CalibrationKey.RawFormat(photometricInterpretation: nil))
    }

    func testOldTablesAndRecipesStillDecode() throws {
        let oldTable = #"{"schema":1,"models":[{"model":"iPhone14,3","ccm":[1,0,0,0,1,0,0,0,1],"exposureOffsetEV":0,"version":"v0","source":"old"}]}"#
        let t = try JSONDecoder().decode(CalibrationTable.self, from: Data(oldTable.utf8))
        XCTAssertNil(t.models[0].lens)
        XCTAssertNil(t.models[0].rawFormat)
        guard case .missing(.keyMismatch, _) = t.lookup(key) else { return XCTFail("model-only entry must not be used by develop") }

        let rec = ColorSourceRecord.dngBaseline(key, .noEntry, "x")
        let back = try JSONDecoder().decode(ColorSourceRecord.self, from: Data(rec.compactJSON().utf8))
        XCTAssertEqual(back, rec)
        XCTAssertEqual(back.schema, ColorSourceRecord.currentSchema)
        XCTAssertTrue(rec.compactJSON().contains(#""source":"dngBaseline""#))
    }

    func testOutputCropValidationAndFraming() throws {
        XCTAssertNoThrow(try OutputCrop.full.validate())
        XCTAssertThrowsError(try OutputCrop(x: 0.5, y: 0, width: 0.6, height: 1).validate())
        XCTAssertThrowsError(try OutputCrop(x: 0, y: 0, width: 0, height: 1).validate())
        XCTAssertThrowsError(try OutputCrop(x: -0.1, y: 0, width: 0.5, height: 0.5).validate())
        var s = RenderSettings.explicit
        s.outputCrop = OutputCrop(x: 0, y: 0, width: 2, height: 1)
        XCTAssertThrowsError(try s.validate())

        XCTAssertNil(OutputCrop.framing(zoom: nil, cropRect: nil))
        XCTAssertNil(OutputCrop.framing(zoom: 1.0, cropRect: nil), "zoom <= 1.01 is no crop, as MoodRoll's framed")
        let z2 = try XCTUnwrap(OutputCrop.framing(zoom: 2, cropRect: nil))
        XCTAssertEqual(z2, OutputCrop(x: 0.25, y: 0.25, width: 0.5, height: 0.5))
        let both = try XCTUnwrap(OutputCrop.framing(zoom: 2, cropRect: [0, 0.125, 1, 0.75]))   // 4:3 → 16:9-ish band inside the zoom
        XCTAssertEqual(both.x, 0.25, accuracy: 1e-12); XCTAssertEqual(both.y, 0.3125, accuracy: 1e-12)
        XCTAssertEqual(both.width, 0.5, accuracy: 1e-12); XCTAssertEqual(both.height, 0.375, accuracy: 1e-12)

        // Top-left convention → Core Image bottom-left pixels.
        let r = FilmFinisher.pixelRect(OutputCrop(x: 0.1, y: 0.2, width: 0.5, height: 0.25), in: CGRect(x: 0, y: 0, width: 1000, height: 800))
        XCTAssertEqual(r, CGRect(x: 100, y: 440, width: 500, height: 200))
    }

    // MARK: stage 4, synthetic

    func flat(_ w: Int, _ h: Int, _ v: CGFloat) -> CIImage {
        CIImage(color: CIColor(red: v, green: v, blue: v, colorSpace: Renderer.linearP3)!).cropped(to: CGRect(x: 0, y: 0, width: w, height: h))
    }

    /// Lag (px, interpolated) where the row autocorrelation of the grain field first drops below 0.5.
    func correlationLength(_ img: LinearImage, mean: Float) -> Double {
        let y = img.displayLuminance().map { Double($0 / mean - 1) }
        let w = img.width, h = img.height
        var r0 = 0.0
        for v in y { r0 += v * v }
        var prev = 1.0
        for k in 1..<min(w / 4, 64) {
            var acc = 0.0
            for j in 0..<h { for i in 0..<(w - k) { acc += y[j * w + i] * y[j * w + i + k] } }
            let r = acc / r0 * Double(w) / Double(w - k)
            if r < 0.5 { return Double(k - 1) + (prev - 0.5) / (prev - r) }
            prev = r
        }
        return Double(min(w / 4, 64))
    }

    /// Grain after the crop is sized on the cropped short edge (same seed, same size %): a centre half crop gets cells
    /// half as many pixels wide as grain applied to the full frame and then cropped (the 0.3.1 order).
    func testCropThenGrainSizesCellsOnTheCroppedShortEdge() throws {
        let v: CGFloat = 0.18
        let full = flat(1200, 800, v)
        let f = FilmFinish(grainAmount: 0.8, grainSize: 1.5, grainSeed: 5)
        let rect = FilmFinisher.pixelRect(OutputCrop(x: 0.25, y: 0.25, width: 0.5, height: 0.5), in: full.extent)
        XCTAssertEqual(rect.size, CGSize(width: 600, height: 400))
        let v2 = try renderer.linearImage(FilmFinisher.applyGrain(FilmFinisher.crop(full, to: rect), f))
        let old = try renderer.linearImage(FilmFinisher.crop(FilmFinisher.applyGrain(full, f), to: rect))
        XCTAssertEqual(v2.width, 600); XCTAssertEqual(old.width, 600)
        let lv2 = correlationLength(v2, mean: Float(v)), lold = correlationLength(old, mean: Float(v))
        print(String(format: "[v2-crop] grain correlation length: cropped-then-grain %.2f px, grain-then-crop %.2f px, ratio %.2f (expected 0.5)", lv2, lold, lv2 / lold))
        XCTAssertEqual(lv2 / lold, 0.5, accuracy: 0.12, "cell size follows the cropped short edge (400 vs 800 px)")
        // Same seed, same size %: identical to grain on a standalone frame of the cropped size.
        let standalone = try renderer.linearImage(FilmFinisher.applyGrain(flat(600, 400, v), f))
        XCTAssertEqual(v2.pixels, standalone.pixels)
        // Splitting the finish is exact: grain(halation(x)) == apply(x) on the same extent.
        let fh = FilmFinish(grainAmount: 0.5, grainSize: 0.3, grainSeed: 9, halationAmount: 0.6, halationThreshold: 0.1, halationRadius: 1)
        let ramp = full.applyingFilter("CIColorMatrix", parameters: ["inputBiasVector": CIVector(x: 0.3, y: 0.3, z: 0.3, w: 0)])
        XCTAssertEqual(try renderer.linearImage(FilmFinisher.applyGrain(FilmFinisher.applyHalation(ramp, fh), fh)).pixels,
                       try renderer.linearImage(FilmFinisher.apply(ramp, fh)).pixels)
    }

    // MARK: on a real DNG (skipped without originals/)

    func pixels(_ o: Developer.Output) throws -> [Float] { try renderer.linearImage(o.image).pixels }

    /// Empty table = DNG baseline, recipe says so, pixels identical to a render that cannot take a calibration.
    /// A same-model entry for another lens is not used (keyMismatch) and changes no pixel.
    func testEmptyTableAndKeyMismatchAreDNGBaselineWithIdenticalPixels() throws {
        let url = try appleDNG()
        let plain = Developer(plugins: .none)
        let k = try plain.calibrationKey(url)
        print("[v2-key] \(url.lastPathComponent): models \(k.models) lens \(k.lens ?? "nil") format \(k.rawFormat?.rawValue ?? "nil")")
        XCTAssertFalse(k.models.isEmpty)
        if url.lastPathComponent == "IMG_1901.DNG" {
            XCTAssertEqual(k.models.first, "iPhone14,3")
            XCTAssertEqual(k.lens, "iPhone 13 Pro Max back camera 5.7mm f/1.5")
            XCTAssertEqual(k.rawFormat, .bayer)
        }
        let scale = try plain.decoder.scaleFactor(url: url, longEdge: 384)
        let empty = try plain.develop(url: url, settings: .explicit, auto: false, scaleFactor: scale)
        XCTAssertEqual(empty.recipe.colorSource?.source, .dngBaseline)
        XCTAssertEqual(empty.recipe.colorSource?.skipReason, .emptyTable)
        XCTAssertEqual(empty.recipe.colorSource?.key, k)
        XCTAssertNil(empty.recipe.settings.ccm)
        XCTAssertNil(empty.recipe.settings.linearExposureEV)

        var off = RenderSettings.explicit
        off.useCalibration = false
        let disabled = try plain.develop(url: url, settings: off, auto: false, scaleFactor: scale)
        XCTAssertEqual(disabled.recipe.colorSource?.skipReason, .calibrationDisabled)
        XCTAssertEqual(try pixels(empty), try pixels(disabled))

        let model = try XCTUnwrap(k.models.first)
        let wrongLens = Developer(plugins: .none, calibration: CalibrationTable(models: [
            ModelCalibration(model: model, lens: (k.lens ?? "") + " (other lens)", rawFormat: k.rawFormat?.rawValue,
                             ccm: [1.2, 0, 0, 0, 1, 0, 0, 0, 0.8], exposureOffsetEV: 1, version: "x", source: "unit test")]))
        let mismatch = try wrongLens.develop(url: url, settings: .explicit, auto: false, scaleFactor: scale)
        XCTAssertEqual(mismatch.recipe.colorSource?.source, .dngBaseline)
        XCTAssertEqual(mismatch.recipe.colorSource?.skipReason, .keyMismatch)
        XCTAssertNotNil(mismatch.recipe.colorSource?.detail)
        XCTAssertEqual(try pixels(mismatch), try pixels(empty), "a non-matching entry changes no pixel")

        var ccm = RenderSettings.explicit
        ccm.ccm = identity
        XCTAssertEqual(try wrongLens.develop(url: url, settings: ccm, auto: false, scaleFactor: scale).recipe.colorSource?.skipReason, .explicitCCM)
        var lin = RenderSettings.explicit
        lin.linearExposureEV = 0
        XCTAssertEqual(try wrongLens.develop(url: url, settings: lin, auto: false, scaleFactor: scale).recipe.colorSource?.skipReason, .explicitLinearExposure)
        XCTAssertEqual(try plain.develop(url: url, settings: .appleDefault, auto: false, scaleFactor: scale).recipe.colorSource?.skipReason, .appleDefaultMode)
    }

    /// nil crop keeps the 0.3.1 order. A full-frame crop with no vignette and no guard runs the v2 order and must give
    /// the same pixels (proves the split halation | crop | grain equals the one-step finish). A real crop gives the
    /// cropped size at origin 0,0 and differs from cropping the 0.3.1 output (grain re-sized).
    func testOutputCropOrderOnADNG() throws {
        let url = try appleDNG()
        let dev = Developer(plugins: .none)
        let scale = try dev.decoder.scaleFactor(url: url, longEdge: 600)
        var s = RenderSettings.explicit
        s.finish = FilmFinish(grainAmount: 0.6, grainSize: 0.5, grainSeed: 21, halationAmount: 0.4, halationThreshold: 0.6, halationRadius: 1)
        let base = try dev.developBase(url: url, settings: s, auto: false, scaleFactor: scale)
        let none = try dev.finish(base)
        var b2 = base
        b2.settings.outputCrop = .full
        let fullCrop = try dev.finish(b2)
        XCTAssertEqual(try pixels(none), try pixels(fullCrop))
        XCTAssertFalse(none.recipe.decisions.contains { $0.hasPrefix("output crop") })
        XCTAssertTrue(fullCrop.recipe.decisions.contains { $0.hasPrefix("output crop") })

        var b3 = base
        let crop = OutputCrop(x: 0.2, y: 0.1, width: 0.5, height: 0.6)
        b3.settings.outputCrop = crop
        let cropped = try dev.finish(b3)
        let rect = FilmFinisher.pixelRect(crop, in: none.image.extent)
        XCTAssertEqual(cropped.image.extent, CGRect(origin: .zero, size: rect.size))
        let oldThenCrop = try renderer.linearImage(FilmFinisher.crop(none.image, to: rect))
        XCTAssertNotEqual(try pixels(cropped), oldThenCrop.pixels, "grain is re-sized on the cropped short edge")
        XCTAssertTrue(cropped.recipe.decisions.contains { $0.contains("cropped short edge") })
        XCTAssertEqual(cropped.recipe.settings.outputCrop, crop)
    }

    /// With the standard plugins: vignette runs before the crop, qualityGuard after (on the cropped base).
    func testPluginSplitAroundTheCrop() throws {
        XCTAssertFalse(VignettePlugin().runsAfterCrop)
        XCTAssertFalse(LightLeakPlugin().runsAfterCrop)
        XCTAssertTrue(QualityGuardPlugin().runsAfterCrop)
        let url = try appleDNG()
        let dev = Developer()
        let scale = try dev.decoder.scaleFactor(url: url, longEdge: 384)
        var s = dev.guardEnabled(RenderSettings.explicit)
        s.stock = FilmStock.all.first { ($0.finish.vignette) > 0 }?.name
        s.outputCrop = OutputCrop(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        let o = try dev.develop(url: url, settings: s, auto: false, scaleFactor: scale)
        let d = o.recipe.decisions
        let iv = d.firstIndex { $0.hasPrefix("[vignette]") }, ic = d.firstIndex { $0.hasPrefix("output crop") }
        if let iv { XCTAssertLessThan(iv, try XCTUnwrap(ic), "vignette on the full frame, before the crop") }
        XCTAssertNotNil(o.recipe.qualityGuardStrength, "the guard ran on the cropped frame")
    }
}
#endif
