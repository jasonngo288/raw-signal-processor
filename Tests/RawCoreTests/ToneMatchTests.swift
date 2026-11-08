import XCTest
@testable import RawCore

final class ToneMatchTests: XCTestCase {
    /// Histogram (64 bins of display-encoded luma) of linear luminances.
    func hist(_ linear: [Double], bins: Int = 64) -> [Double] {
        var h = [Double](repeating: 0, count: bins)
        for v in linear { h[min(bins - 1, Int(ColorMath.encodeTransfer(v) * Double(bins)))] += 1 }
        return h.map { $0 / Double(linear.count) }
    }
    var scene: [Double] { (0..<4000).map { i in 0.005 * pow(2, Double(i) / 4000 * 7) } }   // 7 stops, 0.005...0.64

    func testQuantileOfUniform() {
        let h = [Double](repeating: 1.0 / 64, count: 64)
        for q in [0.1, 0.5, 0.9] { XCTAssertEqual(ToneMatch.quantile(h, q), q, accuracy: 0.02) }
    }

    func testExposureOffsetFindsAKnownShift() {
        let ref = hist(scene)
        let brighter = hist(scene.map { $0 * pow(2, 0.6) })    // we are +0.6 EV vs the camera
        XCTAssertEqual(ToneMatch.exposureOffsetEV(candidate: brighter, reference: ref), -0.6, accuracy: 0.1)
        XCTAssertEqual(ToneMatch.exposureOffsetEV(candidate: ref, reference: ref), 0, accuracy: 0.02)
        let far = hist(scene.map { $0 * 8 })
        XCTAssertEqual(ToneMatch.exposureOffsetEV(candidate: far, reference: ref), -1, accuracy: 1e-9, "bounded to -1 EV")
    }

    func testCurveIdentityForEqualHistogramsAndMonotone() {
        let h = hist(scene)
        let c = ToneMatch.curve(candidate: h, reference: h)
        XCTAssertLessThan(ToneMatch.deviation(c), 0.01)
        let lut = ToneMatch.lut(c, size: 17)
        let o = lut.apply(SIMD3(0.4, 0.5, 0.6))
        XCTAssertEqual(o.x, 0.4, accuracy: 0.02); XCTAssertEqual(o.z, 0.6, accuracy: 0.02)

        // Camera compresses highlights: our top quantiles map down, the curve stays monotone and keeps 0 and 1.
        let compressed = hist(scene.map { $0 < 0.2 ? $0 : 0.2 + ($0 - 0.2) * 0.4 })
        let c2 = ToneMatch.curve(candidate: h, reference: compressed)
        XCTAssertEqual(c2.first!, SIMD2(0, 0)); XCTAssertEqual(c2.last!, SIMD2(1, 1))
        for (a, b) in zip(c2, c2.dropFirst()) { XCTAssertGreaterThanOrEqual(b.y, a.y); XCTAssertGreaterThan(b.x, a.x) }
        let l2 = ToneMatch.lut(c2, size: 33)
        var last: Float = -1
        for i in 0...20 {
            let o = l2.apply(SIMD3(repeating: Float(i) / 20))
            XCTAssertGreaterThanOrEqual(o.y, last - 1e-3); last = o.y
            XCTAssertEqual(o.x, o.z, accuracy: 1e-3, "grey stays grey")
        }
        XCTAssertLessThan(l2.apply(SIMD3(repeating: 0.8)).y, 0.79, "highlights pulled down")
    }
}
