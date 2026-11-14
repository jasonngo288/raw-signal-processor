#if canImport(CoreImage)
import CoreImage
import XCTest
@testable import RawCore

/// P1.1 identity (T2): every roll stock resolved from its id must equal the same look + `LookArguments`, field for field
/// (except `name` / `summary`), LUT value for LUT value and pixel for pixel. The first baseline was captured from RSP
/// 0.1.0 (7a304c5) before the refactor. RSP 0.3.0 (sign-off C7) hashes an explicit source identity instead of
/// `String(describing: source)`, so a new `LookSpec` field no longer breaks the file; `Fixtures/rollstocks-0.3.0-baseline.json`
/// was regenerated once, with only the `fields` text changing (`lut` and `pixels` equal to 0.1.0)
/// (`RSP_WRITE_BASELINE=1 swift test --filter LookArgumentsTests/testRollStocksMatchTheBaseline`).
final class LookArgumentsTests: XCTestCase {
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let baselineURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures/rollstocks-0.3.0-baseline.json")

    struct Baseline: Codable {
        struct Entry: Codable, Equatable {
            var id: String
            var fields: String
            var lut: String
            var pixels: String?
        }
        var engine: String
        var fixture: String?
        var environment: String
        var entries: [Entry]
    }

    /// The fixture DNG: USER_mooncake (a person, so skin protection and the person mask take part), else the first DNG.
    func fixture() throws -> URL {
        let dir = Self.root.appendingPathComponent("originals")
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.lowercased().hasSuffix(".dng") }.sorted()
        guard let n = names.first(where: { $0 == "USER_mooncake.dng" }) ?? names.first else { throw XCTSkip("no DNGs in originals/") }
        return dir.appendingPathComponent(n)
    }

    /// OS build + CPU: pixel hashes are compared only on the environment that wrote them (GPU / Core Image may differ).
    static var environment: String {
        var sys = utsname(); uname(&sys)
        let machine = withUnsafeBytes(of: &sys.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        return "\(ProcessInfo.processInfo.operatingSystemVersionString) \(machine)"
    }

    static func fnv(_ values: [Float]) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for v in values {
            var b = v.bitPattern
            for _ in 0..<4 { h = (h ^ UInt64(b & 0xff)) &* 0x100000001b3; b >>= 8 }
        }
        return String(format: "%016llx", h)
    }

    /// Stable identity of the look source: the case and the look name (LUT values are guarded by `lut`, pixels by
    /// `pixels`), never `String(describing:)`, whose text changes with every new `LookSpec` field.
    static func sourceIdentity(_ s: FilmStock, look: String) -> String {
        switch s.source {
        case .builtIn(let b): return "builtIn(\(b.rawValue))"
        case .preset: return "preset(\(look))"
        case .spec: return "spec(\(look))"
        }
    }

    /// Every `FilmStock` field except `name` and `summary`; `look` is the look the stock is built on.
    static func fields(_ s: FilmStock, look: String) -> String {
        ["source=\(sourceIdentity(s, look: look))", "intensity=\(s.lookIntensity.bitPattern)", "finish=\(s.finish.compactJSON())",
         "skin=\(s.allowsSkinProtection)", "minSkin=\(s.minSkinProtection.map { "\($0.bitPattern)" } ?? "nil")",
         "input=\(s.lookInput)", "space=\(s.lookColorSpace)", "prim=\(s.logPrimaries)",
         "develop=\(s.develop?.compactJSON() ?? "nil")"].joined(separator: " | ")
    }

    /// LUT values only (no title).
    static func lutFingerprint(_ s: FilmStock) -> String {
        let l = s.lut()
        return "\(l.size):" + fnv(l.rgba)
    }

    /// Frame 1 of 24, so the light leak of rr-la-phong-100 is drawn too.
    static func settings(_ stock: String) -> RenderSettings {
        var st = RenderSettings(mode: .explicit)
        st.stock = stock
        st.rollID = "rsp-p1.1"; st.rollFrameIndex = 1; st.rollFrameCount = 24
        return st
    }

    func render(_ st: RenderSettings, dev: Developer, url: URL, scale: Float, analysis: Developer.Analysis) throws -> [Float] {
        let out = try dev.develop(url: url, settings: st, auto: true, scaleFactor: scale, analysis: analysis)
        return try dev.renderer.linearImage(out.image).pixels
    }

    func current(withPixels: Bool) throws -> Baseline {
        let url = try fixture()
        let dev = Developer()
        let scale = try dev.decoder.scaleFactor(url: url, longEdge: 384)
        let an = try dev.analyze(url: url)
        var entries: [Baseline.Entry] = []
        for r in RollStocks.all {
            let s = try XCTUnwrap(FilmStock.named(r.id), r.id)
            let px = withPixels ? Self.fnv(try render(Self.settings(r.id), dev: dev, url: url, scale: scale, analysis: an)) : nil
            entries.append(.init(id: r.id, fields: Self.fields(s, look: r.look), lut: Self.lutFingerprint(s), pixels: px))
        }
        return Baseline(engine: "0.3.0", fixture: url.lastPathComponent, environment: Self.environment, entries: entries)
    }

    /// P1.1: the rr-… path still gives what 0.1.0 gave (same fields, same LUT values, same pixels; pixels against the
    /// file only on the machine / OS that wrote it), and `stock = <look>` + `lookArguments` gives exactly the rr-… result.
    func testRollStocksMatchTheBaselineAndLookArguments() throws {
        if ProcessInfo.processInfo.environment["RSP_WRITE_BASELINE"] == "1" {
            let b = try current(withPixels: true)
            try Data(b.prettyJSON().utf8).write(to: Self.baselineURL)
            return
        }
        let base = try JSONDecoder().decode(Baseline.self, from: Data(contentsOf: Self.baselineURL))
        XCTAssertEqual(base.entries.count, 19)
        XCTAssertEqual(base.entries.map(\.id), RollStocks.all.map(\.id))
        let url = try fixture()
        let samePlace = base.environment == Self.environment && url.lastPathComponent == base.fixture
        let dev = Developer()
        let scale = try dev.decoder.scaleFactor(url: url, longEdge: 384)
        let an = try dev.analyze(url: url)
        for (r, b) in zip(RollStocks.all, base.entries) {
            let byId = try XCTUnwrap(FilmStock.named(r.id), r.id)
            var st = Self.settings(r.look)
            st.lookArguments = r.arguments
            XCTAssertNoThrow(try st.validate(), r.id)
            let merged = try XCTUnwrap(try st.resolvedStock(), r.id)
            XCTAssertEqual(merged.name, r.look, "merged stock is named after the look")
            XCTAssertEqual(Self.fields(byId, look: r.look), b.fields, "\(r.id) fields vs baseline")
            XCTAssertEqual(Self.fields(merged, look: r.look), b.fields, "\(r.id) look + arguments fields vs baseline")
            LookGuardTests.checkLUT(byId.lut(), look: r.look, expected: b.lut, "\(r.id) LUT vs baseline")
            LookGuardTests.checkLUT(merged.lut(), look: r.look, expected: b.lut, "\(r.id) look + arguments LUT vs baseline")
            let pxId = try render(Self.settings(r.id), dev: dev, url: url, scale: scale, analysis: an)
            let pxArgs = try render(st, dev: dev, url: url, scale: scale, analysis: an)
            XCTAssertTrue(pxId == pxArgs, "\(r.id): look + arguments must be pixel-identical to the rr id")
            if samePlace { XCTAssertEqual(Self.fnv(pxId), b.pixels, "\(r.id) pixels vs baseline") }
        }
    }

    /// Arguments survive a JSON round trip, in the documented shape.
    func testArgumentsRoundTripThroughJSON() throws {
        for r in RollStocks.all {
            let data = try JSONEncoder().encode(r.arguments)
            XCTAssertEqual(try JSONDecoder().decode(LookArguments.self, from: data), r.arguments, r.id)
        }
        let lab = try XCTUnwrap(RollStocks.named("rr-chuan-400")).arguments
        XCTAssertTrue(lab.compactJSON().contains("\"grain\":{\"iso\":{\"scale\":0.8}}"), lab.compactJSON())
        let json = #"{"intensity":0.85,"iso":200,"grain":{"iso":{"scale":1.0}},"develop":"auto"}"#
        let a = try JSONDecoder().decode(LookArguments.self, from: Data(json.utf8))
        XCTAssertEqual(a, LookArguments(intensity: 0.85, iso: 200, grain: .iso(scale: 1), develop: .auto))
        XCTAssertNil(try JSONDecoder().decode(LookArguments.self, from: Data(#"{"intensity":0.7}"#.utf8)).iso, "iso optional (D13)")
        var st = RenderSettings(mode: .explicit); st.stock = "goldenDay"; st.lookArguments = a
        XCTAssertEqual(try JSONDecoder().decode(RenderSettings.self, from: JSONEncoder().encode(st)), st)
    }

    /// iso nil = the look's own grain and no decode profile (D13).
    func testNoISOKeepsTheLookGrainAndDecode() throws {
        let s = try FilmStock.resolve(look: "goldenDay", arguments: LookArguments(intensity: 0.7))
        let look = try XCTUnwrap(FilmStock.named("goldenDay"))
        XCTAssertEqual(s.finish, look.finish)
        XCTAssertNil(s.develop)
        XCTAssertEqual(s.lookIntensity, 0.7)
    }

    /// Everything RSP cannot merge throws `invalidSettings`; nothing falls back.
    func testInvalidArgumentsThrow() {
        func throwsInvalid(_ stock: String?, _ a: LookArguments?, finish: FilmFinish? = nil, _ msg: String, line: UInt = #line) {
            var st = RenderSettings(mode: .explicit); st.stock = stock; st.lookArguments = a; st.finish = finish
            XCTAssertThrowsError(try st.validate(), msg, line: line) { e in
                guard case RawCoreError.invalidSettings = e else { return XCTFail("\(e)", line: line) }
            }
            XCTAssertThrowsError(try st.resolvedStock(), msg, line: line)
        }
        throwsInvalid("goldenDay", LookArguments(grain: .iso(scale: 1)), "grain .iso without iso")
        throwsInvalid("goldenDay", LookArguments(iso: 200, lightLeak: "nope"), "unknown leak")
        throwsInvalid("rr-vang-200", LookArguments(iso: 200), "arguments on a stock that is not a SupportedLook")
        throwsInvalid("cinemaNegative", LookArguments(iso: 200), "retired look is not supported")
        throwsInvalid("warm400", LookArguments(iso: 200), "classic stock is not a supported look")
        throwsInvalid("goldenDay", LookArguments(iso: 200), finish: FilmFinish(), "arguments + finish")
        throwsInvalid(nil, LookArguments(iso: 200), "arguments without stock")
        throwsInvalid("goldenDay", LookArguments(intensity: 1.5), "intensity range")
        throwsInvalid("goldenDay", LookArguments(iso: 1), "iso range")
        throwsInvalid("goldenDay", LookArguments(vignette: 2), "vignette range")
        throwsInvalid("goldenDay", LookArguments(halation: .init(amount: 0.2, threshold: 0, radius: 0.5)), "halation threshold")
        throwsInvalid("goldenDay", LookArguments(develop: .vivid), "develop without iso")
        throwsInvalid("no-such-stock", nil, "unknown stock")
    }

    /// SupportedLooks = the listed looks; engine version published.
    func testSupportedLooksAndEngineVersion() {
        XCTAssertEqual(RawCore.engineVersion, "0.3.0")
        XCTAssertEqual(SupportedLooks.all.map(\.id), FilmLooks2026.names)
        XCTAssertEqual(SupportedLooks.all.count, 21)
        XCTAssertEqual(SupportedLooks.named("monoSoft")?.isMonochrome, true)
        XCTAssertEqual(SupportedLooks.named("goldenDay")?.isMonochrome, false)
        for r in RollStocks.all {
            XCTAssertNotNil(SupportedLooks.named(r.look), r.id)
            XCTAssertEqual(r.arguments.iso, r.iso, r.id); XCTAssertEqual(r.arguments.intensity, r.intensity, r.id)
            XCTAssertEqual(r.arguments.tungsten ?? false, r.tungsten, r.id)
        }
    }

    /// The recipe records `look=<id> args=<json>`.
    func testRecipeRecordsLookAndArguments() throws {
        let url = try fixture()
        let dev = Developer()
        let scale = try dev.decoder.scaleFactor(url: url, longEdge: 256)
        var st = RenderSettings(mode: .explicit); st.stock = "cleanLab"
        st.lookArguments = RollStocks.named("rr-chuan-400")!.arguments
        let out = try dev.develop(url: url, settings: st, auto: false, scaleFactor: scale)
        XCTAssertTrue(out.recipe.decisions.contains { $0 == "look=cleanLab args=\(st.lookArguments!.compactJSON())" }, "\(out.recipe.decisions)")
    }
}
#endif
