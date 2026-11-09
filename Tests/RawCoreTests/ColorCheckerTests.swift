import XCTest
@testable import RawCore

final class ColorCheckerTests: XCTestCase {
    let ref = ColorChecker.referenceLabD50.map(ColorChecker.referenceLinearP3)

    func testReferenceConversion() {
        XCTAssertEqual(ref.count, 24)
        let n5 = ColorChecker.labD65(ref[21])
        XCTAssertEqual(n5.x, 50.76, accuracy: 0.1)
        XCTAssertLessThan(abs(n5.y) + abs(n5.z), 0.6, "neutral 5 stays neutral through Bradford + P3")
        XCTAssertGreaterThan(ref[14].x, ref[14].y * 4, "red patch is red")
        XCTAssertEqual(ref[21].y, 0.19, accuracy: 0.01)
    }

    func testFitRecoversAKnownMatrix() throws {
        let m: [Double] = [1.2, -0.15, -0.05, -0.1, 1.15, -0.05, 0.02, -0.12, 1.10]   // rows sum to 1
        let inv = try XCTUnwrap(ColorChecker.inverse3(m))
        let measured = ref.map { ColorChecker.mul(inv, $0) * 0.5 }    // camera sees the chart 1 EV darker, desaturated
        let fit = try XCTUnwrap(ColorChecker.fit(measured: measured))
        for i in 0..<9 { XCTAssertEqual(fit.ccm[i], m[i], accuracy: 0.01, "ccm[\(i)]") }
        XCTAssertEqual(fit.exposureScale, 2, accuracy: 0.05)
        XCTAssertLessThan(fit.meanAfter, 0.5)
        XCTAssertGreaterThan(fit.meanBefore, 2)
        for r in 0..<3 { XCTAssertEqual(fit.ccm[r * 3] + fit.ccm[r * 3 + 1] + fit.ccm[r * 3 + 2], 1, accuracy: 1e-9, "neutral preserved") }
    }

    func testClippedPatchesAreLeftOut() throws {
        var measured = ref.map { $0 * 0.5 }
        measured[18] = SIMD3(1, 1, 1)   // white clipped
        let fit = try XCTUnwrap(ColorChecker.fit(measured: measured))
        let id: [Double] = [1, 0, 0, 0, 1, 0, 0, 0, 1]
        for i in 0..<9 { XCTAssertEqual(fit.ccm[i], id[i], accuracy: 0.01, "identity camera: the clipped white does not bend the fit") }
    }

    func testSamplingGeometry() {
        // 24 flat patches on a grey surround, image row 0 = top.
        let w = 600, h = 400
        var px = [Float](repeating: 0.1, count: w * h * 3)
        let corners = ColorChecker.Corners(topLeft: SIMD2(0.15, 0.2), topRight: SIMD2(0.85, 0.2), bottomRight: SIMD2(0.85, 0.8), bottomLeft: SIMD2(0.15, 0.8))
        for r in 0..<4 { for c in 0..<6 {
            let ctr = corners.centre(row: r, col: c), v = ref[r * 6 + c]
            let cx = Int(ctr.x * Double(w)), cy = Int(ctr.y * Double(h))
            for y in (cy - 20)...(cy + 20) { for x in (cx - 20)...(cx + 20) {
                let i = (y * w + x) * 3; px[i] = Float(v.x); px[i + 1] = Float(v.y); px[i + 2] = Float(v.z)
            } }
        } }
        let s = ColorChecker.sample(LinearImage(width: w, height: h, pixels: px), corners: corners)
        for i in 0..<24 { XCTAssertEqual(s[i].x, ref[i].x, accuracy: 1e-3, ColorChecker.names[i]); XCTAssertEqual(s[i].z, ref[i].z, accuracy: 1e-3) }
    }

    func testCornersParseAndGate3Compare() {
        XCTAssertNotNil(ColorChecker.Corners("0.1,0.2,0.9,0.2,0.9,0.8,0.1,0.8"))
        XCTAssertNil(ColorChecker.Corners("0.1,0.2,0.9"))
        XCTAssertNil(ColorChecker.Corners("0.1,0.2,0.9,0.2,0.9,0.8,0.1,1.8"))
        XCTAssertEqual(ColorChecker.compare(ref, ref.map { $0 * 0.7 }).max()!, 0, accuracy: 1e-6, "exposure difference is normalised away")
        var shifted = ref; shifted[14] = SIMD3(ref[14].x, ref[14].y * 1.3, ref[14].z)
        XCTAssertGreaterThan(ColorChecker.compare(ref, shifted)[14], 1)
    }

    func testParseReferenceSheetFormats() throws {
        let built = ColorChecker.referenceLabD50
        // X-Rite-style sheet: header, comment, "n name L a b" rows.
        var sheet = "# my chart, Lab D50 2 deg\nPatch Name L* a* b*\n"
        for (i, l) in built.enumerated() { sheet += "\(i + 1)\t\(ColorChecker.names[i])\t\(l.x)\t\(l.y)\t\(l.z)\n" }
        XCTAssertEqual(try XCTUnwrap(ColorChecker.parseReference(sheet)), built)
        // European CSV with decimal commas.
        let euro = built.map { "\($0.x);\($0.y);\($0.z)".replacingOccurrences(of: ".", with: ",") }.joined(separator: "\n")
        XCTAssertEqual(try XCTUnwrap(ColorChecker.parseReference(euro)), built)
        // Wrong count or out-of-range L is rejected.
        XCTAssertNil(ColorChecker.parseReference(built.dropLast().map { "\($0.x) \($0.y) \($0.z)" }.joined(separator: "\n")))
        XCTAssertNil(ColorChecker.parseReference(built.map { "\($0.x * 3) \($0.y) \($0.z)" }.joined(separator: "\n")))
    }

    func testFitFollowsACustomReference() throws {
        var lab = ColorChecker.referenceLabD50; lab[14].y += 6   // a chart batch with a redder red
        let custom = lab.map(ColorChecker.referenceLinearP3)
        let fit = try XCTUnwrap(ColorChecker.fit(measured: custom.map { $0 * 0.5 }, reference: custom))
        XCTAssertLessThan(fit.maxAfter, 1e-6, "measuring exactly the custom chart fits it with no error")
        XCTAssertGreaterThan(try XCTUnwrap(ColorChecker.fit(measured: custom.map { $0 * 0.5 })).deltaEBefore[14], 1,
                             "the built-in table would call the same chart wrong")
    }
}
