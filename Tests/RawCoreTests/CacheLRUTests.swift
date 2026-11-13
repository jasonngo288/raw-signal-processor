import Foundation
import XCTest
@testable import RawCore

/// RSP 0.3.0 sign-off C9: the LUT caches are bounded LRUs (LookSpecCache and SkyHoldLUTCache 4, LogLookPlugin.Cache 4,
/// the headroom restore cache 2), same lock and keys as before.
final class CacheLRUTests: XCTestCase {
    func lut(_ v: Float) -> CubeLUT { CubeLUT.generate(size: 2) { _ in SIMD3(repeating: v) } }

    func testFifthInsertEvictsTheLeastRecentlyUsed() {
        var c = LUTLRU(capacity: 4)
        for k in ["a", "b", "c", "d", "e"] { c.put(k, lut(0.5)) }
        XCTAssertEqual(c.order, ["b", "c", "d", "e"])
        XCTAssertNil(c.get("a"))
    }

    func testHitRefreshesRecency() {
        var c = LUTLRU(capacity: 4)
        for k in ["a", "b", "c", "d"] { c.put(k, lut(0.5)) }
        XCTAssertNotNil(c.get("a"))
        c.put("e", lut(0.5))
        XCTAssertEqual(c.order, ["c", "d", "a", "e"], "a was used last before e: b is evicted")
        var built = 0
        _ = c.value("c") { built += 1; return lut(0.1) }
        XCTAssertEqual(built, 0, "a hit does not rebuild")
        XCTAssertEqual(c.order.last, "c")
    }

    func testCapacities() {
        XCTAssertEqual(LookSpecCache.capacity, 4)
        XCTAssertEqual(SkyHoldLUTCache.capacity, 4)
        #if canImport(CoreImage)
        XCTAssertEqual(LogLookPlugin.Cache.capacity, 4)
        #endif
    }

    /// An evicted generated look rebuilds to byte-identical values.
    func testEvictedLookRebuildsIdentically() throws {
        let cache = LookSpecCache(capacity: 4)
        let names = Array(FilmLooks2026.looks.prefix(5))
        let first = cache.lut(names[0].name, names[0].spec, size: 17)
        for l in names.dropFirst() { _ = cache.lut(l.name, l.spec, size: 17) }
        XCTAssertEqual(cache.keys.count, 4)
        XCTAssertFalse(cache.keys.contains("\(names[0].name)|17"), "the first look was evicted")
        let again = cache.lut(names[0].name, names[0].spec, size: 17)
        XCTAssertEqual(LookGuardTests.fnv(again.rgba), LookGuardTests.fnv(first.rgba))
        XCTAssertEqual(again, first)

        let sky = SkyHoldLUTCache(capacity: 4)
        var spec = try XCTUnwrap(FilmLooks2026.looks.first { $0.spec.skyHold > 0 }).spec
        spec.skyHold = 0
        let a = sky.lut("x#nohold|17") { spec.lut(size: 17) }
        for k in ["p", "q", "r", "s"] { _ = sky.lut(k) { lut(0.5) } }
        XCTAssertFalse(sky.keys.contains("x#nohold|17"))
        let b = sky.lut("x#nohold|17") { spec.lut(size: 17) }
        XCTAssertEqual(a, b)
    }
}
