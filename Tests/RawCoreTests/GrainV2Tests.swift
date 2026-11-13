import Foundation
import XCTest
@testable import RawCore

/// `LookArguments.Grain.isoV2` (RSP 0.3.0, prototype §5.G = LINEUP_V2 L12 tiers). The old `.iso` table is unchanged.
final class GrainV2Tests: XCTestCase {
    func testTiersAndBoundaries() {
        let cases: [(Int, Float, Float)] = [(25, 0.22, 0.065), (100, 0.22, 0.065), (129, 0.22, 0.065),
                                            (130, 0.26, 0.075), (160, 0.26, 0.075), (179, 0.26, 0.075),
                                            (180, 0.33, 0.090), (200, 0.33, 0.090), (299, 0.33, 0.090),
                                            (300, 0.46, 0.120), (400, 0.46, 0.120), (599, 0.46, 0.120),
                                            (600, 0.62, 0.150), (800, 0.62, 0.150), (6400, 0.62, 0.150)]
        for (iso, a, s) in cases {
            let g = RollStock.grainV2(iso: iso)
            XCTAssertEqual(g.amount, a, "\(iso)"); XCTAssertEqual(g.size, s, "\(iso)")
        }
    }

    func testResolveUsesTheTableAndScale() throws {
        let s = try FilmStock.resolve(look: "goldenDay", arguments: LookArguments(iso: 400, grain: .isoV2(scale: 1)))
        XCTAssertEqual(s.finish.grainAmount, 0.46); XCTAssertEqual(s.finish.grainSize, 0.12)
        let t = try FilmStock.resolve(look: "tungstenGlow", arguments: LookArguments(iso: 800, tungsten: true, grain: .isoV2(scale: 0.5)))
        XCTAssertEqual(t.finish.grainAmount, 0.31); XCTAssertEqual(t.finish.grainSize, 0.15)
        XCTAssertThrowsError(try FilmStock.resolve(look: "goldenDay", arguments: LookArguments(grain: .isoV2(scale: 1))), "needs iso")
        XCTAssertThrowsError(try FilmStock.resolve(look: "goldenDay", arguments: LookArguments(iso: 200, grain: .isoV2(scale: 2.5))), "scale range")
    }

    func testCodableShape() throws {
        let a = LookArguments(iso: 200, grain: .isoV2(scale: 1))
        XCTAssertTrue(a.compactJSON().contains(#""grain":{"isoV2":{"scale":1}}"#), a.compactJSON())
        let d = try JSONDecoder().decode(LookArguments.self, from: Data(#"{"iso":160,"grain":{"isoV2":{"scale":1}}}"#.utf8))
        XCTAssertEqual(d.grain, .isoV2(scale: 1))
        XCTAssertEqual(try JSONDecoder().decode(LookArguments.self, from: JSONEncoder().encode(a)), a)
    }

    func testOldISOTableUnchanged() throws {
        let old: [(Int, Bool, Float, Float)] = [(100, false, 0.18, 0.050), (160, false, 0.22, 0.055), (200, false, 0.27, 0.060),
                                                (400, false, 0.35, 0.070), (800, false, 0.50, 0.080), (800, true, 0.55, 0.085)]
        for (iso, t, a, s) in old {
            let g = RollStock.grain(iso: iso, tungsten: t)
            XCTAssertEqual(g.amount, a); XCTAssertEqual(g.size, s)
        }
        let r = try FilmStock.resolve(look: "goldenDay", arguments: LookArguments(iso: 200, grain: .iso(scale: 1)))
        XCTAssertEqual(r.finish.grainAmount, 0.27); XCTAssertEqual(r.finish.grainSize, 0.06)
    }
}
