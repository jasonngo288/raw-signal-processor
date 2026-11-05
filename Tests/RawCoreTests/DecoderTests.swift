#if canImport(CoreImage)
import CoreImage
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
