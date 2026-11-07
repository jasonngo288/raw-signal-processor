#if canImport(CoreImage)
import CoreImage
import XCTest
@testable import RawCore

/// Film finishing on synthetic images (no RAW needed).
final class FilmFinisherTests: XCTestCase {
    let renderer = Renderer()

    func flat(_ w: Int, _ h: Int, _ v: CGFloat) -> CIImage {
        CIImage(color: CIColor(red: v, green: v, blue: v, colorSpace: Renderer.linearP3)!).cropped(to: CGRect(x: 0, y: 0, width: w, height: h))
    }

    func lumaStats(_ img: LinearImage) -> (mean: Double, std: Double) {
        let y = img.displayLuminance().map(Double.init)
        let m = y.reduce(0, +) / Double(y.count)
        return (m, sqrt(y.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Double(y.count)))
    }

    func testGrainIsDeterministicSeededAndMeanPreserving() throws {
        let base = flat(400, 300, 0.18)
        let f = FilmFinish(grainAmount: 0.6, grainSize: 0.5, grainSeed: 7)
        let a = try renderer.linearImage(FilmFinisher.apply(base, f))
        let b = try renderer.linearImage(FilmFinisher.apply(base, f))
        XCTAssertEqual(a.pixels, b.pixels, "same seed, same grain")
        var f2 = f; f2.grainSeed = 8
        XCTAssertNotEqual(a.pixels, try renderer.linearImage(FilmFinisher.apply(base, f2)).pixels, "other seed, other grain")
        let s = lumaStats(a)
        XCTAssertEqual(s.mean, 0.18, accuracy: 0.18 * 0.03, "grain must not shift exposure")
        XCTAssertGreaterThan(s.std, 0.002, "grain is visible")
        XCTAssertEqual(a.pixels[0], a.pixels[1], accuracy: 1e-6, "monochrome grain: r == g")
    }

    /// The point of sizing grain by the short edge: a 2x larger render, viewed at the same size, has the same grain.
    func testGrainLooksTheSameAtAnyResolution() throws {
        let f = FilmFinish(grainAmount: 0.6, grainSize: 0.4, grainSeed: 3)
        let small = try renderer.linearImage(FilmFinisher.apply(flat(600, 400, 0.18), f))
        let large = try renderer.linearImage(FilmFinisher.apply(flat(1200, 800, 0.18), f)).downsampled(by: 2)
        let s = lumaStats(small).std, l = lumaStats(large).std
        print("[grain] std at 600x400: \(s), at 1200x800 viewed at 600x400: \(l)")
        XCTAssertEqual(l / s, 1, accuracy: 0.3)
    }

    func testGrainFadesTowardWhite() throws {
        let f = FilmFinish(grainAmount: 0.6, grainSize: 0.5, grainSeed: 5)
        let dark = lumaStats(try renderer.linearImage(FilmFinisher.apply(flat(300, 300, 0.10), f)))
        let bright = lumaStats(try renderer.linearImage(FilmFinisher.apply(flat(300, 300, 0.85), f)))
        XCTAssertLessThan(bright.std / bright.mean, dark.std / dark.mean, "relative grain is weaker in highlights")
    }

    func testHalationGlowsRedAroundBrightAreas() throws {
        let lamp = CIImage(color: CIColor(red: 1, green: 1, blue: 1, colorSpace: Renderer.linearP3)!)
            .cropped(to: CGRect(x: 180, y: 130, width: 40, height: 40))
        let scene = lamp.composited(over: flat(400, 300, 0.02))
        let out = try renderer.linearImage(FilmFinisher.apply(scene, FilmFinish(halationAmount: 0.6, halationThreshold: 0.7, halationRadius: 3)))
        let before = try renderer.linearImage(scene)
        let i = (150 * 400 + 235) * 3  // 15 px right of the lamp
        XCTAssertGreaterThan(out.pixels[i], before.pixels[i] + 0.01, "glow next to the lamp")
        XCTAssertGreaterThan(out.pixels[i], out.pixels[i + 1], "red > green")
        XCTAssertGreaterThan(out.pixels[i + 1], out.pixels[i + 2], "green > blue")
        XCTAssertEqual(out.pixels[3], before.pixels[3], accuracy: 1e-4, "far corner untouched")
    }

    func testVignetteDarkensCornersOnly() throws {
        let out = try renderer.linearImage(FilmFinisher.apply(flat(400, 300, 0.5), FilmFinish(vignette: 0.5)))
        let centre = out.pixels[(150 * 400 + 200) * 3], corner = out.pixels[(2 * 400 + 2) * 3]
        XCTAssertEqual(Double(centre), 0.5, accuracy: 0.02)
        XCTAssertLessThan(corner, centre - 0.03)
    }
}
#endif
