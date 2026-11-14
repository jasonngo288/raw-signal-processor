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

    // MARK: exact hash here, numeric tolerance on another toolchain / OS (CI)

    /// LUT values are pure Swift float maths (OKLab: pow, atan2, cos, sin), so their bits depend on the compiler and
    /// libm: the macos-15 CI runner (macOS 15.8.2, Xcode 16.4, Swift 6.1.2) gives other hashes than the machine that wrote
    /// the fixtures (macOS 15.2, Xcode 16.2, Swift 6.0.3) for every colour look, while the two mono looks (no OKLab) match.
    /// Rule: the exact hash is always tried first. Only when the environment differs from the one in
    /// `lut-samples-0.3.0.json`, or `CI=true` (set by GitHub Actions), a mismatch falls back to a numeric check: 9³
    /// lattice samples (every (size−1)/8 node of each axis, stored as UInt16) must be within `tolerance` per channel.
    /// On the fixture machine the exact check stays the only check.
    static let samplesURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures/lut-samples-0.3.0.json")
    static let tolerance: Float = 1.0 / 255

    struct Samples: Codable {
        var engine: String
        var environment: String
        var note: String
        /// look id -> base64 of 9³ × RGB UInt16 little-endian (value × 65535, rounded)
        var looks: [String: String]
    }

    /// OS build + CPU, same string as `LookArgumentsTests.environment`.
    static var environment: String {
        var sys = utsname(); uname(&sys)
        let machine = withUnsafeBytes(of: &sys.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        return "\(ProcessInfo.processInfo.operatingSystemVersionString) \(machine)"
    }

    static let samples: Samples? = try? JSONDecoder().decode(Samples.self, from: Data(contentsOf: samplesURL))

    /// True where a hash mismatch may fall back to the numeric check.
    static var toleranceAllowed: Bool {
        ProcessInfo.processInfo.environment["CI"] == "true" || (samples.map { $0.environment != environment } ?? false)
    }

    static func sample(_ l: CubeLUT) -> [UInt16] {
        let n = l.size, step = (n - 1) / 8
        var out: [UInt16] = []
        for b in stride(from: 0, to: n, by: step) { for g in stride(from: 0, to: n, by: step) { for r in stride(from: 0, to: n, by: step) {
            let o = ((b * n + g) * n + r) * 4
            for c in 0..<3 { out.append(UInt16((min(max(l.rgba[o + c], 0), 1) * 65535).rounded())) }
        } } }
        return out
    }

    static func encode(_ v: [UInt16]) -> String {
        var d = Data(); for x in v { d.append(UInt8(x & 0xff)); d.append(UInt8(x >> 8)) }
        return d.base64EncodedString()
    }

    static func decode(_ s: String) -> [UInt16] {
        let d = [UInt8](Data(base64Encoded: s) ?? Data())
        return stride(from: 0, to: d.count - 1, by: 2).map { UInt16(d[$0]) | UInt16(d[$0 + 1]) << 8 }
    }

    /// Per-value |difference| between a LUT's samples and stored samples (nil = different lattice).
    static func sampleDiffs(_ lut: CubeLUT, _ ref: [UInt16]) -> [Float]? {
        let now = sample(lut)
        guard ref.count == now.count else { return nil }
        return zip(now, ref).map { abs(Float(Int($0) - Int($1))) / 65535 }
    }

    /// The numeric fallback itself (run everywhere): the stored samples reproduce, and a shift of 2/255 is caught.
    func testSampleFallbackCatchesRealChanges() throws {
        let s = try XCTUnwrap(Self.samples, "lut-samples-0.3.0.json missing")
        XCTAssertEqual(Set(s.looks.keys), Set(FilmLooks2026.names))
        let lut = try XCTUnwrap(FilmStock.named("goldenDay")).lut()
        let ref = Self.decode(try XCTUnwrap(s.looks["goldenDay"]))
        XCTAssertEqual(ref.count, 9 * 9 * 9 * 3)
        XCTAssertLessThanOrEqual(try XCTUnwrap(Self.sampleDiffs(lut, ref)).max()!, 1.0 / 65535, "samples match the LUT here")
        var moved = lut
        for i in stride(from: 0, to: moved.rgba.count, by: 4) { moved.rgba[i] = min(moved.rgba[i] + 2.0 / 255, 1) }
        XCTAssertGreaterThan(try XCTUnwrap(Self.sampleDiffs(moved, ref)).max()!, Self.tolerance, "a 2/255 shift fails the bound")
        var noise = lut
        for i in stride(from: 0, to: noise.rgba.count, by: 4) { noise.rgba[i] = min(max(noise.rgba[i] + 1e-5, 0), 1) }
        XCTAssertLessThanOrEqual(try XCTUnwrap(Self.sampleDiffs(noise, ref)).max()!, Self.tolerance, "float noise passes")
    }

    /// Exact fingerprint check, or (other toolchain / OS only) the numeric check against the stored samples.
    static func checkLUT(_ lut: CubeLUT, look: String, expected: String, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        let got = "\(lut.size):" + fnv(lut.rgba)
        if got == expected { return }
        guard toleranceAllowed else {
            XCTFail("\(what): LUT \(got) != \(expected) (exact check: same environment as the fixtures)", file: file, line: line)
            return
        }
        guard let ref = samples?.looks[look].map(decode) else {
            XCTFail("\(what): hash differs and no stored samples for \(look)", file: file, line: line); return
        }
        guard let diffs = sampleDiffs(lut, ref) else { XCTFail("\(what): sample count differs", file: file, line: line); return }
        let worst = diffs.max() ?? 0
        print(String(format: "[lut-tolerance] %@: hash %@ != %@ on %@; 9^3 samples max |d| = %.6f (%.2f/255), %d of %d values differ, bound %.4f",
                     what, got, expected, environment, worst, worst * 255, diffs.filter { $0 > 0 }.count, diffs.count, tolerance))
        XCTAssertLessThanOrEqual(worst, tolerance, "\(what): LUT values moved beyond the cross-toolchain bound", file: file, line: line)
    }

    /// Writes the samples of all listed looks, only after every exact fingerprint matched on this machine.
    func testWriteSamplesWhenAsked() throws {
        guard ProcessInfo.processInfo.environment["RSP_WRITE_LUT_SAMPLES"] == "1" else { return }
        let g = try JSONDecoder().decode(Guard.self, from: Data(contentsOf: Self.guardURL))
        for e in g.entries { XCTAssertEqual(try Self.fingerprint(e.look), e.lut, e.look) }
        let v2 = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/looks-v2-0.3.0.json")
        struct V2: Codable { struct L: Codable { var look: String; var lut: String }; var looks: [L] }
        for e in try JSONDecoder().decode(V2.self, from: Data(contentsOf: v2)).looks { XCTAssertEqual(try Self.fingerprint(e.look), e.lut, e.look) }
        guard testRun?.failureCount == 0 else { return }
        var looks: [String: String] = [:]
        for n in FilmLooks2026.names { looks[n] = Self.encode(Self.sample(try XCTUnwrap(FilmStock.named(n)).lut())) }
        let s = Samples(engine: RawCore.engineVersion, environment: Self.environment,
                        note: "9^3 lattice samples of every listed look, written after all exact fingerprints matched (LookGuardTests.checkLUT)",
                        looks: looks)
        try Data(s.prettyJSON().utf8).write(to: Self.samplesURL)
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
            Self.checkLUT(try XCTUnwrap(FilmStock.named(e.look)).lut(), look: e.look, expected: e.lut, "\(e.look) (D6: a shipped look is frozen)")
        }
    }
}
