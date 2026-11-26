#if canImport(CoreImage) && canImport(Vision)
import CoreGraphics
import CoreImage
import CoreVideo
import XCTest
@testable import RawCore

/// Schema 9 person mask: Vision `.balanced`, else `.fast` when balanced is empty; both empty means no person (nil, no fraction).
final class PersonMaskTests: XCTestCase {
    /// A flat grey frame has no person: balanced gives no pixel >= 128, so enrich returns nil with status ok + maskIsEmpty.
    func testEmptyBalancedMaskGivesNoMask() throws {
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = try XCTUnwrap(CGContext(data: nil, width: 256, height: 256, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        ctx.setFillColor(CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 256, height: 256))
        let image = try XCTUnwrap(ctx.makeImage())
        var scene = SceneContext(logP1: -8, logP50: -3, logP99: 0, dynamicRangeStops: 6, clippedFraction: 0, iso: 100, faceCount: 0, labels: nil)
        let mask = VisionAnalyzer.enrich(&scene, image: image)
        let diag = try XCTUnwrap(scene.personMaskDiag)
        if diag.status != .ok { throw XCTSkip("Vision person request unavailable here (\(diag.summary))") }
        XCTAssertTrue(diag.maskIsEmpty, "a flat grey frame should have no person pixel")
        XCTAssertNil(mask, "both masks empty must return no mask")
        XCTAssertEqual(diag.source, .balanced)
        XCTAssertTrue(diag.summary.contains("treated as no person"))
    }

    private func buffer(w: Int, h: Int, fill: UInt8) throws -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_OneComponent8, nil, &pb)
        let b = try XCTUnwrap(pb)
        CVPixelBufferLockBaseAddress(b, [])
        memset(CVPixelBufferGetBaseAddress(b), Int32(fill), CVPixelBufferGetBytesPerRow(b) * h)
        CVPixelBufferUnlockBaseAddress(b, [])
        return b
    }

    /// Balanced empty + fast hit: the fast mask is used and the diagnostics say so with both levels' stats.
    func testBalancedEmptyFastHitUsesFast() throws {
        let bal = try buffer(w: 96, h: 64, fill: 0), fast = try buffer(w: 48, h: 32, fill: 200)
        let (d, used) = VisionAnalyzer.pickPersonMask(balanced: bal) { fast }
        XCTAssertEqual(d.source, .fastFallback)
        XCTAssertTrue(used === fast)
        XCTAssertFalse(d.maskIsEmpty)
        XCTAssertEqual(d.balancedPixelsAtLeast128, 0)
        XCTAssertEqual(d.fastPixelsAtLeast128, 48 * 32)
        XCTAssertTrue(d.summary.contains("source fastFallback"))
    }

    /// Balanced has pixels: fast is never asked.
    func testBalancedHitSkipsFast() throws {
        let bal = try buffer(w: 96, h: 64, fill: 255)
        let (d, used) = VisionAnalyzer.pickPersonMask(balanced: bal) { XCTFail("fast must not run"); return nil }
        XCTAssertEqual(d.source, .balanced)
        XCTAssertTrue(used === bal)
    }

    /// Both empty: no person; the diagnostics keep both levels' stats and the trace validity is empty (noMaskEmpty).
    func testBothEmptyIsNoPerson() throws {
        let bal = try buffer(w: 96, h: 64, fill: 0), fast = try buffer(w: 48, h: 32, fill: 0)
        let (d, _) = VisionAnalyzer.pickPersonMask(balanced: bal) { fast }
        XCTAssertTrue(d.maskIsEmpty)
        XCTAssertEqual(d.source, .balanced)
        XCTAssertEqual(d.fastPixelsAtLeast128, 0)
        XCTAssertTrue(d.summary.contains("treated as no person"))
    }

    /// Stored analyses without the level stats, or with `"source":"fastFallback"`, still decode.
    func testOldJSONStillDecodes() throws {
        let json = #"{"status":"ok","width":192,"height":256,"maxValue":200,"nonZeroPixels":10,"pixelsAtLeast128":5,"source":"fastFallback","balancedMaxValue":0,"balancedPixelsAtLeast128":0,"fastMaxValue":200,"fastPixelsAtLeast128":5}"#
        let d = try JSONDecoder().decode(PersonMaskDiagnostics.self, from: Data(json.utf8))
        XCTAssertEqual(d.source, .fastFallback)
        XCTAssertEqual(d.pixelsAtLeast128, 5)
        let old = #"{"status":"ok","width":9,"height":9,"maxValue":0,"nonZeroPixels":0,"pixelsAtLeast128":0}"#
        let o = try JSONDecoder().decode(PersonMaskDiagnostics.self, from: Data(old.utf8))
        XCTAssertNil(o.source); XCTAssertTrue(o.maskIsEmpty)
    }
}
#endif
