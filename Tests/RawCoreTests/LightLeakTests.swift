import XCTest
@testable import RawCore

/// Light leak: pure plan/maths tests, plus the Core Image layer on synthetic frames (no RAW needed).
final class LightLeakTests: XCTestCase {
    let spec = LightLeakSpec.laPhong

    func plans(roll: String, count: Int = 36) -> [LightLeakPlan] {
        (1...count).map { LightLeakPlanner.plan(spec: spec, rollID: roll, frame: $0, count: count)! }
    }

    func testPlanIsDeterministic() {
        for f in [1, 2, 3, 18, 36] {
            XCTAssertEqual(LightLeakPlanner.plan(spec: spec, rollID: "roll-A", frame: f, count: 36),
                           LightLeakPlanner.plan(spec: spec, rollID: "roll-A", frame: f, count: 36))
        }
        XCTAssertNotEqual(LightLeakPlanner.seed(rollID: "roll-A", frame: 1), LightLeakPlanner.seed(rollID: "roll-B", frame: 1))
        XCTAssertNotEqual(LightLeakPlanner.seed(rollID: "roll-A", frame: 1), LightLeakPlanner.seed(rollID: "roll-A", frame: 2))
        XCTAssertNil(LightLeakPlanner.plan(spec: spec, rollID: "r", frame: 0, count: 36))
        XCTAssertNil(LightLeakPlanner.plan(spec: spec, rollID: "r", frame: 37, count: 36))
    }

    func testFramePatternOver36FrameRolls() {
        var third = 0, last = 0, middleLeaks = 0, middleFrames = 0
        let rolls = 400
        for r in 0..<rolls {
            let p = plans(roll: "roll-\(r)")
            // Frames 1-2: always, strong 0.6-0.9.
            for i in 0...1 {
                let l = try! XCTUnwrap(p[i].leak, "frame \(i + 1) always leaks")
                XCTAssertTrue((0.6...0.9).contains(l.strength))
                XCTAssertEqual(p[i].frameClass, .start)
            }
            if let l = p[2].leak { third += 1; XCTAssertTrue((0.3...0.5).contains(l.strength)) }
            if let l = p[35].leak { last += 1; XCTAssertTrue(spec.last.strength.contains(l.strength)); XCTAssertEqual(p[35].frameClass, .last) }
            var strongInRow = 0
            for i in 3..<35 {
                middleFrames += 1
                if let l = p[i].leak {
                    middleLeaks += 1
                    XCTAssertTrue((0.15...0.35).contains(l.strength), "middle leaks are faint")
                    if l.strength >= 0.6 { strongInRow += 1 }
                }
            }
            XCTAssertEqual(strongInRow, 0, "never a strong leak mid-roll, so never two in a row")
        }
        XCTAssertEqual(Double(third) / Double(rolls), 0.5, accuracy: 0.08)
        XCTAssertEqual(Double(last) / Double(rolls), 0.6, accuracy: 0.08)
        XCTAssertEqual(Double(middleLeaks) / Double(middleFrames), 0.12, accuracy: 0.02)
        print("[light-leak] \(rolls) rolls x 36: frame3 \(third), last \(last), middle \(middleLeaks)/\(middleFrames)")
    }

    func testPlacementShapeAndColour() {
        var edges = Set<LightLeakPlan.Edge>()
        for r in 0..<300 {
            for p in plans(roll: "p\(r)", count: 12) {
                guard let l = p.leak else { continue }
                edges.insert(l.edge)
                XCTAssertTrue(l.position <= 1.0 / 3 + 1e-6 || l.position >= 2.0 / 3 - 1e-6, "never the central third: \(l.position)")
                XCTAssertTrue((0...0.10).contains(l.coreOutside))
                let reach = l.sigma * spec.reachSigmas
                XCTAssertTrue((0.21 - 1e-4...0.39 + 1e-4).contains(reach), "reach 20-40 % of the width: \(reach)")
                XCTAssertTrue(abs(l.hueShift) <= 8)
                if let w = l.streak { XCTAssertTrue((0.05...0.12).contains(w)) }
                // Never magenta, pink or neon: hue between red-orange and yellow at every depth.
                for t in stride(from: Float(0), through: 1, by: 0.25) {
                    let c = LightLeakPlanner.colour(spec: spec, leak: l, t: t)
                    let lab = OKLab.fromLinearP3(c)
                    var h = atan2(lab.z, lab.y) * 180 / .pi; if h < 0 { h += 360 }
                    XCTAssertTrue((25...85).contains(h), "hue \(h) at t \(t)")
                    XCTAssertEqual(max(c.x, c.y, c.z), 1, accuracy: 1e-4)
                }
            }
        }
        XCTAssertEqual(edges, [.left, .right])
        let core = LightLeakPlanner.coreHue(spec)
        print("[light-leak] core hue \(core) deg")
        // The spec's numbers [1, .30, .06] give ~52 deg, its text says 35-45: recorded, not corrected (OPEN in WORK_LOG).
        XCTAssertEqual(core, 52, accuracy: 3)
    }

    func testPeakAddMatchesSpecAndFallsOff() throws {
        var leak = try XCTUnwrap(LightLeakPlanner.plan(spec: spec, rollID: "peak", frame: 1, count: 36)?.leak)
        leak.streak = nil
        let s = spec
        let cx: Float = leak.edge == .left ? 0 : 1
        // Evaluate at the core row, on the frame edge: dx = coreOutside.
        let atEdge = LightLeakPlanner.addition(spec: s, leak: leak, x: cx, y: leak.position, aspectWH: 1.5)
        let peak = s.peakAdd * s.amount * leak.strength
        XCTAssertLessThanOrEqual(atEdge.x, peak + 1e-6)
        XCTAssertGreaterThan(atEdge.x, peak * 0.4, "core sits 0-10 % outside, edge still strongly lit")
        // The far side of the frame gets nothing.
        let far = LightLeakPlanner.addition(spec: s, leak: leak, x: 1 - cx, y: leak.position, aspectWH: 1.5)
        XCTAssertLessThan(far.x, peak * 0.06)
    }

    #if canImport(CoreImage)
    func flat(_ w: Int, _ h: Int, _ v: CGFloat) -> CIImage {
        CIImage(color: CIColor(red: v, green: v, blue: v, colorSpace: Renderer.linearP3)!).cropped(to: CGRect(x: 0, y: 0, width: w, height: h))
    }
    let renderer = Renderer()

    func testLayerLiftsShadowsMoreAndNeverClips() throws {
        let leak = try XCTUnwrap(LightLeakPlanner.plan(spec: spec, rollID: "layer", frame: 1, count: 36)?.leak)
        var s = spec; s.amount = 1   // exaggerate so the cap is exercised
        let dark = try renderer.linearImage(FilmFinisher.lightLeak(flat(300, 200, 0.02), spec: s, leak: leak))
        let dark0 = try renderer.linearImage(flat(300, 200, 0.02))
        let hi = try renderer.linearImage(FilmFinisher.lightLeak(flat(300, 200, 0.9), spec: s, leak: leak))
        let hi0 = try renderer.linearImage(flat(300, 200, 0.9))
        let dGain = zip(dark.pixels, dark0.pixels).map { $0 - $1 }.max()!
        let hGain = zip(hi.pixels, hi0.pixels).map { $0 - $1 }.max()!
        XCTAssertGreaterThan(dGain, hGain, "screen lifts shadows more than highlights")
        XCTAssertGreaterThan(dGain, 0.01)
        let cap = Float(ColorMath.decodeTransfer(Double(s.encodedCap)))
        let blown = try renderer.linearImage(FilmFinisher.lightLeak(flat(300, 200, 0.97), spec: s, leak: leak))
        XCTAssertLessThanOrEqual(blown.pixels.max()!, max(0.97, cap) + 1e-3, "no new clip above the cap")
        XCTAssertGreaterThanOrEqual(zip(hi.pixels, hi0.pixels).map { $0 - $1 }.min()!, -1e-4, "never darkens")
    }

    func testPersonMaskAttenuates() throws {
        let leak = try XCTUnwrap(LightLeakPlanner.plan(spec: spec, rollID: "mask", frame: 1, count: 36)?.leak)
        var s = spec; s.amount = 1
        let base = flat(300, 200, 0.05)
        let white = CIImage(color: CIColor(red: 1, green: 1, blue: 1, colorSpace: Renderer.linearP3)!).cropped(to: CGRect(x: 0, y: 0, width: 30, height: 20))
        let plain = try renderer.linearImage(FilmFinisher.lightLeak(base, spec: s, leak: leak))
        let masked = try renderer.linearImage(FilmFinisher.lightLeak(base, spec: s, leak: leak, personMask: white))
        let ref = try renderer.linearImage(base)
        let gp = zip(plain.pixels, ref.pixels).map { $0 - $1 }.max()!, gm = zip(masked.pixels, ref.pixels).map { $0 - $1 }.max()!
        XCTAssertEqual(Double(gm / gp), Double(s.personFactor), accuracy: 0.05, "x0.4 inside the person mask")
    }

    func testPluginRoundTrip() throws {
        var finish = FilmFinish(); finish.lightLeak = spec
        var st = RenderSettings(mode: .explicit)
        let plugin = LightLeakPlugin()
        let ctx = PluginRenderContext(renderer: renderer, decodeBase: { self.flat(8, 8, 0.1) })
        let img = flat(300, 200, 0.05)
        // No roll position: nothing drawn, and it says so.
        var (out, why) = try plugin.afterFinish(img, settings: st, finish: finish, ctx: ctx)
        XCTAssertTrue(why.first?.contains("not set") ?? false)
        XCTAssertEqual(try renderer.linearImage(out).pixels, try renderer.linearImage(img).pixels)
        // Frame 1 of 36: leak, logged, deterministic.
        st.rollID = "r1"; st.rollFrameIndex = 1; st.rollFrameCount = 36
        let a = try plugin.afterFinish(img, settings: st, finish: finish, ctx: ctx)
        let b = try plugin.afterFinish(img, settings: st, finish: finish, ctx: ctx)
        XCTAssertTrue(a.1.joined().contains("seed") && a.1.joined().contains("edge") && a.1.joined().contains("strength") && a.1.joined().contains("hue"))
        let pa = try renderer.linearImage(a.0).pixels
        XCTAssertEqual(pa, try renderer.linearImage(b.0).pixels, "same roll + frame, same leak")
        XCTAssertNotEqual(pa, try renderer.linearImage(img).pixels)
        // No FilmFinish.lightLeak: no-op, no reasons.
        (out, why) = try plugin.afterFinish(img, settings: st, finish: FilmFinish(), ctx: ctx)
        XCTAssertTrue(why.isEmpty)
        // Removable: not in the list = not active.
        st.plugins = []
        XCTAssertTrue(try PluginRegistry.standard.active(for: st).isEmpty)
        st.plugins = nil
        XCTAssertTrue(try PluginRegistry.standard.active(for: st).contains { $0.id == "lightLeak" })
    }
    #endif

    func testOnlyLaPhongCarriesALeak() {
        for rs in RollStocks.all {
            XCTAssertEqual(rs.stock.finish.lightLeak != nil, rs.id == "rr-la-phong-100", rs.id)
        }
        XCTAssertTrue(FilmStock.all.allSatisfy { $0.finish.lightLeak == nil })
    }

    func testSettingsValidation() {
        var s = RenderSettings(mode: .explicit)
        s.rollFrameCount = 36; s.rollFrameIndex = 37
        XCTAssertThrowsError(try s.validate())
        s.rollFrameIndex = 36
        XCTAssertNoThrow(try s.validate())
        XCTAssertFalse(s.hasOverrides, "roll position is not a decode override")
    }

    // MARK: cameraMatch curve strength with a stock

    func testToneCurveBlendTowardIdentity() {
        let c: [SIMD2<Double>] = [SIMD2(0, 0), SIMD2(0.25, 0.4), SIMD2(0.5, 0.55), SIMD2(1, 1)]
        XCTAssertEqual(ToneMatch.blended(c, strength: 1), c)
        XCTAssertEqual(ToneMatch.blended(c, strength: 0).map(\.y), c.map(\.x))
        let h = ToneMatch.blended(c, strength: 0.5)
        XCTAssertEqual(h[1].y, 0.325, accuracy: 1e-12)
        XCTAssertEqual(ToneMatch.deviation(h), ToneMatch.deviation(c) / 2, accuracy: 1e-12)
        XCTAssertEqual(ToneMatch.blended(c, strength: 7), c, "clamped to 0...1")
        XCTAssertTrue(zip(h, h.dropFirst()).allSatisfy { $0.y <= $1.y }, "stays monotone")
        XCTAssertEqual(FilmStock.named("rr-sao-mai-200")?.develop?.cameraMatchCurveStrength, 0.5)
        XCTAssertNil(FilmStock.named("warm400")?.develop, "no develop profile: curve unchanged")
    }
}
