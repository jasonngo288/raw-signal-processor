import XCTest
@testable import RawCore

/// Roll stocks (RollStocks.swift): naming rules R1–R10 of docs/input/doi-ten-film-stock-RR-2026-11-11.md.
final class RollStocksTests: XCTestCase {
    /// Maker / product words that must never reach a name, vibe or summary (R1, R7). Whole words, case-insensitive.
    let banned: Set<String> = ["kodak", "fuji", "fujifilm", "portra", "ektar", "gold", "colorplus", "ultramax", "cinestill",
                               "ektacolor", "kodacolor", "koda", "reto", "retocolor", "proimage", "yesstar", "yes", "star",
                               "prism", "maple", "chrome", "velvia", "kodachrome", "superia", "vision", "vision3", "pro",
                               "lomo", "agfa", "ilford", "polaroid"]

    func words(_ s: String) -> [String] { s.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init) }

    /// ASCII slug of a Vietnamese name: strip diacritics, đ → d, spaces → "-".
    func slug(_ s: String) -> String {
        let folded = s.replacingOccurrences(of: "đ", with: "d").replacingOccurrences(of: "Đ", with: "D")
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "vi"))
        return folded.lowercased().split(separator: " ").joined(separator: "-")
    }

    /// 19 stocks: the brief's 21 minus RR Chuẩn 160 / 800 (same colour as RR Chuẩn 400, grain only; cut 2026-11-11).
    func testStocksNamedByTheRules() throws {
        let all = RollStocks.all
        XCTAssertEqual(all.count, 19)
        XCTAssertEqual(Set(all.map(\.id)).count, all.count)
        XCTAssertEqual(Set(all.map(\.nameVi)).count, all.count)
        XCTAssertEqual(Set(all.map(\.nameEn)).count, all.count)
        for r in all {
            // R2: "RR <1–2 words> <ISO>[T]"; R10: at most 3 syllables (Vietnamese words) between prefix and ISO.
            let parts = r.nameVi.split(separator: " ").map(String.init)
            XCTAssertEqual(parts.first, "RR", r.id)
            XCTAssertEqual(parts.last, "\(r.iso)\(r.tungsten ? "T" : "")", r.id)
            XCTAssertTrue((1...3).contains(parts.count - 2), r.id)
            // English name: same "RR <words> <ISO>[T]" shape, ASCII, set for every stock, unique.
            let en = r.nameEn.split(separator: " ").map(String.init)
            XCTAssertNotEqual(r.nameEn, r.nameVi, "\(r.id) has an English name")
            XCTAssertEqual(en.first, "RR", r.id); XCTAssertEqual(en.last, parts.last, r.id)
            XCTAssertTrue((1...2).contains(en.count - 2), r.id)
            XCTAssertTrue(r.nameEn.allSatisfy(\.isASCII), r.id)
            XCTAssertTrue(Set(words(r.nameEn)).isDisjoint(with: banned), "\(r.id): \(r.nameEn)")
            // R4: id is the ASCII slug of the Vietnamese name.
            XCTAssertEqual(r.id, slug(r.nameVi), r.nameVi)
            XCTAssertNotNil(r.id.range(of: "^rr-[a-z0-9-]+$", options: .regularExpression), r.id)
            // R1 / R6 / R7: no maker or product word anywhere the app or a recipe can show.
            for text in [r.nameVi, r.vibe, r.stock.summary, r.stock.name] {
                XCTAssertTrue(Set(words(text)).isDisjoint(with: banned), "\(r.id): \(text)")
            }
        }
    }

    func testEachStockDevelopsWithAColourLook() throws {
        for r in RollStocks.all {
            let base = try XCTUnwrap(FilmLooks2026.anyStock(named: r.look), "\(r.id) -> \(r.look)")
            XCTAssertNotEqual(r.look, "flashDigicam", "not a film stock (user, 2026-11-11)")
            if case .spec(let spec) = base.source { XCTAssertNil(spec.monoWeights, "\(r.id): colour stock on a mono look") }
            let stock = try XCTUnwrap(FilmStock.named(r.id), "\(r.id) resolves as a stock")
            XCTAssertEqual(stock.lookIntensity, r.intensity)
            XCTAssertNoThrow(try stock.finish.validate(), r.id)
            var s = RenderSettings(mode: .explicit); s.stock = r.id
            XCTAssertNoThrow(try s.validate(), r.id)
            XCTAssertFalse(FilmStock.all.contains { $0.name == r.id }, "\(r.id): roll stocks are not in the bench list")
            XCTAssertEqual(stock.finish.vignette, base.finish.vignette, "\(r.id) keeps the look's vignette")
            XCTAssertEqual(stock.finish.halationAmount, base.finish.halationAmount, "\(r.id) keeps the look's halation")
        }
    }

    /// R5: one stock, one role. Two stocks on the same look differ in ISO, or (same ISO) by at least 0.2 intensity.
    func testNoTwoStocksPlayTheSameRole() {
        let all = RollStocks.all
        for (i, a) in all.enumerated() {
            for b in all[(i + 1)...] where a.look == b.look && a.iso == b.iso && a.tungsten == b.tungsten {
                XCTAssertGreaterThanOrEqual(abs(a.intensity - b.intensity), 0.2, "\(a.id) vs \(b.id)")
            }
        }
    }

    /// Mean CIEDE2000 between two stocks over the 24 ColorChecker patches and 9 greys, each at its own intensity
    /// (grain not included: it is the same at the same ISO).
    func chartDistance(_ a: RollStock, _ b: RollStock) -> Double {
        let patches: [SIMD3<Float>] = ColorChecker.referenceLabD50.map { lab in
            let l = ColorChecker.referenceLinearP3(lab)
            return SIMD3(Preset26.encode(Float(l.x)), Preset26.encode(Float(l.y)), Preset26.encode(Float(l.z)))
        } + (1...9).map { SIMD3<Float>(repeating: Float($0) / 10) }
        func lab(_ c: SIMD3<Float>) -> (Double, Double, Double) {
            let l = ColorMath.lab(r: Double(Preset26.decode(c.x)), g: Double(Preset26.decode(c.y)), b: Double(Preset26.decode(c.z)))
            return (l.l, l.a, l.b)
        }
        let la = a.stock.lut(), lb = b.stock.lut()
        return patches.map { p in
            let x = lab(p + (la.apply(p) - p) * a.intensity), y = lab(p + (lb.apply(p) - p) * b.intensity)
            return ColorMath.deltaE2000(x.0, x.1, x.2, y.0, y.1, y.2)
        }.reduce(0, +) / Double(patches.count)
    }

    /// No near-duplicates (user, 2026-11-11: "để user khỏi lăn tăn"): two stocks at the same ISO must differ in colour
    /// by ≥ 2 chart ΔE00, not only in intensity. Prints the matrix of stocks that share a look (they differ by ISO).
    func testSameISOStocksLookDifferent() {
        let all = RollStocks.all
        for (i, a) in all.enumerated() {
            for b in all[(i + 1)...] {
                let d = chartDistance(a, b)
                if a.look == b.look { print(String(format: "[shared] %@ vs %@ (%@): %.2f", a.id, b.id, a.look, d)) }
                if a.iso == b.iso && a.tungsten == b.tungsten {
                    XCTAssertGreaterThanOrEqual(d, 2, "\(a.id) vs \(b.id): same ISO, too close in colour")
                }
            }
        }
    }

    /// Matrix for the stocks that shared a look before 2026-11-11 (RR_LOOKS_2026-11-11.md). Print only.
    func testPrintFormerlySharedMatrix() {
        let groups = [["rr-vang-200", "rr-am-200", "rr-nang-100"], ["rr-ruc-ro-100", "rr-la-phong-100", "rr-ruc-400"],
                      ["rr-da-mem-160", "rr-chan-dung-400", "rr-dem-mem-800"], ["rr-chuan-400"]]
        let old: [String: (String, Float)] = ["rr-vang-200": ("goldenDay", 0.85), "rr-am-200": ("goldenDay", 0.60), "rr-nang-100": ("goldenDay", 0.95),
            "rr-ruc-ro-100": ("vividFine", 0.95), "rr-la-phong-100": ("vividFine", 0.65), "rr-ruc-400": ("vividFine", 0.75),
            "rr-da-mem-160": ("softPortrait", 0.85), "rr-chan-dung-400": ("softPortrait", 0.70), "rr-dem-mem-800": ("softPortrait", 0.75),
            "rr-chuan-400": ("brightTravel", 0.55)]
        let identity = RollStock(id: "identity", nameVi: "", iso: 400, tungsten: false, look: "cleanLab", intensity: 0, vibe: "")
        for g in groups {
            for (i, a) in g.enumerated() {
                let na = RollStocks.named(a)!
                var oa = na; oa.id = a + "-old"; oa.look = old[a]!.0; oa.intensity = old[a]!.1
                print(String(format: "[matrix] %@ vs base: before %.2f after %.2f", a, chartDistance(oa, identity), chartDistance(na, identity)))
                for b in g[(i + 1)...] {
                    let nb = RollStocks.named(b)!
                    var ob = nb; ob.id = b + "-old"; ob.look = old[b]!.0; ob.intensity = old[b]!.1
                    print(String(format: "[matrix] %@ vs %@: before %.2f after %.2f", a, b, chartDistance(oa, ob), chartDistance(na, nb)))
                }
            }
        }
    }

    func testGrainGrowsWithISO() {
        let isos = [100, 160, 200, 400, 800]
        for (a, b) in zip(isos, isos.dropFirst()) {
            XCTAssertLessThan(RollStock.grain(iso: a).amount, RollStock.grain(iso: b).amount)
            XCTAssertLessThan(RollStock.grain(iso: a).size, RollStock.grain(iso: b).size)
        }
        let night = RollStocks.named("rr-den-vang-800t")!.stock.finish, fine = RollStocks.named("rr-ruc-ro-100")!.stock.finish
        XCTAssertGreaterThan(night.grainAmount, fine.grainAmount)
        // With the per-look multiplier, shipped stocks still order by box ISO: every stock is grainier than every
        // stock of a lower ISO (a clean lab 400 is finer than the other 400s, not finer than a 200).
        for a in RollStocks.all {
            for b in RollStocks.all where a.iso < b.iso {
                XCTAssertLessThan(a.stock.finish.grainAmount, b.stock.finish.grainAmount, "\(a.id) vs \(b.id)")
                XCTAssertLessThan(a.stock.finish.grainSize, b.stock.finish.grainSize, "\(a.id) vs \(b.id)")
            }
        }
        XCTAssertLessThan(RollStocks.named("rr-chuan-400")!.stock.finish.grainAmount,
                          RollStocks.named("rr-chan-dung-400")!.stock.finish.grainAmount)
        // The multiplier stays a gentle character offset (amount only, within 0.7...1.0).
        for s in RollStocks.all {
            guard case .iso(let scale)? = s.arguments.grain else { XCTFail("\(s.id): grain must be the ISO form"); continue }
            XCTAssert((0.7...1.0).contains(scale), s.id)
        }
    }

    // MARK: filmDevelop (pure rule)

    func params(sharp: Float = 0.89, detail: Float = 0, ltm: Float = 0, lumaNR: Float = 0) -> DecodeParameters {
        DecodeParameters(exposure: 0, baselineExposure: 0, shadowBias: 0, boostAmount: 1, boostShadowAmount: 0.9,
                         localToneMapAmount: ltm, sharpnessAmount: sharp, contrastAmount: 0, detailAmount: detail,
                         luminanceNoiseReductionAmount: lumaNR, colorNoiseReductionAmount: 0.4, moireReductionAmount: 0,
                         extendedDynamicRangeAmount: 0, lensCorrection: false, gamutMapping: true, neutralTemperature: 5000, neutralTint: 0)
    }
    func scene(face: Double? = nil) -> SceneContext {
        var c = SceneContext(logP1: -8, logP50: -3, logP99: 0, dynamicRangeStops: 6, clippedFraction: 0, iso: 50, faceCount: face == nil ? 0 : 1, labels: nil)
        c.largestFaceArea = face
        return c
    }

    func testRollStockDevelopProfiles() throws {
        func dev(_ id: String) throws -> FilmDevelop { try XCTUnwrap(FilmStock.named(id)?.develop, id) }
        XCTAssertEqual(try dev("rr-vang-200").sharpScale, 0.55); XCTAssertNil(try dev("rr-vang-200").lumaNRMaxDelta)
        XCTAssertEqual(try dev("rr-sao-hom-400").sharpScale, 0.50); XCTAssertEqual(try dev("rr-sao-hom-400").lumaNRMaxDelta, 0)
        XCTAssertEqual(try dev("rr-ruc-ro-100").sharpScale, 0.70)
        XCTAssertEqual(try dev("rr-ruc-400").sharpScale, 0.70)
        XCTAssertEqual(try dev("rr-da-mem-160").sharpScale, 0.50)
        XCTAssertEqual(try dev("rr-dem-mem-800").sharpScale, 0.50)
        XCTAssertEqual(try dev("rr-dem-mem-800").profile, "iso400-1599+portrait")
        XCTAssertNil(FilmStock.named("warm400")?.develop, "classic stocks keep Apple's decode")
        XCTAssertNil(FilmStock.all.first { $0.name != "" && $0.develop != nil }, "only roll stocks carry a develop profile")
    }

    func testFilmDevelopScalesAndLogs() {
        let d = params()
        var st = RenderSettings.explicit
        st.highlightClarity = 0.4
        let fd = FilmStock.named("rr-sao-mai-200")!.develop!
        let why = fd.apply(context: scene(), defaults: d, settings: &st)
        XCTAssertEqual(st.sharpnessAmount!, 0.89 * 0.55, accuracy: 1e-5)
        XCTAssertEqual(st.highlightClarity!, 0.16, accuracy: 1e-5)
        XCTAssertNil(st.contrastAmount); XCTAssertNil(st.boostAmount); XCTAssertNil(st.boostShadowAmount)
        XCTAssertEqual(why.count, 2)
        XCTAssertTrue(why.allSatisfy { $0.hasPrefix("develop iso<400") })
        // Floor: Pixel-like default 0.5 x 0.50 = 0.25 -> 0.30; never raised above the default.
        var s2 = RenderSettings.explicit
        _ = FilmStock.named("rr-sao-hom-400")!.develop!.apply(context: scene(), defaults: params(sharp: 0.5), settings: &s2)
        XCTAssertEqual(s2.sharpnessAmount!, 0.30, accuracy: 1e-5)
        var s3 = RenderSettings.explicit
        _ = fd.apply(context: scene(), defaults: params(sharp: 0.1), settings: &s3)
        XCTAssertNil(s3.sharpnessAmount, "default below the floor is left alone")
    }

    func testFilmDevelopFaceLumaNRAndProRAW() {
        let fd = FilmStock.named("rr-sao-hom-400")!.develop!
        // Face: extra -0.05 below the scaled value; DecisionEngine's own -0.10 is not stacked (min of both).
        var st = RenderSettings.explicit
        st.sharpnessAmount = 0.79
        _ = fd.apply(context: scene(face: 0.05), defaults: params(), settings: &st)
        XCTAssertEqual(st.sharpnessAmount!, 0.89 * 0.50 - 0.05, accuracy: 1e-5)
        // Luma NR: DecisionEngine's +0.10 (ISO >= 800) is taken back to Apple's default for 400...1599.
        var nr = RenderSettings.explicit
        nr.luminanceNoiseReductionAmount = 0.10
        let why = fd.apply(context: scene(), defaults: params(), settings: &nr)
        XCTAssertEqual(nr.luminanceNoiseReductionAmount!, 0, accuracy: 1e-6)
        XCTAssertTrue(why.contains { $0.contains("luminanceNR") })
        XCTAssertNil(nr.colorNoiseReductionAmount, "colour NR kept")
        // ProRAW (default LTM > 0): detail 0.5 -> 0.2, LTM untouched by default.
        var pr = RenderSettings.explicit
        _ = fd.apply(context: scene(), defaults: params(sharp: 1, detail: 0.5, ltm: 1), settings: &pr)
        XCTAssertEqual(pr.detailAmount!, 0.2, accuracy: 1e-6)
        XCTAssertNil(pr.localToneMapAmount)
        // Bayer: detail untouched.
        var by = RenderSettings.explicit
        _ = fd.apply(context: scene(), defaults: params(), settings: &by)
        XCTAssertNil(by.detailAmount)
    }

    func testFaceRuleLowersSharpnessWhenDetailIsZero() {
        let s = DecoderSupport(localToneMap: false, sharpness: true, contrast: true, detail: true, luminanceNoiseReduction: true,
                               colorNoiseReduction: true, moireReduction: true, lensCorrection: false, maxExtendedDynamicRange: 2)
        let dec = DecisionEngine.decide(context: scene(face: 0.05), defaults: params(), support: s)
        XCTAssertEqual(dec.settings.sharpnessAmount!, 0.79, accuracy: 1e-5)
        XCTAssertNil(dec.settings.detailAmount)
        XCTAssertTrue(dec.reasons.contains { $0.contains("sharpness 0.89 -> 0.79") })
        let pro = DecisionEngine.decide(context: scene(face: 0.05), defaults: params(sharp: 1, detail: 0.5), support: s)
        XCTAssertEqual(pro.settings.detailAmount!, 0.4, accuracy: 1e-5, "ProRAW still lowers detail")
        XCTAssertNil(pro.settings.sharpnessAmount)
    }
}
