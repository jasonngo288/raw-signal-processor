import Foundation
import XCTest
@testable import RawCore

/// `LookSpec.vibrance` (RSP 0.3.0, prototype §5.B tests 1-5; placement per sign-off C5).
final class VibranceTests: XCTestCase {
    let gains = SIMD3<Float>(repeating: 1)

    /// (1) vibrance 0 skips the branch: every listed, trial and retired look gives the same LUT whatever `vibranceSkin` is
    /// (the 18 shipped looks are also pinned by `LookGuardTests`).
    func testZeroVibranceIsIdenticalForEveryLook() {
        for l in FilmLooks2026.looks + FilmLooks2026.trialLooks + FilmLooks2026.retiredLooks where l.spec.vibrance == 0 {
            var other = l.spec
            other.vibranceSkin = 0.9
            XCTAssertEqual(other.lut(size: 9).rgba, l.spec.lut(size: 9).rgba, l.name)
        }
    }

    /// (2) Grey stays grey: the grey drift does not change.
    func testGreyStaysGrey() {
        var v = LookSpec(); v.vibrance = 0.5
        for i in 1...9 {
            let g = SIMD3<Float>(repeating: Float(i) / 10)
            let a = OKLab.lch(encodedP3: LookSpec().apply(g, gains: gains)).y
            let b = OKLab.lch(encodedP3: v.apply(g, gains: gains)).y
            XCTAssertEqual(a, b, accuracy: 1e-4, "grey \(g.x)")
        }
    }

    /// (3) A low-chroma colour gains more than a high-chroma one (same hue family, outside skin).
    func testLowChromaGainsMore() {
        var v = LookSpec(); v.vibrance = 0.3
        func gain(_ c: SIMD3<Float>) -> Float {
            OKLab.lch(encodedP3: v.apply(c, gains: gains)).y / OKLab.lch(encodedP3: LookSpec().apply(c, gains: gains)).y
        }
        let mutedGreen = SIMD3<Float>(0.45, 0.55, 0.45), strongGreen = SIMD3<Float>(0.2, 0.75, 0.2)
        let mutedBlue = SIMD3<Float>(0.45, 0.5, 0.6), strongBlue = SIMD3<Float>(0.15, 0.3, 0.85)
        XCTAssertGreaterThan(gain(mutedGreen), gain(strongGreen) + 0.05)
        XCTAssertGreaterThan(gain(mutedBlue), gain(strongBlue) + 0.05)
        XCTAssertGreaterThan(gain(mutedGreen), 1.1)
        // Skin hue gets about half the gain (vibranceSkin 0.5).
        let skin = SIMD3<Float>(0.62, 0.5, 0.44), skinLike = OKLab.lch(encodedP3: skin)
        XCTAssertEqual(skinLike.z, 52, accuracy: 15)
        XCTAssertLessThan(gain(skin) - 1, (gain(mutedGreen) - 1) * 0.8)
    }

    /// (4) Hue moves at most 0.5° for vibrance up to 0.5.
    func testHueKept() {
        var rng = SplitMix64(seed: 0x51B_2026)
        for v in [Float(0.1), 0.3, 0.5] {
            var s = LookSpec(); s.vibrance = v
            var worst: Float = 0
            for _ in 0..<2000 {
                let c = SIMD3<Float>(Float.random(in: 0.05...0.95, using: &rng), Float.random(in: 0.05...0.95, using: &rng), Float.random(in: 0.05...0.95, using: &rng))
                let a = OKLab.lch(encodedP3: LookSpec().apply(c, gains: gains)), b = OKLab.lch(encodedP3: s.apply(c, gains: gains))
                guard a.y > 0.02 else { continue }
                var d = abs(a.z - b.z); if d > 180 { d = 360 - d }
                worst = max(worst, d)
            }
            XCTAssertLessThanOrEqual(worst, 0.5, "vibrance \(v): hue moved \(worst)°")
        }
    }

    /// (5) The LUT stays in gamut and monotone along greys.
    func testInGamutAndMonotoneGreys() {
        var s = LookSpec(); s.vibrance = 0.5
        let lut = s.lut(size: 17)
        XCTAssertTrue(lut.rgba.allSatisfy { $0 >= 0 && $0 <= 1 })
        var last: Float = -1
        for i in 0...64 {
            let y = (lut.apply(SIMD3(repeating: Float(i) / 64)) * Preset26.lumaEncoded).sum()
            XCTAssertGreaterThanOrEqual(y, last - 1e-4)
            last = y
        }
        for c in [SIMD3<Float>(0.9, 0.2, 0.1), SIMD3(0.1, 0.9, 0.2), SIMD3(0.1, 0.2, 0.95), SIMD3(0.95, 0.9, 0.1)] {
            let o = s.apply(c, gains: gains)
            XCTAssertTrue((0...0.99 + 1e-4).contains(o.max()) && o.min() >= 0, "\(c) -> \(o)")
        }
    }
}
