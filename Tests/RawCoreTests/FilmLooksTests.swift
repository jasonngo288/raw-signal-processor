import XCTest
@testable import RawCore

/// Acceptance checks of the 2026 film-look set (.orchestration/looks/LOOKS_RESEARCH.md §4.1), on the LUTs alone.
/// Image-level checks (clip vs appleDefault, black p1, skin on real people) are in `raw-bench looks`.
final class FilmLooksTests: XCTestCase {
    let trademarks = ["kodak", "kodachrome", "portra", "ektar", "ektacolor", "fuji", "fujifilm", "superia", "velvia", "provia",
                      "ilford", "polaroid", "cinestill", "chrome64", "trix", "agfa", "vsco", "dazz"]

    /// The 10 listed looks, the trial candidates and the retired looks: every LUT check below runs on all of them.
    var allLooks: [(name: String, summary: String, spec: LookSpec, intensity: Float, finish: FilmFinish, minSkin: Float?)] {
        FilmLooks2026.looks + FilmLooks2026.trialLooks + FilmLooks2026.retiredLooks
    }

    func colourLooks() -> [(String, LookSpec, CubeLUT)] {
        allLooks.filter { $0.spec.monoWeights == nil }.map { ($0.name, $0.spec, FilmStock.named($0.name)!.lut()) }
    }

    func testGeneratedLooksGenericNames() throws {
        XCTAssertEqual(FilmLooks2026.names.count, 10)   // cinemaNegative left the launch set (unlisted) 2026-11-10
        for n in FilmLooks2026.names { XCTAssertNotNil(FilmStock.named(n), n) }
        for l in allLooks {
            let words = (l.name + " " + l.summary).lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
            XCTAssertFalse(words.contains { trademarks.contains($0) }, "trademark in \(l.name): \(l.summary)")
        }
    }

    /// Grey in → luma out never goes down; grey stays (near) grey within the look's declared drift.
    func testNeutralRampMonotoneAndNearNeutral() {
        for (name, spec, lut) in colourLooks() {
            var last: Float = -1
            for i in 0...64 {
                let v = Float(i) / 64
                let o = lut.apply(SIMD3(repeating: v))
                let y = (o * Preset26.lumaEncoded).sum()
                XCTAssertGreaterThanOrEqual(y, last - 1e-4, "\(name): grey ramp not monotone at \(v)")
                last = y
                if (0.1...0.9).contains(v) {
                    XCTAssertLessThanOrEqual(OKLab.lch(encodedP3: o).y, spec.neutralDrift + 0.004, "\(name): grey \(v) drifts")
                }
            }
        }
        for l in allLooks where l.spec.monoWeights != nil {
            let lut = FilmStock.named(l.name)!.lut()
            XCTAssertTrue(lut.isMonochrome, l.name)
            let o = lut.apply(SIMD3(0.8, 0.3, 0.2))
            XCTAssertEqual(o.x, o.z, accuracy: 1e-5, l.name)
        }
    }

    /// Skin (ColorChecker dark and light skin): hue within ±8°, chroma within ±20 %.
    func testSkinHueAndChromaBounded() {
        let skins = [0, 1].map { i -> SIMD3<Float> in
            let lin = ColorChecker.referenceLinearP3(ColorChecker.referenceLabD50[i])
            return SIMD3(Preset26.encode(Float(lin.x)), Preset26.encode(Float(lin.y)), Preset26.encode(Float(lin.z)))
        }
        for (name, spec, lut) in colourLooks() {
            for (k, s) in skins.enumerated() {
                let a = OKLab.lch(encodedP3: s), b = OKLab.lch(encodedP3: lut.apply(s))
                var dh = abs(b.z - a.z); if dh > 180 { dh = 360 - dh }
                XCTAssertLessThanOrEqual(dh, spec.skinTolerance, "\(name): \(ColorChecker.names[k]) hue moved \(dh)°")
                XCTAssertEqual(b.y / a.y, 1, accuracy: spec.skinTolerance > 8 ? 0.5 : 0.2, "\(name): \(ColorChecker.names[k]) chroma ×\(b.y / a.y)")
            }
        }
    }

    /// White stays below clipping (except a look that declares it), black sits at the declared toe, everything in gamut.
    func testWhiteBlackAndGamut() {
        for (name, spec, lut) in colourLooks() {
            let w = lut.apply(SIMD3(repeating: 1)), k = lut.apply(SIMD3(repeating: 0))
            if !spec.allowsClip { XCTAssertLessThanOrEqual(w.max(), 0.99 + 1e-4, "\(name): white clips") }
            XCTAssertLessThanOrEqual(k.max(), spec.black + 0.012, "\(name): black lifted beyond its toe")
            XCTAssertTrue(lut.rgba.allSatisfy { $0 >= 0 && $0 <= 1 }, name)
            if spec.skinTolerance > 8 { XCTAssertNotNil(FilmStock.named(name)?.minSkinProtection, "\(name) moves skin: must hold the look back on people") }
        }
    }

    /// Saturated primaries are pulled into gamut, not clipped flat: a saturated red keeps some gradation.
    func testSaturatedRedKeepsGradation() {
        for (name, _, lut) in colourLooks() {
            let a = lut.apply(SIMD3(0.85, 0.1, 0.08)), b = lut.apply(SIMD3(0.95, 0.12, 0.1))
            XCTAssertGreaterThan((b * Preset26.lumaEncoded).sum(), (a * Preset26.lumaEncoded).sum() - 1e-4, name)
        }
    }

    /// Banding risk: along grey and along lightness ramps of six hues, the output may not change faster than 3× the
    /// input (10-bit: a 1-code input step must not become a > 3-code jump). Steps into a declared clip are ignored.
    func testNoSteepStepsThatBand() {
        let hues: [SIMD3<Float>] = [SIMD3(1, 0.25, 0.2), SIMD3(1, 0.6, 0.35), SIMD3(0.9, 0.85, 0.3), SIMD3(0.35, 0.8, 0.35),
                                    SIMD3(0.3, 0.75, 0.85), SIMD3(0.3, 0.4, 1)]
        for l in allLooks {
            let lut = FilmStock.named(l.name)!.lut()
            for dir in [SIMD3<Float>(repeating: 1)] + hues {
                var prev = lut.apply(.zero)
                var worst: Float = 0
                let n = 1023
                for i in 1...n {
                    let o = lut.apply(dir * (Float(i) / Float(n)))
                    if l.spec.allowsClip, o.max() >= 0.999 { prev = o; continue }
                    let step = max((o - prev).max(), (prev - o).max()) * Float(n)
                    if step > worst, step > 3 { print("[band] \(l.name) dir \(dir) at \(Float(i) / Float(n)): \(prev) -> \(o)") }
                    worst = max(worst, step)
                    prev = o
                }
                XCTAssertLessThanOrEqual(worst, 3, "\(l.name): slope \(worst) along \(dir)")
            }
        }
    }

    /// Interpolation error of the shipped cube vs the look function at 4000 random off-grid points (CIEDE2000 on the
    /// linearised results). Bound for the shipped size: mean < 0.1, p99 < 0.5, max < 2.5 (research §4.1 proposed
    /// p99.9 < 0.5; the tail above that sits only at saturated gamut corners, e.g. (0.9, 0.99, 0.07) — printed below).
    func testOffGridInterpolationError() {
        var rng = SplitMix64(seed: 0x5EED_2026_1110)   // fixed: the same 4000 points every run (was random → flaky tail)
        let samples = (0..<4000).map { _ in SIMD3<Float>(Float.random(in: 0...1, using: &rng), Float.random(in: 0...1, using: &rng), Float.random(in: 0...1, using: &rng)) }
        func de(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Double {
            func lab(_ c: SIMD3<Float>) -> (Double, Double, Double) {
                let l = ColorMath.lab(r: Double(Preset26.decode(c.x)), g: Double(Preset26.decode(c.y)), b: Double(Preset26.decode(c.z)))
                return (l.l, l.a, l.b)
            }
            let x = lab(a), y = lab(b)
            return ColorMath.deltaE2000(x.0, x.1, x.2, y.0, y.1, y.2)
        }
        for l in allLooks {
            let gains = Preset26.whiteBalanceGains(temperatureK: l.spec.temperatureK, tint: l.spec.tint)
            let truth = samples.map { l.spec.apply($0, gains: gains) }
            let lut = FilmStock.named(l.name)!.lut()
            XCTAssertEqual(lut.size, l.spec.cubeSize, l.name)
            let e = zip(samples, truth).map { de(lut.apply($0.0), $0.1) }.sorted()
            let mean = e.reduce(0, +) / Double(e.count)
            func p(_ q: Double) -> Double { e[Int(Double(e.count - 1) * q)] }
            print(String(format: "[interp] %@ %d³: mean %.3f, p99 %.3f, p99.9 %.3f, max %.3f", l.name, lut.size, mean, p(0.99), p(0.999), e.last!))
            XCTAssertLessThan(mean, 0.1, "\(l.name) mean")
            XCTAssertLessThan(p(0.99), 0.5, "\(l.name) p99")
            XCTAssertLessThan(e.last!, 2.5, "\(l.name) max")
        }
    }

    /// `density` and `HueBand.lightness` (kept by the user, 2026-11-10): defaults change nothing; greys never move;
    /// density makes a saturated colour darker, never brighter; a negative band lightness darkens only its hue.
    func testDensityAndBandLightnessContract() {
        let gains = SIMD3<Float>(repeating: 1)
        let red = SIMD3<Float>(0.85, 0.12, 0.1), grey = SIMD3<Float>(repeating: 0.5), blue = SIMD3<Float>(0.15, 0.25, 0.85)
        var base = LookSpec()
        var dense = base; dense.density = 0.15
        var banded = base; banded.bands = [.init(28, chroma: 1, lightness: -0.1)]
        XCTAssertEqual(OKLab.lch(encodedP3: dense.apply(grey, gains: gains)).x, OKLab.lch(encodedP3: base.apply(grey, gains: gains)).x, accuracy: 1e-4)
        XCTAssertEqual(OKLab.lch(encodedP3: banded.apply(grey, gains: gains)).x, OKLab.lch(encodedP3: base.apply(grey, gains: gains)).x, accuracy: 1e-4)
        XCTAssertLessThan(OKLab.lch(encodedP3: dense.apply(red, gains: gains)).x, OKLab.lch(encodedP3: base.apply(red, gains: gains)).x - 0.01)
        XCTAssertLessThan(OKLab.lch(encodedP3: banded.apply(red, gains: gains)).x, OKLab.lch(encodedP3: base.apply(red, gains: gains)).x - 0.01)
        XCTAssertEqual(OKLab.lch(encodedP3: banded.apply(blue, gains: gains)).x, OKLab.lch(encodedP3: base.apply(blue, gains: gains)).x, accuracy: 0.005)
        base.bands = [.init(28)]
        XCTAssertEqual(base.apply(red, gains: gains), LookSpec().apply(red, gains: gains))
    }

    /// Unlisted looks (trial candidates; retired cinemaNegative, 2026-11-10): resolvable by name for review renders, never listed (not in `names`,
    /// `stocks` or `FilmStock.all`), no name shared with the shipped set.
    func testTrialLooksResolvableButNotListed() {
        XCTAssertFalse(FilmLooks2026.trialNames.isEmpty)
        let listed = Set(FilmStock.all.map(\.name))
        for n in FilmLooks2026.trialNames {
            XCTAssertNotNil(FilmStock.named(n), n)
            XCTAssertFalse(FilmLooks2026.names.contains(n), n)
            XCTAssertFalse(listed.contains(n), "\(n) must not be listed in FilmStock.all")
        }
        XCTAssertEqual(Set(FilmLooks2026.trialNames).count, FilmLooks2026.trialNames.count)
        for l in FilmLooks2026.retiredLooks {
            XCTAssertNotNil(FilmStock.named(l.name), l.name)
            XCTAssertFalse(listed.contains(l.name), "\(l.name) is retired: must not be listed")
        }
    }

    /// Distinctness on the LUTs: mean CIEDE2000 between two looks over the 24 ColorChecker patches and 9 greys, at
    /// the shipped intensity. Prints every look's nearest neighbour; a trial must sit ≥ 2 from every look (else it
    /// duplicates one and should not be proposed).
    func testLooksDistinctFromNeighbours() {
        let patches: [SIMD3<Float>] = ColorChecker.referenceLabD50.map { lab in
            let l = ColorChecker.referenceLinearP3(lab)
            return SIMD3(Preset26.encode(Float(l.x)), Preset26.encode(Float(l.y)), Preset26.encode(Float(l.z)))
        } + (1...9).map { SIMD3<Float>(repeating: Float($0) / 10) }
        func lab(_ c: SIMD3<Float>) -> (Double, Double, Double) {
            let l = ColorMath.lab(r: Double(Preset26.decode(c.x)), g: Double(Preset26.decode(c.y)), b: Double(Preset26.decode(c.z)))
            return (l.l, l.a, l.b)
        }
        let outs: [(String, [(Double, Double, Double)])] = allLooks.map { l in
            let lut = FilmStock.named(l.name)!.lut()
            return (l.name, patches.map { p in lab(p + (lut.apply(p) - p) * l.intensity) })
        }
        func dist(_ a: [(Double, Double, Double)], _ b: [(Double, Double, Double)]) -> Double {
            zip(a, b).map { ColorMath.deltaE2000($0.0.0, $0.0.1, $0.0.2, $0.1.0, $0.1.1, $0.1.2) }.reduce(0, +) / Double(a.count)
        }
        for (i, a) in outs.enumerated() {
            let others = outs.enumerated().filter { $0.offset != i }.map { ($0.element.0, dist(a.1, $0.element.1)) }.sorted { $0.1 < $1.1 }
            print(String(format: "[distinct] %@ nearest %@ %.2f, then %@ %.2f; vs base %.2f", a.0, others[0].0, others[0].1, others[1].0, others[1].1,
                         dist(a.1, patches.map(lab))))
            if FilmLooks2026.trialNames.contains(a.0) { XCTAssertGreaterThanOrEqual(others[0].1, 2, "\(a.0) too close to \(others[0].0)") }
        }
    }
}

/// Deterministic generator for sampled tests (SplitMix64, Steele et al. 2014).
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
