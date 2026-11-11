import XCTest
@testable import RawCore

final class Presets2026Tests: XCTestCase {
    let trademarks = ["kodak", "kodachrome", "portra", "fuji", "superia", "ilford", "polaroid", "cinestill", "dazz"]

    func testSevenPresetsNamedAndValid() throws {
        XCTAssertEqual(Preset26.all.count, 7)
        XCTAssertEqual(Set(Preset26.all.map(\.name)).count, 7)
        for p in Preset26.all {
            XCTAssertTrue(p.name.hasPrefix("PRESET_26_"), p.name)
            // Whole words (letters only): "PORTRAIT160" is the spec's own non-trademark name, not "portra".
            let words = p.name.lowercased().split { !$0.isLetter }.map(String.init)
            XCTAssertFalse(words.contains { trademarks.contains($0) }, "trademark in \(p.name)")
            XCTAssertNoThrow(try p.finish.validate(), p.name)
            XCTAssertNotNil(FilmStock.named(p.name), "\(p.name) usable as a stock")
            var s = RenderSettings(mode: .explicit); s.stock = p.name
            XCTAssertNoThrow(try s.validate())
        }
        XCTAssertEqual(Preset26.named("PRESET_26_SOCIAL_POP")?.intensity, 0.8)
        XCTAssertEqual(Preset26.named("PRESET_26_CPM35")?.intensity, 0.6)
        XCTAssertEqual(FilmStock.named("PRESET_26_PALM_SPRINGS")?.minSkinProtection, 0.5, "skinProtect: true")
        XCTAssertNil(FilmStock.named("PRESET_26_CHROME64")?.minSkinProtection)
        XCTAssertEqual(Preset26.named("PRESET_26_CPM35")?.finish.vignette, 0.25)
        XCTAssertEqual(Preset26.named("PRESET_26_CPM35")!.finish.grainSize, 0.084, accuracy: 1e-6)
        XCTAssertEqual(FilmStock.classic.count + 7 + FilmLooks2026.stocks.count, FilmStock.builtIn.count)   // `all` also holds run-time registered stocks (tests register some)
    }

    func testWhiteBalanceDirection() {
        let warm = Preset26.whiteBalanceGains(temperatureK: 5900, tint: 0)
        let cool = Preset26.whiteBalanceGains(temperatureK: 5400, tint: 0)
        let ref = Preset26.whiteBalanceGains(temperatureK: 5500, tint: 0)
        XCTAssertGreaterThan(warm.x / warm.z, 1.02, "higher K renders warmer (Lightroom semantics)")
        XCTAssertLessThan(cool.x / cool.z, 1, "lower K renders cooler")
        XCTAssertEqual(ref.x, 1, accuracy: 1e-4); XCTAssertEqual(ref.z, 1, accuracy: 1e-4)
        let green = Preset26.whiteBalanceGains(temperatureK: 5500, tint: -6)
        XCTAssertGreaterThan(green.y, green.x, "negative tint = green")
    }

    /// Spec §9.2 checks that can be run on the LUT alone.
    func testToneMonotoneHighlightsNotClippedWhitesNearNeutral() {
        for p in Preset26.all {
            let lut = p.lut(size: 33)
            var last: Float = -1
            for i in 0...40 {
                let g = Float(i) / 40
                let o = lut.apply(SIMD3(repeating: g))
                let y = (o * SIMD3<Float>(0.2126, 0.7152, 0.0722)).sum()
                XCTAssertGreaterThanOrEqual(y, last - 1e-3, "\(p.name) not monotone at \(g)")
                last = y
            }
            let white = lut.apply(SIMD3(repeating: 1))
            XCTAssertLessThan(white.max(), 0.995, "\(p.name): highlight clips")
            XCTAssertGreaterThan(white.min(), 0.85, "\(p.name): white goes grey")
            // White cast within ±5 % (grd-r is warm on purpose).
            let cast = (white.max() - white.min()) / white.max()
            XCTAssertLessThan(cast, p.specId == "grd-r" ? 0.08 : 0.05, "\(p.name) white cast \(white)")
        }
    }

    func testSaturatedRedStaysDenseNotClipped() {
        let lut = Preset26.named("PRESET_26_CHROME64")!.lut(size: 33)
        let o = lut.apply(SIMD3(0.80, 0.15, 0.10))
        XCTAssertLessThan(o.x, 0.999, "red channel not clipped (neon)")
        XCTAssertGreaterThan(o.x - o.z, 0.62, "red stays at least as saturated: \(o)")
    }

    func testNoShadowChromaBlowUp() {
        for p in Preset26.all {
            let lut = p.lut(size: 33)
            for c in [SIMD3<Float>(0.02, 0.004, 0.004), SIMD3<Float>(0.003, 0.003, 0.03), SIMD3<Float>(0.05, 0.03, 0.02)] {
                let o = lut.apply(c)
                XCTAssertLessThan(o.max() - o.min(), (c.max() - c.min()) * 2.5 + 0.03, "\(p.name) \(c) -> \(o)")
            }
        }
    }

    /// Sky hold (2026-11-11): bright blue keeps its chroma under the bright-airy presets and softPortrait; skin,
    /// foliage and greys are not touched by it; recipes written before the field still decode.
    func testSkyHoldKeepsSkyAndLeavesSkinAlone() throws {
        let sky = SIMD3<Float>(0.55, 0.70, 0.90), paleSky = SIMD3<Float>(0.70, 0.80, 0.92)
        let skin = SIMD3<Float>(0.80, 0.60, 0.50), leaf = SIMD3<Float>(0.35, 0.50, 0.25), grey = SIMD3<Float>(repeating: 0.6)
        func chroma(_ v: SIMD3<Float>) -> Float { let l = OKLab.fromLinearP3(SIMD3(Preset26.decode(v.x), Preset26.decode(v.y), Preset26.decode(v.z))); return (l.y * l.y + l.z * l.z).squareRoot() }
        XCTAssertEqual(Preset26.skyWeight(skin), 0); XCTAssertEqual(Preset26.skyWeight(leaf), 0); XCTAssertEqual(Preset26.skyWeight(grey), 0)
        XCTAssertGreaterThan(Preset26.skyWeight(sky), 0.99)
        for name in ["PRESET_26_PORTRAIT160", "PRESET_26_SOFT400"] {
            let p = try XCTUnwrap(Preset26.named(name))
            XCTAssertEqual(p.params.skyHold, 1, name)
            var off = p.params; off.skyHold = 0
            let gOn = Preset26.whiteBalanceGains(temperatureK: p.params.temperatureK, tint: p.params.tint) * pow(2, p.params.exposureEV)
            for c in [sky, paleSky] {
                let on = Preset26.apply(c, p.params, gains: gOn), without = Preset26.apply(c, off, gains: gOn)
                XCTAssertGreaterThan(chroma(on), chroma(without), "\(name) \(c)")
                XCTAssertGreaterThan(chroma(on), 0.93 * chroma(c), "\(name) sky keeps its chroma")
            }
            for c in [skin, leaf, grey] {
                XCTAssertEqual(Preset26.apply(c, p.params, gains: gOn), Preset26.apply(c, off, gains: gOn), "\(name) \(c) untouched")
            }
        }
        let soft = try XCTUnwrap(FilmLooks2026.looks.first { $0.name == "softPortrait" }).spec
        var softOff = soft; softOff.skyHold = 0
        let g = Preset26.whiteBalanceGains(temperatureK: soft.temperatureK, tint: soft.tint)
        XCTAssertGreaterThan(chroma(soft.apply(sky, gains: g)), chroma(softOff.apply(sky, gains: g)))
        XCTAssertEqual(soft.apply(skin, gains: g), softOff.apply(skin, gains: g))
        // Older recipes (no skyHold key) decode with the hold off.
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(Preset26.all[0].params)) as? [String: Any])
        json["skyHold"] = nil
        let old = try JSONDecoder().decode(PresetLookParams.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(old.skyHold, 0)
    }
}
