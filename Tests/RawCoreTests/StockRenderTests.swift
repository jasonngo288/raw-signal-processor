import XCTest
@testable import RawCore
#if canImport(CoreImage)
import CoreImage
#endif

/// Pipeline v2 stage 2 skeleton (MoodRoll `.orchestration/film-lab/PIPELINE_V2_CONTRACT.md`, fixed stock render):
/// types, recipe record, anchor drift warnings, and that the pass-through changes no pixel in legacy or v2.
final class StockRenderTests: XCTestCase {
    static let originals = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("originals")

    // MARK: pure

    func testRecordListsPendingComponentsAndHasNoExposureOffset() throws {
        let ill = IlluminantMetadata(cct: 5000, tint: 3, source: "t")
        let r = StockRenderRecord(renderer: "passThrough", stock: "rr-sao-mai-200", illuminant: ill, applied: [], notes: [])
        XCTAssertEqual(r.pending, StockRender.Component.allCases)
        XCTAssertEqual(r.globalExposureOffsetEV, 0)
        XCTAssertEqual(r.version, StockRender.version)
        XCTAssertTrue(r.parametersStatus.contains("provisional"))
        let back = try JSONDecoder().decode(StockRenderRecord.self, from: Data(r.compactJSON().utf8))
        XCTAssertEqual(back, r)
        let partial = StockRenderRecord(renderer: "x", stock: nil, illuminant: ill, applied: [.halation], notes: [])
        XCTAssertFalse(partial.pending.contains(.halation))
        XCTAssertEqual(partial.pending.count, StockRender.Component.allCases.count - 1)
    }

    func testIlluminantFromContext() {
        let none = IlluminantMetadata(context: nil)
        XCTAssertNil(none.cct); XCTAssertNil(none.tint); XCTAssertNil(none.asShotNeutral)
        XCTAssertTrue(none.source.hasPrefix("none"))
    }

    func testAnchorsOnlyWarn() {
        let a = StockAnchor(stock: "rr-sao-mai-200", frame: "GS-A01", approvedOn: "2026-11-19", fingerprint: "abc", pipeline: "0.4.0")
        let b = StockAnchor(stock: "rr-sao-mai-200", frame: "GS-A02", approvedOn: "2026-11-19", fingerprint: "def", pipeline: "0.4.0")
        XCTAssertEqual(StockAnchors.check([a, b], rendered: [StockAnchors.key(stock: a.stock, frame: a.frame): "abc",
                                                             StockAnchors.key(stock: b.stock, frame: b.frame): "def"]), [])
        let drift = StockAnchors.check([a, b], rendered: [StockAnchors.key(stock: a.stock, frame: a.frame): "zzz"])
        XCTAssertEqual(drift.count, 2)
        XCTAssertEqual(drift[0].got, "zzz"); XCTAssertEqual(drift[0].expected, "abc")
        XCTAssertTrue(drift[0].message.hasPrefix("warning:"))
        XCTAssertNil(drift[1].got)
        XCTAssertTrue(drift[1].message.contains("not rendered"))
    }

    #if canImport(CoreImage)
    // MARK: pixels

    /// Replaces the image with flat grey: any call would change the pixels.
    struct PoisonRenderer: StockRenderer {
        let id = "poison"
        func render(_ image: CIImage, stock: FilmStock?, illuminant: IlluminantMetadata) throws -> StockRenderResult {
            StockRenderResult(image: CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: image.extent), applied: [.characteristicCurve])
        }
    }

    func dng() throws -> URL {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: Self.originals.path)) ?? []
        let pick = names.contains("IMG_1901.DNG") ? "IMG_1901.DNG" : names.filter { $0.lowercased().hasSuffix(".dng") }.sorted().first
        guard let n = pick else { throw XCTSkip("no DNGs in originals/") }
        return Self.originals.appendingPathComponent(n)
    }

    func settings(_ model: RenderSettings.ExposureModel?) -> RenderSettings {
        var s = RenderSettings(mode: .explicit)
        s.stock = "rr-sao-mai-200"
        s.exposureModel = model
        s.rollID = "R1"; s.rollFrameIndex = 3; s.rollFrameCount = 24
        return s
    }

    func testLegacyNeverRunsStageTwo() throws {
        let url = try dng()
        let dev = Developer()
        let scale = try dev.decoder.scaleFactor(url: url, longEdge: 384)
        let an = try dev.analyze(url: url)
        let plain = try dev.develop(url: url, settings: settings(nil), auto: true, scaleFactor: scale, analysis: an)
        let poisoned = Developer(stockRenderer: PoisonRenderer())
        let legacy = try poisoned.develop(url: url, settings: settings(.legacy), auto: true, scaleFactor: scale, analysis: an)
        XCTAssertNil(plain.recipe.stockRender); XCTAssertNil(legacy.recipe.stockRender)
        XCTAssertFalse(plain.recipe.compactJSON().contains("stockRender"))
        XCTAssertEqual(try dev.renderer.linearImage(plain.image).pixels, try dev.renderer.linearImage(legacy.image).pixels,
                       "legacy pixels changed by the stage-2 hook")
    }

    func testV2PassThroughKeepsPixelsAndRecords() throws {
        let url = try dng()
        let dev = Developer()
        let scale = try dev.decoder.scaleFactor(url: url, longEdge: 384)
        let an = try dev.analyze(url: url)
        let base = try dev.developBase(url: url, settings: settings(.v2Normalizer), auto: true, scaleFactor: scale, analysis: an)
        let withStage2 = try dev.finish(base)
        // Same v2 base, finished with the stage-2 gate off (finish reads exposureModel only for stage 2): the 0.4.0 finish.
        var skipped = base; skipped.settings.exposureModel = nil
        let without = try dev.finish(skipped)
        XCTAssertEqual(try dev.renderer.linearImage(withStage2.image).pixels, try dev.renderer.linearImage(without.image).pixels,
                       "v2 pixels changed by the stage-2 pass-through")
        XCTAssertNil(without.recipe.stockRender)
        let r = try XCTUnwrap(withStage2.recipe.stockRender)
        XCTAssertEqual(r.renderer, "passThrough")
        XCTAssertEqual(r.stock, "rr-sao-mai-200")
        XCTAssertEqual(r.applied, [])
        XCTAssertEqual(r.pending, StockRender.Component.allCases)
        XCTAssertEqual(r.illuminant.cct, an.context.cct)
        XCTAssertEqual(r.illuminant.tint, an.context.tint)
        // The hook is live under v2: a renderer that changes pixels does change the output.
        let poisoned = Developer(stockRenderer: PoisonRenderer())
        let p = try poisoned.finish(base)
        XCTAssertNotEqual(try dev.renderer.linearImage(p.image).pixels, try dev.renderer.linearImage(withStage2.image).pixels)
        XCTAssertEqual(p.recipe.stockRender?.applied, [.characteristicCurve])
    }
    #endif
}
