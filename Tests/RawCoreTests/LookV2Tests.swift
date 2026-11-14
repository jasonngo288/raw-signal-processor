#if canImport(CoreImage)
import CoreImage
import XCTest
@testable import RawCore

/// The 3 v2 looks of RSP 0.3.0 (sign-off C4, C8; prototype §5.A, §5.F): ids listed and supported, LUT fingerprints, and
/// pixel hashes of the catalog stocks Marigold, Breeze and Blush built as look + arguments (the MoodRoll catalog
/// arguments with the L16 values). Written with `RSP_WRITE_LOOK_V2=1 swift test --filter LookV2Tests`; pixel hashes are
/// compared only on the OS / machine and fixture DNG that wrote them (same rule as `LookArgumentsTests`).
final class LookV2Tests: XCTestCase {
    static let fixtureURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures/looks-v2-0.3.0.json")

    static let v2 = ["goldenDay2", "coolFade2", "softPortrait2"]

    /// Catalog stocks on the v2 looks: look + `LookArguments` as the app sends them (render keys are app-side, §2).
    static let stocks: [(name: String, look: String, args: LookArguments)] = [
        ("Marigold", "goldenDay2", LookArguments(stockId: "rr-vang-200", intensity: 0.9, iso: 200, grain: .explicit(amount: 0.32, size: 0.085),
                                                 halation: .init(amount: 0.3, threshold: 0.75, radius: 1.0), vignette: 0.14, develop: .auto)),
        ("Breeze", "coolFade2", LookArguments(stockId: "rr-gio-400", intensity: 1.0, iso: 400, grain: .explicit(amount: 0.44, size: 0.115),
                                              halation: .init(amount: 0.12, threshold: 0.82, radius: 0.8), vignette: 0.12, develop: .auto)),
        ("Blush", "softPortrait2", LookArguments(stockId: "rr-da-mem-160", intensity: 1.0, iso: 160, grain: .explicit(amount: 0.26, size: 0.075),
                                                 halation: .init(amount: 0.1, threshold: 0.8, radius: 0.9), vignette: 0.1, develop: .portrait)),
    ]

    struct Fixture: Codable {
        struct Look: Codable, Equatable { var look: String; var lut: String }
        struct Stock: Codable, Equatable { var name: String; var look: String; var arguments: String; var pixels: String }
        var engine: String
        var fixture: String
        var environment: String
        var looks: [Look]
        var stocks: [Stock]
    }

    func testV2LooksAreListedAndSupported() {
        XCTAssertEqual(Array(FilmLooks2026.names.suffix(3)), Self.v2)
        for n in Self.v2 {
            XCTAssertNotNil(SupportedLooks.named(n), n)
            XCTAssertEqual(SupportedLooks.named(n)?.isMonochrome, false)
        }
        XCTAssertNil(FilmStock.named("tungstenGlow2"), "deferred (L19, C4)")
        XCTAssertEqual(FilmStock.named("goldenDay2")?.finish, FilmStock.named("goldenDay")?.finish)
        XCTAssertEqual(FilmStock.named("coolFade2")?.finish, FilmStock.named("trialCoolFade")?.finish)
        XCTAssertEqual(FilmStock.named("softPortrait2")?.finish, FilmStock.named("softPortrait")?.finish)
        let vib = Dictionary(uniqueKeysWithValues: FilmLooks2026.looks.map { ($0.name, $0.spec.vibrance) })
        XCTAssertEqual(vib["goldenDay2"], 0.10); XCTAssertEqual(vib["coolFade2"], 0); XCTAssertEqual(vib["softPortrait2"], 0.10)
        XCTAssertTrue(FilmLooks2026.looks.filter { !Self.v2.contains($0.name) }.allSatisfy { $0.spec.vibrance == 0 }, "vibrance only inside the v2 looks (L21)")
    }

    func testFingerprintsAndPixels() throws {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: LookArgumentsTests.root.appendingPathComponent("originals").path)) ?? [])
        let dng = names.contains("USER_mooncake.dng") ? "USER_mooncake.dng" : names.filter { $0.lowercased().hasSuffix(".dng") }.sorted().first
        let looks = try Self.v2.map { Fixture.Look(look: $0, lut: try LookGuardTests.fingerprint($0)) }
        func pixels() throws -> [Fixture.Stock] {
            guard let dng else { throw XCTSkip("no DNGs in originals/") }
            let url = LookArgumentsTests.root.appendingPathComponent("originals/\(dng)")
            let dev = Developer()
            let scale = try dev.decoder.scaleFactor(url: url, longEdge: 384)
            let an = try dev.analyze(url: url)
            return try Self.stocks.map { s in
                var st = LookArgumentsTests.settings(s.look)
                st.lookArguments = s.args
                let out = try dev.develop(url: url, settings: st, auto: true, scaleFactor: scale, analysis: an)
                return .init(name: s.name, look: s.look, arguments: s.args.compactJSON(), pixels: LookArgumentsTests.fnv(try dev.renderer.linearImage(out.image).pixels))
            }
        }
        if ProcessInfo.processInfo.environment["RSP_WRITE_LOOK_V2"] == "1" {
            let f = Fixture(engine: "0.3.0", fixture: dng ?? "", environment: LookArgumentsTests.environment, looks: looks, stocks: try pixels())
            try Data(f.prettyJSON().utf8).write(to: Self.fixtureURL)
            return
        }
        let f = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: Self.fixtureURL))
        XCTAssertEqual(looks.map(\.look), f.looks.map(\.look))
        for (l, e) in zip(Self.v2, f.looks) {
            LookGuardTests.checkLUT(try XCTUnwrap(FilmStock.named(l)).lut(), look: l, expected: e.lut, "\(l) v2 LUT")
        }
        XCTAssertEqual(f.stocks.map(\.arguments), Self.stocks.map { $0.args.compactJSON() })
        guard f.environment == LookArgumentsTests.environment, dng == f.fixture else { return }
        XCTAssertEqual(try pixels(), f.stocks, "v2 stock pixels changed")
    }
}
#endif
