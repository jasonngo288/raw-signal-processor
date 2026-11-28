#if canImport(CoreImage)
import CoreImage
import XCTest
@testable import RawCore

/// CALA M1-02 no-op contract, tests T0-T8 and T10 (design: MoodRollApp/.orchestration/film-lab/cala/m1/M1_02_NOOP_CONTRACT.md section 5.1).
/// T9 (all frames x all stocks vs the pin) is NOT here: it needs the app harness (moved to M3).
///
/// Production has no adapter and no validity enum yet. So the "adapter" and the "canary lever" below live ONLY in this test
/// target (`Adapter`, `Canary`); the validity they gate on is the production `LookAdaptationTrace.skin.maskValidity`
/// and `.reason`, which `Developer.finish` derives. What these tests prove: the comparison method (T0), that the trace
/// and the plumbing change no bit (T1, T2), that a gate reading production validity can keep a live lever at "same path as off"
/// (T3), that every skip has a production reason code (T4), and the invariants of stock, LUT and depth (T7, T8, T10).
/// They do NOT prove that a future production lever obeys the gate; that needs the lever (M3).
/// Bit-identical = `[Float]` `==` on `renderer.linearImage(out.image).pixels` (HeadroomTests pattern), no tolerance.
final class CALANoOpContractTests: XCTestCase {
    typealias T = LookAdaptationTrace

    // MARK: test-only adapter and canary (never in the library)

    /// A lever the test target owns. `gate` reads one production validity and a confidence the test supplies.
    struct Canary {
        let usableConfidence: Float = 0.5   // canary-only number: NOT a product threshold (none exists, DD 62 Q6)
        /// Returns nil (= "same path as off", no node built) unless the feature is `ok` AND the confidence is usable.
        func skipReason(validity: T.Validity, confidence: Float?) -> String? {
            switch validity {
            case .unavailable: return "unavailable"
            case .failed: return "failed"
            case .empty: return "empty"
            case .ok:
                guard let c = confidence else { return "okNoConfidence" }
                return c >= usableConfidence ? nil : "okLowConfidence"
            }
        }
    }

    /// Adapter off = `levers` nil. Wired but empty (null adapter) = `[]`. Neither touches the image.
    struct Adapter {
        var levers: [(validity: T.Validity, confidence: Float?)]?
        var skipLog: [String] = []
        func apply(to image: CIImage, renderer: Renderer) -> CIImage { image }
        mutating func run(image: CIImage, renderer: Renderer) -> CIImage {
            guard let levers else { return image }              // off: early return
            var out = image
            for l in levers {
                if let why = Canary().skipReason(validity: l.validity, confidence: l.confidence) { skipLog.append(why); continue }
                let dark = CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: image.extent)
                out = renderer.dissolve(from: out, to: dark, amount: 0.5)   // obvious pixel change: proves the canary is live
            }
            return out
        }
    }

    // MARK: helpers

    enum MaskState: CaseIterable { case noContext, diagNil, noCGImage, requestFailed, noResult, empty, ok, inconsistent }

    /// A synthetic frame (no file, no Vision) in one person-mask state of M1_02 3.1.
    func synthetic(_ st: RenderSettings, _ state: MaskState) throws -> (Developer, Developer.Base) {
        let dev = Developer()
        let rect = CGRect(x: 0, y: 0, width: 96, height: 64)
        let image = CIImage(color: CIColor(red: 0.4, green: 0.35, blue: 0.3)).cropped(to: rect)
        var c: SceneContext? = SceneContext(logP1: -12, logP50: -6.5, logP99: 1, dynamicRangeStops: 15, clippedFraction: 0.05, iso: 3200, faceCount: 1, labels: nil)
        c?.largestFaceArea = 0.05
        var mask: CIImage? = nil
        func diag(_ s: PersonMaskDiagnostics.Status, px: Int?) -> PersonMaskDiagnostics {
            var d = PersonMaskDiagnostics(status: s)
            if s == .requestFailed { d.error = "x 1" }
            d.pixelsAtLeast128 = px; d.width = 96; d.height = 64; d.maxValue = px == nil ? nil : (px == 0 ? 0 : 255)
            d.source = .balanced
            return d
        }
        let white = CIImage(color: CIColor(red: 1, green: 1, blue: 1)).cropped(to: rect)
        switch state {
        case .noContext: c = nil
        case .diagNil: c?.personMaskDiag = nil
        case .noCGImage: c?.personMaskDiag = diag(.noCGImage, px: nil)
        case .requestFailed: c?.personMaskDiag = diag(.requestFailed, px: nil)
        case .noResult: c?.personMaskDiag = diag(.noResult, px: nil)
        case .empty: c?.personMaskDiag = diag(.ok, px: 0)
        case .ok: c?.personMaskDiag = diag(.ok, px: 100); c?.personFraction = 0.2; mask = white
        case .inconsistent: c?.personMaskDiag = diag(.ok, px: 100); c?.personFraction = 0.2   // ok but no image
        }
        let recipe = DecodeRecipe(file: "synthetic", settings: st, decoderVersion: "synthetic", supportedDecoderVersions: [],
                                  defaults: HeadroomTests.defaults, effective: HeadroomTests.defaults, support: HeadroomTests.support,
                                  nativeSize: [96, 64], scaleFactor: 1, camera: nil, iso: nil, exposureTime: nil)
        let active = try dev.plugins.active(for: st)
        let pctx = PluginRenderContext(renderer: dev.renderer, decodeBase: { image }, scene: c ?? SceneContext(logP1: -12, logP50: -6.5, logP99: 1, dynamicRangeStops: 15, clippedFraction: 0.05, iso: 3200, faceCount: nil, labels: nil), decodeSceneLinear: nil)
        let base = Developer.Base(image: image, recipe: recipe, settings: st, context: c, personMask: mask,
                                  developedFor: nil, active: active, ran: [], pluginContext: pctx)
        return (dev, base)
    }

    func settings(stock: String = "goldenDay", trace: Bool? = nil, skin: Float? = 0.75) -> RenderSettings {
        var st = RenderSettings(mode: .explicit); st.stock = stock; st.skinProtection = skin; st.lookIntensityOffset = -0.05
        st.traceLookAdaptation = trace
        return st
    }

    func pixels(_ dev: Developer, _ out: Developer.Output) throws -> [Float] {
        let p = try dev.renderer.linearImage(out.image).pixels
        XCTAssertFalse(p.isEmpty)
        return p
    }

    /// L3: recipe JSON after dropping the new trace key, the trace flag, the timing text and the tie-order label text.
    func normalised(_ r: DecodeRecipe) -> String {
        var r = r
        r.lookAdaptation = nil
        r.settings.traceLookAdaptation = nil
        r.decisions = r.decisions.map {
            var s = $0
            s = s.replacingOccurrences(of: #"\d+\.\d+s"#, with: "Ts", options: .regularExpression)
            s = s.replacingOccurrences(of: #"\(top: [^)]*\)"#, with: "(top)", options: .regularExpression)
            return s
        }
        return r.compactJSON()
    }

    func dngFixtures() throws -> [(name: String, f: HeadroomTests.Fixture)] {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: HeadroomTests.originals.path)) ?? [])
            .filter { $0.lowercased().hasSuffix(".dng") }.sorted()
        if names.isEmpty { throw XCTSkip("no DNGs in originals/") }
        // Two frames only (USER_mooncake first, as the existing fixture): the full 6-DNG matrix took > 15 min per run.
        let pick = Array(([names.first(where: { $0 == "USER_mooncake.dng" })].compactMap { $0 } + names).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }.prefix(2))
        return try pick.map { n in
            let url = HeadroomTests.originals.appendingPathComponent(n)
            let dev = Developer()
            return (n, HeadroomTests.Fixture(dev: dev, url: url, scale: try dev.decoder.scaleFactor(url: url, longEdge: 256), an: try dev.analyze(url: url)))
        }
    }

    struct Render { let pixels: [Float]; let recipe: DecodeRecipe; let base: Developer.Base }
    func render(_ f: HeadroomTests.Fixture, _ st: RenderSettings, auto: Bool = true, analysis: Bool = true) throws -> Render {
        let b = try f.dev.developBase(url: f.url, settings: st, auto: auto, scaleFactor: f.scale, analysis: analysis ? f.an : nil)
        let out = try f.dev.finish(b)
        return Render(pixels: try pixels(f.dev, out), recipe: out.recipe, base: b)
    }

    /// Stocks by property, read from the library (never by remembered position): mono, skin-min 0.5, allowsClip, sky hold, light leak, plain.
    func stockSet() -> [(role: String, settings: RenderSettings)] {
        var out: [(String, RenderSettings)] = []
        for (role, name) in [("mono", "monoSoft"), ("minSkin0.5", "tungstenGlow"), ("flashDigicam", "flashDigicam"), ("plain", "goldenDay")] {
            out.append((role, settings(stock: name)))
        }
        if let sky = FilmStock.all.first(where: { $0.skyHoldAmount > 0 }) { out.append(("skyHold>0", settings(stock: sky.name))) }
        var leak = settings(stock: "rr-la-phong-100"); leak.rollID = "noop-contract"; leak.rollFrameIndex = 7; leak.rollFrameCount = 36
        if FilmStock.named("rr-la-phong-100") != nil { out.append(("lightLeak", leak)) }
        return out
    }

    // MARK: T0

    /// T0: precondition. Same input twice, adapter off, trace off: L1, L2, L3 equal. If this fails, nothing below may be read.
    func testT0_SelfEqualityAdapterOffTraceOff() throws {
        for (n, f) in try dngFixtures() {
            var st = RenderSettings(mode: .explicit); st.stock = "goldenDay"
            let a = try render(f, st), b = try render(f, st)
            XCTAssertTrue(a.pixels == b.pixels, "\(n) L1")
            XCTAssertEqual(a.recipe.qualityGuardStrength?.bitPattern, b.recipe.qualityGuardStrength?.bitPattern, "\(n) L2")
            XCTAssertEqual(normalised(a.recipe), normalised(b.recipe), "\(n) L3")
            XCTAssertNil(a.recipe.lookAdaptation)
        }
    }

    // MARK: T1

    /// T1: trace on vs absent. L1, L2 equal; L3 equal after dropping the new key. DNG frames x stocks by property, plus crop,
    /// plus every person-mask state on a synthetic frame. Also the tech-lead follow-up: `analysisReused` on the DNG trace.
    func testT1_TraceOnVsAbsent_DNG() throws {
        for (n, f) in try dngFixtures() {
            for (role, base) in stockSet() {
                for crop in [false, true] {
                    var off = base; off.traceLookAdaptation = nil
                    var on = base; on.traceLookAdaptation = true
                    if crop { let c = OutputCrop(x: 0, y: 0.03125, width: 1, height: 0.9375); off.outputCrop = c; on.outputCrop = c }
                    let a = try render(f, off), b = try render(f, on)
                    let tag = "\(n) \(role) crop=\(crop)"
                    XCTAssertTrue(a.pixels == b.pixels, "\(tag) L1")
                    XCTAssertEqual(a.recipe.qualityGuardStrength?.bitPattern, b.recipe.qualityGuardStrength?.bitPattern, "\(tag) L2")
                    XCTAssertEqual(normalised(a.recipe), normalised(b.recipe), "\(tag) L3")
                    XCTAssertNil(a.recipe.lookAdaptation, tag)
                    let t = try XCTUnwrap(b.recipe.lookAdaptation, tag)
                    XCTAssertEqual(t.frame.analysisReused, true, "\(tag): analysis was passed in, so it is reused")   // tech-lead follow-up
                    XCTAssertEqual(t.frame.finishOrder, crop ? .crop : .noCrop, tag)
                }
            }
        }
    }

    /// T1 follow-up: with no analysis passed in and `auto`, the frame is analysed here, so it is not reused.
    func testT1_AnalysisReusedFalseWhenNotPassedIn() throws {
        let f = try dngFixtures()[0].f
        var st = RenderSettings(mode: .explicit); st.stock = "goldenDay"; st.traceLookAdaptation = true
        let r = try render(f, st, analysis: false)
        XCTAssertEqual(try XCTUnwrap(r.recipe.lookAdaptation).frame.analysisReused, false)
    }

    func testT1_TraceOnVsAbsent_SyntheticEveryMaskState() throws {
        for state in MaskState.allCases {
            for (role, st) in stockSet() {
                var on = st; on.traceLookAdaptation = true
                let (dev, offBase) = try synthetic(st, state), (_, onBase) = try synthetic(on, state)
                let o = try dev.finish(offBase), p = try dev.finish(onBase)
                XCTAssertTrue(try pixels(dev, o) == pixels(dev, p), "\(state) \(role) L1")
                XCTAssertEqual(o.recipe.qualityGuardStrength?.bitPattern, p.recipe.qualityGuardStrength?.bitPattern, "\(state) \(role) L2")
                XCTAssertEqual(normalised(o.recipe), normalised(p.recipe), "\(state) \(role) L3")
            }
        }
    }

    // MARK: T2

    /// T2: adapter wired but empty (no levers) vs adapter off. L1, L2, L3 equal. DNG and synthetic.
    func testT2_NullAdapterEqualsOff() throws {
        for (n, f) in try dngFixtures() {
            for (role, st) in stockSet() {
                let b = try f.dev.developBase(url: f.url, settings: st, auto: true, scaleFactor: f.scale, analysis: f.an)
                let out = try f.dev.finish(b)
                var off = Adapter(levers: nil), null = Adapter(levers: [])
                let pOff = try f.dev.renderer.linearImage(off.run(image: out.image, renderer: f.dev.renderer)).pixels
                let pNull = try f.dev.renderer.linearImage(null.run(image: out.image, renderer: f.dev.renderer)).pixels
                XCTAssertTrue(pOff == pNull, "\(n) \(role) L1")
                XCTAssertTrue(pOff == (try pixels(f.dev, out)), "\(n) \(role): adapter off = no adapter")
                XCTAssertTrue(off.skipLog.isEmpty && null.skipLog.isEmpty)
                // L2/L3: a second full render with the adapter notionally wired changes neither guard strength nor recipe.
                let again = try render(f, st)
                XCTAssertEqual(out.recipe.qualityGuardStrength?.bitPattern, again.recipe.qualityGuardStrength?.bitPattern, "\(n) \(role) L2")
                XCTAssertEqual(normalised(out.recipe), normalised(again.recipe), "\(n) \(role) L3")
            }
        }
    }

    // MARK: T3 and T4

    /// T3: canary per feature state. unavailable, failed, empty, ok with nil or low confidence: L1 equal to off.
    /// ok with usable confidence: pixels DIFFER (the canary is live). The feature state is the production trace's `maskValidity`.
    /// T4 (in the same loop): every skip has the expected production reason code, and the canary logged it (no silent skip).
    /// Person mask only: face, sky and measured features have no production validity yet (see the skipped tests below).
    func testT3_T4_CanaryPerPersonMaskState() throws {
        let expect: [(MaskState, T.Validity, T.Reason?)] = [
            (.noContext, .unavailable, .noMaskUnavailable), (.diagNil, .unavailable, .noMaskUnavailable),
            (.noCGImage, .unavailable, .noMaskUnavailable), (.requestFailed, .failed, .noMaskFailed),
            (.noResult, .failed, .noMaskFailed), (.empty, .empty, .noMaskEmpty), (.inconsistent, .unavailable, .noMaskUnavailable),
            (.ok, .ok, nil)]
        for (state, validity, reason) in expect {
            var st = settings(trace: true)
            st.skinProtection = 0.75
            let (dev, base) = try synthetic(st, state)
            let out = try dev.finish(base)
            let t = try XCTUnwrap(out.recipe.lookAdaptation)
            XCTAssertEqual(t.skin.maskValidity, validity, "\(state)")          // T5 row, also checked here
            if let reason {
                XCTAssertEqual(t.skin.reason, reason, "\(state) T4: skin skip reason")   // T4
                XCTAssertEqual(t.skin.status, .skipped, "\(state)")
                XCTAssertEqual(t.skin.outcome, .skippedNoMask, "\(state)")
            } else {
                XCTAssertEqual(t.skin.status, .applied)
            }
            let img = out.image
            let ref = try dev.renderer.linearImage(img).pixels
            for conf: Float? in [nil, 0.1, 0.9] {
                var off = Adapter(levers: nil), on = Adapter(levers: [(t.skin.maskValidity, conf)])
                _ = off.run(image: img, renderer: dev.renderer)
                let p = try dev.renderer.linearImage(on.run(image: img, renderer: dev.renderer)).pixels
                if validity == .ok && conf == 0.9 {
                    XCTAssertFalse(p == ref, "\(state) conf \(conf!): canary must be live (pixels differ)")
                    XCTAssertTrue(on.skipLog.isEmpty)
                } else {
                    XCTAssertTrue(p == ref, "\(state) conf \(String(describing: conf)): gated lever is bit-identical to off")   // T3
                    XCTAssertEqual(on.skipLog.count, 1, "\(state) conf \(String(describing: conf)): the skip is recorded")        // T4
                    let want: String
                    switch validity { case .unavailable: want = "unavailable"; case .failed: want = "failed"; case .empty: want = "empty"
                    case .ok: want = conf == nil ? "okNoConfidence" : "okLowConfidence" }
                    XCTAssertEqual(on.skipLog.first, want)
                }
            }
        }
    }

    /// T3 on a DNG frame: a real analysis (whatever its person mask state is), canary with the production validity.
    func testT3_CanaryOnDNGFramesFollowsProductionValidity() throws {
        for (n, f) in try dngFixtures() {
            var st = settings(trace: true); st.skinProtection = 0.75
            let r = try render(f, st)
            let t = try XCTUnwrap(r.recipe.lookAdaptation)
            let img = try f.dev.finish(r.base).image
            let ref = try f.dev.renderer.linearImage(img).pixels
            var a = Adapter(levers: [(t.skin.maskValidity, nil)])
            XCTAssertTrue(try f.dev.renderer.linearImage(a.run(image: img, renderer: f.dev.renderer)).pixels == ref, "\(n): nil confidence = off (validity \(t.skin.maskValidity))")
            XCTAssertEqual(a.skipLog.count, 1)
        }
    }

    // MARK: T5

    /// T5: person-mask validity derivation. unavailable, failed, empty are distinct and match the table, incl. the inconsistent row.
    func testT5_PersonMaskValidityTable() throws {
        let want: [MaskState: T.Validity] = [.noContext: .unavailable, .diagNil: .unavailable, .noCGImage: .unavailable,
                                              .requestFailed: .failed, .noResult: .failed, .empty: .empty, .ok: .ok, .inconsistent: .unavailable]
        var seen = Set<T.Validity>()
        for state in MaskState.allCases {
            let (_, base) = try synthetic(settings(trace: true), state)
            let v = Developer.personMaskValidity(base)
            XCTAssertEqual(v, want[state], "\(state)")
            seen.insert(v)
        }
        XCTAssertEqual(seen, [.unavailable, .failed, .empty, .ok], "all four states are distinct")
    }

    // T5 rows 3.2-3.4 (M2-02): schema 9 column of M2_01 section 4. Pure functions over a synthetic SceneContext.
    func ctx(_ edit: (inout SceneContext) -> Void = { _ in }) -> SceneContext {
        var c = SceneContext(logP1: -12, logP50: -6.5, logP99: 1, dynamicRangeStops: 15, clippedFraction: 0.05, iso: 3200, faceCount: 1, labels: nil)
        edit(&c); return c
    }

    func testT5_FaceValidityTable() {
        XCTAssertEqual(Developer.faceValidity(nil), .init(.unavailable, reason: .noAnalysis))
        XCTAssertEqual(Developer.faceValidity(ctx { $0.faceCount = nil }), .init(.unavailable, reason: .unknown))
        XCTAssertEqual(Developer.faceValidity(ctx { $0.faceCount = 0 }), .init(.empty))
        XCTAssertEqual(Developer.faceValidity(ctx { $0.faceCount = 1 }), .init(.ok))
        XCTAssertEqual(Developer.faceValidity(ctx { $0.faceCount = 3 }).confidence, nil)
        // no `failed` on schema 9: a swallowed request error is nil, same as not run
        for n in [nil, 0, 2] as [Int?] { XCTAssertNotEqual(Developer.faceValidity(ctx { $0.faceCount = n }).state, .failed) }
    }

    func testT5_SkyValidityTable() {
        let sky = Developer.skyValidity
        XCTAssertEqual(sky(nil, false), .init(.unavailable, reason: .noAnalysis))
        XCTAssertEqual(sky(ctx { $0.skyMaskVersion = nil; $0.skyFraction = 0.5 }, true), .init(.unavailable, reason: .pluginOffAtAnalysis))
        XCTAssertEqual(sky(ctx { $0.skyMaskVersion = 3; $0.skyFraction = nil }, false), .init(.unavailable, reason: .gateUnavailable))
        XCTAssertEqual(sky(ctx { $0.skyMaskVersion = 3; $0.skyFraction = 0 }, false), .init(.empty))           // gate closed
        XCTAssertEqual(sky(ctx { $0.skyMaskVersion = 3; $0.skyFraction = 0.0099 }, true), .init(.empty))      // open, below min coverage
        XCTAssertEqual(sky(ctx { $0.skyMaskVersion = 3; $0.skyFraction = 0.01 }, true), .init(.ok))
        XCTAssertEqual(sky(ctx { $0.skyMaskVersion = 3; $0.skyFraction = 0.4 }, true).confidence, nil)
        XCTAssertEqual(sky(ctx { $0.skyMaskVersion = 3; $0.skyFraction = 0.4 }, false), .init(.unavailable, reason: .inconsistent))
        // the gate text is never parsed: same result whatever it says
        XCTAssertEqual(sky(ctx { $0.skyMaskVersion = 3; $0.skyFraction = 0.4; $0.skyGate = "label sky 0.9" }, true),
                       sky(ctx { $0.skyMaskVersion = 3; $0.skyFraction = 0.4; $0.skyGate = "garbage" }, true))
    }

    func testT5_MeasuredValidityRAW() {
        func mv(_ e: (inout SceneContext) -> Void) -> T.ContextValidity { Developer.measuredValidity(ctx(e), kind: .raw, skyMaskPresent: false) }
        let none = mv { _ in }
        XCTAssertEqual(none.sensorClip.state, .ok); XCTAssertEqual(none.night.state, .ok)
        XCTAssertEqual(none.displayClip, .init(.unavailable, reason: .noCameraReference))
        XCTAssertEqual(mv { $0.displayClippedFraction = 0 }.displayClip, .init(.ok))   // 0 is a measurement
        XCTAssertEqual(none.edrHeadroom, .init(.unavailable, reason: .notMeasured))
        XCTAssertEqual(mv { $0.edrHeadroom = 1.0 }.edrHeadroom, .init(.empty))
        XCTAssertEqual(mv { $0.edrHeadroom = 1.4 }.edrHeadroom, .init(.ok))
        XCTAssertEqual(mv { $0.edrHeadroom = 0.9 }.edrHeadroom, .init(.unavailable, reason: .inconsistent))
        XCTAssertEqual(mv { $0.cct = 5200 }.cctTint, .init(.ok))   // tint not required
        XCTAssertEqual(none.lumaQuantiles, .init(.ok))
        XCTAssertEqual(none.displayHistogram, .init(.unavailable, reason: .noHistogram))
        XCTAssertEqual(mv { $0.lumaHistogram = [1] }.displayHistogram, .init(.ok))
        XCTAssertEqual(none.ev100, .init(.unavailable, reason: .noValue))
        XCTAssertEqual(mv { $0.ev100 = 10; $0.ev100Version = 1 }.ev100, .init(.ok))
        XCTAssertEqual(mv { $0.ev100 = 10; $0.ev100Version = 2 }.ev100.state, .unavailable)
        XCTAssertEqual(none.cctTint.state, .unavailable)
        XCTAssertEqual(mv { $0.appleDecodeClippedFraction = 0.2 }.recoverableClip, .init(.ok))
        XCTAssertEqual(none.appleDecodeClip.state, .unavailable)
        // no analysis: everything unavailable
        let n = Developer.measuredValidity(nil, kind: .raw, skyMaskPresent: false)
        for f in [n.face, n.sky, n.sensorClip, n.displayClip, n.edrHeadroom, n.appleDecodeClip, n.recoverableClip, n.night, n.cctTint] { XCTAssertEqual(f.state, .unavailable) }
    }

    func testT5_MeasuredValidityHEICOnly() {
        func mv(_ e: (inout SceneContext) -> Void) -> T.ContextValidity { Developer.measuredValidity(ctx(e), kind: .heicOnly, skyMaskPresent: true) }
        let v = mv { $0.appleDecodeClippedFraction = 0.2; $0.edrHeadroom = 2; $0.cct = 5000; $0.tint = 0; $0.displayClippedFraction = 0.1 }
        let dr = T.FeatureValidity(.unavailable, reason: .displayReferred)
        XCTAssertEqual(v.sensorClip, dr); XCTAssertEqual(v.night, dr); XCTAssertEqual(v.appleDecodeClip, dr)
        XCTAssertEqual(v.recoverableClip, dr); XCTAssertEqual(v.edrHeadroom, dr)                        // even if a value is stored
        XCTAssertEqual(v.cctTint, .init(.unavailable, reason: .estimate))
        XCTAssertEqual(v.displayClip, .init(.unavailable, reason: .noHistogram))                       // HEIC: from lumaHistogram, not displayClippedFraction
        XCTAssertEqual(mv { $0.lumaHistogram = [Double](repeating: 1.0 / 64, count: 64) }.displayClip, .init(.ok))
        XCTAssertEqual(v.lumaQuantiles, .init(.ok, reason: .displayReferred))
    }

    /// M2S-03: sky ok in the analysis, sky plugin off in the render -> validity stays ok; the render gate is SkyHold.pluginOn only.
    func testT5_SkyValidityIgnoresRenderPlugin() throws {
        var st = settings(trace: true); st.skinProtection = 0.75
        var (_, base) = try synthetic(st, .ok)
        base.context?.skyMaskVersion = 3; base.context?.skyFraction = 0.4
        base.skyMask = CIImage(color: CIColor(red: 1, green: 1, blue: 1)).cropped(to: CGRect(x: 0, y: 0, width: 96, height: 64))
        base.active = base.active.filter { $0.id != "skyMask" }
        let t = Developer.adaptationTrace(base: base, settings: st, stock: nil, finish: nil, skin: nil, stockLookUsed: false, skinOutcome: .notRequested,
                                          lookOffset: (nil, nil, .none, .none), skyPath: .colourOnly, guardReport: nil, effectiveExposure: 0)
        XCTAssertEqual(t.contextValidity?.sky, .init(.ok))
        XCTAssertFalse(t.skyHold.pluginOn)
    }

    func testT5_TraceVersion2DecodesVersion1JSON() throws {
        XCTAssertEqual(T.currentVersion, 2)
        var st = settings(trace: true); st.skinProtection = 0.75
        let (_, base) = try synthetic(st, .ok)
        let t = Developer.adaptationTrace(base: base, settings: st, stock: nil, finish: nil, skin: nil, stockLookUsed: false, skinOutcome: .notRequested,
                                          lookOffset: (nil, nil, .none, .none), skyPath: .notApplicable, guardReport: nil, effectiveExposure: 0)
        XCTAssertNotNil(t.contextValidity)
        XCTAssertEqual(try JSONDecoder().decode(T.self, from: JSONEncoder().encode(t)), t)
        var obj = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(t)) as? [String: Any])
        obj.removeValue(forKey: "contextValidity"); obj["version"] = 1
        let old = try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: obj))
        XCTAssertNil(old.contextValidity); XCTAssertEqual(old.version, 1)
    }

    // MARK: T6

    /// T6: determinism. T0 plus trace JSON byte equality, same input rendered twice.
    func testT6_TraceDeterminism() throws {
        for (n, f) in try dngFixtures() {
            for (role, base) in stockSet() {
                var st = base; st.traceLookAdaptation = true
                let a = try render(f, st), b = try render(f, st)
                XCTAssertTrue(a.pixels == b.pixels, "\(n) \(role)")
                XCTAssertEqual(try XCTUnwrap(a.recipe.lookAdaptation).compactJSON(), try XCTUnwrap(b.recipe.lookAdaptation).compactJSON(), "\(n) \(role)")
            }
        }
    }

    // MARK: T7

    /// T7 (RSP half): stock, LUT and catalog-in-library unchanged by an adapter-on render; an adapter-off render after an
    /// adapter-on one equals the one before (cache not poisoned). The app half (catalog JSON bytes, `catalogRevision`) is app-level: not here.
    func testT7_Immutability() throws {
        let names = FilmStock.all.map(\.name)
        let lutsBefore = names.map { FilmStock.named($0)!.lut() }
        let f = try dngFixtures()[0].f
        var st = settings(trace: true); st.skinProtection = 0.75
        let before = try render(f, settings(trace: nil, skin: 0.75))
        let on = try render(f, st)
        var a = Adapter(levers: [(.ok, 0.9)])
        let img = try f.dev.finish(on.base).image
        _ = try f.dev.renderer.linearImage(a.run(image: img, renderer: f.dev.renderer))   // adapter-on render, canary live
        let after = try render(f, settings(trace: nil, skin: 0.75))
        XCTAssertTrue(before.pixels == after.pixels, "adapter-off after adapter-on equals the one before")
        XCTAssertEqual(FilmStock.all.map(\.name), names)
        for (i, n) in names.enumerated() { XCTAssertTrue(FilmStock.named(n)!.lut() == lutsBefore[i], "LUT of \(n) unchanged") }
        // Cache not poisoned by a depth variant either.
        let plain = FilmStock.named("citrus2")!.lut()
        _ = try FilmStock.resolve(look: "citrus2", arguments: LookArguments(depth: 0.6)).lut()
        XCTAssertTrue(FilmStock.named("citrus2")!.lut() == plain)
    }

    func testT7_CatalogBytesAndRevision_SKIPPED() throws {
        throw XCTSkip("T7 app half: catalog JSON bytes and `catalogRevision` live in the app (film-stocks.json), not in RSP. Belongs to MoodRollAppTests (camera-first-qa) or the M3 harness.")
    }

    // MARK: T8

    /// T8: depth untouched. `citrus2` depth 0.6, depth nil, a mono stock: resolved name and cube hash unchanged by the adapter;
    /// depth nil is byte-identical to the base look (ID-03).
    func testT8_DepthUntouched() throws {
        let base = FilmStock.named("citrus2")!
        let nilDepth = try FilmStock.resolve(look: "citrus2", arguments: LookArguments())
        XCTAssertEqual(nilDepth.name, "citrus2")
        XCTAssertTrue(nilDepth.lut() == base.lut(), "depth nil is byte-identical to the base look")
        let zero = try FilmStock.resolve(look: "citrus2", arguments: LookArguments(depth: 0))
        XCTAssertEqual(zero.name, "citrus2"); XCTAssertTrue(zero.lut() == base.lut(), "depth 0 = no depth")

        let deep = try FilmStock.resolve(look: "citrus2", arguments: LookArguments(depth: 0.6))
        XCTAssertEqual(deep.name, "citrus2~d0.60")
        let deepLut = deep.lut()
        XCTAssertFalse(deepLut == base.lut(), "sanity: depth 0.6 is a real variant")

        for (look, depth): (String, Float?) in [("citrus2", 0.6), ("citrus2", nil), ("monoSoft", 0.6), ("monoSoft", nil)] {
            var st = settings(stock: look, trace: true)
            st.lookArguments = LookArguments(depth: depth)
            let (dev, b) = try synthetic(st, .ok)
            let nameBefore = try st.resolvedStock()!.name, lutBefore = try st.resolvedStock()!.lut()
            let out = try dev.finish(b)
            var a = Adapter(levers: [(.ok, 0.9)])
            _ = try dev.renderer.linearImage(a.run(image: out.image, renderer: dev.renderer))
            XCTAssertEqual(try st.resolvedStock()!.name, nameBefore, "\(look) depth \(String(describing: depth))")
            XCTAssertTrue(try st.resolvedStock()!.lut() == lutBefore, "\(look) depth \(String(describing: depth))")
            XCTAssertEqual(try XCTUnwrap(out.recipe.lookAdaptation).frame.depth, depth, "trace records the caller depth, nothing else")
            // Trace on vs off with a depth stock: same pixels.
            var off = st; off.traceLookAdaptation = nil
            let (_, ob) = try synthetic(off, .ok)
            XCTAssertTrue(try pixels(dev, try dev.finish(ob)) == pixels(dev, out), "\(look) depth \(String(describing: depth)): trace changes no bit")
        }
        XCTAssertTrue(FilmStock.named("citrus2")!.lut() == base.lut(), "base look cache not poisoned by the depth variant")
    }

    // MARK: T9

    func testT9_AllFramesAllStocksVsPin_SKIPPED() throws {
        throw XCTSkip("T9 moved to M3: needs the app harness (all frames x all offered stocks, adapter off vs the pin). Not implemented here on purpose.")
    }

    // MARK: T10

    /// T10: the guard strength a preview chose equals the strength the final reports, bit for bit, and the final records it as given.
    /// Stocks where the guard fires (< 1) and where it does not are both asserted equal; which stocks fire is printed, not assumed.
    func testT10_PreviewGuardStrengthEqualsFinalGiven() throws {
        let f = try dngFixtures()[0].f
        var fired: [String] = [], passed: [String] = []
        for (role, base) in stockSet() {
            var st = base; st.traceLookAdaptation = true
            let preview = f.scale * 0.5
            let strength = try f.dev.previewGuardStrength(url: f.url, settings: st, auto: true, previewScaleFactor: preview, analysis: f.an)
            let final = try f.dev.developGuarded(url: f.url, settings: st, auto: true, scaleFactor: f.scale, previewScaleFactor: preview, analysis: f.an)
            XCTAssertEqual(final.recipe.qualityGuardStrength?.bitPattern, strength.bitPattern, "\(role) L2")
            let t = try XCTUnwrap(final.recipe.lookAdaptation, role).qualityGuard
            XCTAssertEqual(t.source, .given, role)
            XCTAssertEqual(t.strengthGiven?.bitPattern, strength.bitPattern, role)
            XCTAssertEqual(t.strengthFinal?.bitPattern, strength.bitPattern, role)
            XCTAssertEqual(t.measures, 0, "\(role): the final makes no measuring render")
            // Trace on or off, the strength is the same bits.
            var offSt = base; offSt.traceLookAdaptation = nil
            let off = try f.dev.developGuarded(url: f.url, settings: offSt, auto: true, scaleFactor: f.scale, previewScaleFactor: preview, analysis: f.an)
            XCTAssertEqual(off.recipe.qualityGuardStrength?.bitPattern, strength.bitPattern, "\(role) trace off")
            XCTAssertTrue(try pixels(f.dev, off) == pixels(f.dev, final), "\(role): trace on vs off, guarded final pixels")
            (strength < 1 ? { fired.append(role) } : { passed.append(role) })()
        }
        print("T10 guard fired (<1): \(fired); passed untouched (=1): \(passed)")
    }

    // MARK: tech-lead follow-up (item 66): v2 exposure bias

    /// On the v2 path `developBase` clears `settings.exposure`; the trace's `exposure.bias` must still be the caller's exposure
    /// (equal to `exposureNormalizer.ignoredCallerExposureEV`), not nil. Real v2 render on the DNG fixture; nil caller exposure stays nil.
    func testExposureBiasIsTheCallersOnTheV2Path() throws {
        let f = try dngFixtures()[0].f
        for caller: Float? in [0.3, -0.5, nil] {
            var st = RenderSettings(mode: .explicit); st.stock = "goldenDay"; st.exposureModel = .v2Normalizer
            st.exposure = caller; st.traceLookAdaptation = true
            let r = try render(f, st)
            XCTAssertEqual(r.recipe.settings.resolvedExposureModel, .v2Normalizer)
            let rec = try XCTUnwrap(r.recipe.exposureNormalizer, "v2 ran")
            XCTAssertEqual(rec.ignoredCallerExposureEV?.bitPattern, caller?.bitPattern)
            let t = try XCTUnwrap(r.recipe.lookAdaptation)
            XCTAssertEqual(t.exposure.bias?.bitPattern, caller?.bitPattern, "caller \(String(describing: caller))")
            XCTAssertEqual(t.exposure.bias, rec.ignoredCallerExposureEV)
            XCTAssertEqual(t.frame.exposureModel, "v2Normalizer")
        }
    }
}
#endif
