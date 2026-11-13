import Foundation
import XCTest
@testable import RawCore

/// D6 guard (RSP 0.3.0 sign-off C8): the LUT fingerprints of the 18 looks that shipped in 0.2.0, written on the unchanged
/// 0.2.0 code (`RSP_WRITE_LOOK_GUARD=1 swift test --filter LookGuardTests`). Every later change must keep them equal:
/// a shipped look id is frozen, new looks get new ids. LUT values only (title ignored), so the check runs on any machine.
final class LookGuardTests: XCTestCase {
    static let guardURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures/looks-0.2.0-guard.json")

    struct Guard: Codable {
        struct Entry: Codable, Equatable {
            var look: String
            var lut: String
        }
        var engine: String
        var entries: [Entry]
    }

    /// FNV-1a 64 over the float bit patterns (same hash as `LookArgumentsTests.fnv`).
    static func fnv(_ values: [Float]) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for v in values {
            var b = v.bitPattern
            for _ in 0..<4 { h = (h ^ UInt64(b & 0xff)) &* 0x100000001b3; b >>= 8 }
        }
        return String(format: "%016llx", h)
    }

    /// Size and values of the look's shipped cube (`FilmStock.lut()`, 65³ colour / 33³ mono).
    static func fingerprint(_ look: String) throws -> String {
        let l = try XCTUnwrap(FilmStock.named(look), look).lut()
        return "\(l.size):" + fnv(l.rgba)
    }

    func testThe18ShippedLooksAreUnchanged() throws {
        if ProcessInfo.processInfo.environment["RSP_WRITE_LOOK_GUARD"] == "1" {
            let g = Guard(engine: RawCore.engineVersion, entries: try FilmLooks2026.names.map { .init(look: $0, lut: try Self.fingerprint($0)) })
            try Data(g.prettyJSON().utf8).write(to: Self.guardURL)
            return
        }
        let g = try JSONDecoder().decode(Guard.self, from: Data(contentsOf: Self.guardURL))
        XCTAssertEqual(g.engine, "0.2.0")
        XCTAssertEqual(g.entries.count, 18)
        XCTAssertEqual(Array(FilmLooks2026.names.prefix(18)), g.entries.map(\.look), "the 18 shipped looks keep their ids and order")
        for e in g.entries {
            XCTAssertEqual(try Self.fingerprint(e.look), e.lut, "\(e.look): LUT changed (D6: a shipped look is frozen)")
        }
    }
}
