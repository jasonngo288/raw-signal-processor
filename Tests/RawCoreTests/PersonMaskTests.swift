#if canImport(CoreImage) && canImport(Vision)
import CoreGraphics
import CoreImage
import XCTest
@testable import RawCore

/// Schema 8 person mask: Vision `.balanced` only; an empty balanced mask means no person (nil, no fraction).
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
        XCTAssertNil(mask, "an empty balanced mask must return no mask")
        XCTAssertEqual(diag.source, .balanced)
        XCTAssertTrue(diag.summary.contains("treated as no person"))
    }

    /// Stored analyses from schema 7 may carry `"source":"fastFallback"` and the removed fast/balanced stats: still decode.
    func testOldFastFallbackSourceStillDecodes() throws {
        let json = #"{"status":"ok","width":192,"height":256,"maxValue":200,"nonZeroPixels":10,"pixelsAtLeast128":5,"source":"fastFallback","balancedMaxValue":0,"balancedPixelsAtLeast128":0,"fastMaxValue":200,"fastPixelsAtLeast128":5}"#
        let d = try JSONDecoder().decode(PersonMaskDiagnostics.self, from: Data(json.utf8))
        XCTAssertEqual(d.status, .ok)
        XCTAssertEqual(d.source, .balanced)
        XCTAssertEqual(d.pixelsAtLeast128, 5)
        XCTAssertFalse(d.maskIsEmpty)
    }
}
#endif
