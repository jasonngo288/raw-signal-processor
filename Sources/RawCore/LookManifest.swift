import Foundation

/// The declaration every LUT file must ship with (`<name>.manifest.json` next to the `.cube`), following the LUT
/// library contract (ImageSignalProcessor-ISP `docs/research/LUT_LIBRARY_RESEARCH.md`): a `.cube` is only a grid of
/// numbers, so its encodings, intended stage, provenance and licence are declared here and checked before use.
/// Unknown values are written as "unknown" (an assumption goes in `assumed…`), never guessed silently.
public struct LookManifest: Codable, Equatable, Sendable {
    public struct Encoding: Codable, Equatable, Sendable {
        public var primaries: String
        public var white: String
        public var transfer: String
        public var logCurve: String?
        public var assumedLogCurve: String?
        public var domain: [Float]?
        public var referred: String?
    }
    public struct Source: Codable, Equatable, Sendable {
        public var author: String
        public var url: String
        public var version: String
        public var obtained: String?
    }
    public struct License: Codable, Equatable, Sendable {
        public var id: String
        public var redistributionInApp: String
    }
    public struct Change: Codable, Equatable, Sendable {
        public var date: String
        public var change: String
    }

    public var schema: Int
    public var name: String
    public var file: String
    public var sha256: String
    public var input: Encoding
    public var output: Encoding
    public var toneBaked: Bool?
    public var exposureAnchor: String?
    public var route: String
    public var source: Source
    public var license: License
    public var history: [Change]
    public var notes: String?

    public static let currentSchema = 1
}

/// Colour space a display-referred LUT was authored in (CIColorCubeWithColorSpace encodes the image into it).
public enum LookColorSpace: String, Codable, Equatable, Sendable {
    case displayP3
    case sRGB
}

/// Where a declared LUT can run in this pipeline. Anything else is rejected.
public enum LookRoute: Equatable, Sendable {
    /// Display-referred look on the base render, in the LUT's own encoded colour space.
    case display(LookColorSpace)
    /// Scene-referred log input → display output: the `logLook` plugin (scene-linear decode → primaries → log curve).
    case log(LogCurve, primaries: LogLookPrimaries)
}

/// Primaries of a log LUT's input (the composite converts the scene-linear Display P3 decode into them).
public enum LogLookPrimaries: String, Codable, Equatable, Sendable {
    case rec2020
    case rec709
}

public struct LookCheck: Equatable, Sendable {
    public var name: String
    public var manifestFile: String
    /// Reasons the LUT must not load. Empty = usable.
    public var problems: [String]
    /// Reasons it must not ship in a release build (licence, trademark) even though it loads for testing.
    public var releaseBlockers: [String]
    public var route: LookRoute?
    public var isUsable: Bool { problems.isEmpty && route != nil }
}

public enum LookContract {
    public static let licenceAllowList: Set<String> = ["MIT", "CC0", "CC0-1.0", "BSD-2-Clause", "BSD-3-Clause", "Apache-2.0", "own-work"]
    public static let trademarks = ["kodak", "kodachrome", "portra", "ektar", "ektacolor", "ektapan", "gold", "vision3", "fuji",
                                    "fujifilm", "superia", "velvia", "provia", "ilford", "polaroid", "cinestill", "trix", "tri",
                                    "agfa", "vsco", "dazz"]

    static func norm(_ s: String) -> String { s.lowercased().replacingOccurrences(of: "-", with: "").replacingOccurrences(of: "_", with: "").replacingOccurrences(of: " ", with: "") }
    static func isUnknown(_ s: String?) -> Bool { s.map { $0.isEmpty || $0.lowercased() == "unknown" } ?? true }

    /// Route the manifest declares, or why it cannot run here.
    public static func route(_ m: LookManifest) -> (LookRoute?, [String]) {
        let inT = norm(m.input.transfer), outT = norm(m.output.transfer)
        let inP = norm(m.input.primaries), outP = norm(m.output.primaries)
        let outDisplay = (m.output.referred.map(norm) ?? "display") == "display" && (outT == "srgb" || outT == "gamma22" || outT == "displayp3")
        func space(_ p: String) -> LookColorSpace? {
            switch p { case "displayp3", "p3", "p3d65": return .displayP3; case "srgb", "rec709", "bt709": return .sRGB; default: return nil }
        }
        switch norm(m.route) {
        case "display":
            guard inT == "srgb" || inT == "displayp3" else { return (nil, ["route display needs an encoded display input (sRGB transfer), got input transfer \(m.input.transfer)"]) }
            guard outDisplay else { return (nil, ["route display needs a display-referred output, got \(m.output.transfer) / \(m.output.referred ?? "display")"]) }
            guard let s = space(inP), space(outP) == s else {
                return (nil, ["route display needs the same supported primaries in and out (Display P3 or sRGB/Rec.709), got \(m.input.primaries) → \(m.output.primaries)"])
            }
            return (.display(s), [])
        case "scenetodisplay":
            guard inT == "log" else {
                return (nil, ["route sceneToDisplay is implemented for log-encoded input only, got input transfer \(m.input.transfer)"])
            }
            let named = isUnknown(m.input.logCurve) ? m.input.assumedLogCurve : m.input.logCurve
            guard let n = named, let curve = LogCurve.allCases.first(where: { norm($0.rawValue) == norm(n) }) else {
                return (nil, ["log curve \(m.input.logCurve ?? "nil") (assumed \(m.input.assumedLogCurve ?? "nil")) is not one of \(LogCurve.allCases.map(\.rawValue).joined(separator: ", "))"])
            }
            let prim: LogLookPrimaries
            switch inP {
            case "rec2020", "bt2020": prim = .rec2020
            case "rec709", "bt709", "srgb": prim = .rec709
            default: return (nil, ["log input primaries \(m.input.primaries) not supported (Rec.2020 or Rec.709)"])
            }
            guard outDisplay, space(outP) == .sRGB else {
                return (nil, ["route sceneToDisplay needs a Rec.709/sRGB display output, got \(m.output.primaries) \(m.output.transfer)"])
            }
            return (.log(curve, primaries: prim), [])
        default:
            return (nil, ["route \(m.route) is not supported here (display, sceneToDisplay)"])
        }
    }

    /// Full check of one manifest against its file bytes.
    public static func check(_ m: LookManifest, manifestFile: String, cubeData: Data?) -> (LookCheck, CubeLUT?) {
        var problems: [String] = [], release: [String] = []
        if m.schema != LookManifest.currentSchema { problems.append("schema \(m.schema) != \(LookManifest.currentSchema)") }
        for (field, v) in [("name", m.name), ("file", m.file), ("sha256", m.sha256), ("input.primaries", m.input.primaries),
                           ("input.white", m.input.white), ("input.transfer", m.input.transfer), ("output.primaries", m.output.primaries),
                           ("output.white", m.output.white), ("output.transfer", m.output.transfer), ("route", m.route),
                           ("source.author", m.source.author), ("source.url", m.source.url), ("source.version", m.source.version),
                           ("license.id", m.license.id), ("license.redistributionInApp", m.license.redistributionInApp)] where v.isEmpty {
            problems.append("\(field) is empty (write \"unknown\" if it is not known)")
        }
        if m.history.isEmpty { problems.append("history is empty") }
        if let d = m.input.domain, d.count != 2 || d[0] >= d[1] { problems.append("input.domain must be [min, max] with min < max") }
        var lut: CubeLUT?
        if let data = cubeData {
            let actual = SHA256.hex(data)
            if actual != m.sha256.lowercased() { problems.append("sha256 mismatch: manifest \(m.sha256.prefix(12))…, file \(actual.prefix(12))…") }
            do { lut = try CubeLUT.parse(String(decoding: data, as: UTF8.self)) } catch { problems.append("cube does not parse: \(error)") }
        } else {
            problems.append("file \(m.file) not found next to the manifest")
        }
        let (r, why) = route(m)
        problems += why
        // Release checks (loading for tests and review is still allowed).
        let lic = m.license.id.trimmingCharacters(in: .whitespaces)
        if !licenceAllowList.contains(lic) { release.append("licence \(lic) is not on the allow-list (\(licenceAllowList.sorted().joined(separator: ", ")))") }
        if !norm(m.license.redistributionInApp).hasPrefix("permitted") { release.append("redistribution in an app is \(m.license.redistributionInApp)") }
        let words = m.name.lowercased().split { !$0.isLetter }.map(String.init)
        if let t = words.first(where: { trademarks.contains($0) }) { release.append("name \(m.name) contains the trademark word \"\(t)\"") }
        if isUnknown(m.source.version) || isUnknown(m.source.url) { release.append("source url/version unknown") }
        return (LookCheck(name: m.name, manifestFile: manifestFile, problems: problems, releaseBlockers: release, route: problems.isEmpty ? r : nil),
                problems.isEmpty ? lut : nil)
    }
}

/// Bundled or user-supplied LUT library: every `*.manifest.json` in a folder, checked; only usable ones become stocks.
public final class LookLibrary: @unchecked Sendable {
    public struct Entry: Sendable {
        public var manifest: LookManifest
        public var lut: CubeLUT
        public var route: LookRoute
        public var check: LookCheck
    }
    public private(set) var entries: [Entry] = []
    public private(set) var checks: [LookCheck] = []

    public init(directory: URL?) {
        guard let dir = directory,
              let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return }
        for n in names.sorted() where n.hasSuffix(".manifest.json") {
            let url = dir.appendingPathComponent(n)
            guard let data = try? Data(contentsOf: url) else { continue }
            guard let m = try? JSONDecoder().decode(LookManifest.self, from: data) else {
                checks.append(LookCheck(name: n, manifestFile: n, problems: ["manifest is not valid JSON for schema \(LookManifest.currentSchema)"], releaseBlockers: [], route: nil))
                continue
            }
            let cube = try? Data(contentsOf: dir.appendingPathComponent(m.file))
            let (c, lut) = LookContract.check(m, manifestFile: n, cubeData: cube)
            checks.append(c)
            if let lut, let r = c.route { entries.append(Entry(manifest: m, lut: lut, route: r, check: c)) }
        }
    }

    /// RawCore's own `Looks/` resources.
    public static let bundled = LookLibrary(directory: bundledDirectory)

    static var bundledDirectory: URL? {
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle(for: LookLibrary.self)   // RawCore.framework in the demo app
        #endif
        if let u = bundle.url(forResource: "Looks", withExtension: nil) { return u }
        return bundle.resourceURL   // XcodeGen copies the files flat
    }

    /// Stocks for the usable entries: the file is the look (no grain/halation), route from the manifest.
    public var stocks: [FilmStock] {
        entries.map { e in
            var s = FilmStock(name: e.manifest.name, source: .library(e.manifest.name), lookIntensity: 1, finish: FilmFinish(),
                              summary: "\(e.manifest.source.author) · \(e.manifest.license.id) · \(e.manifest.notes ?? e.manifest.file)")
            switch e.route {
            case .display(let space): s.lookInput = .display; s.lookColorSpace = space
            case .log(let curve, let prim): s.lookInput = .log(curve); s.logPrimaries = prim
            }
            return s
        }
    }

    public func lut(named n: String) -> CubeLUT? { entries.first { $0.manifest.name == n }?.lut }
    public func manifest(named n: String) -> LookManifest? { entries.first { $0.manifest.name == n }?.manifest }
}

/// SHA-256 in pure Swift (no CryptoKit, so the contract checks run in the pure-Swift core everywhere).
public enum SHA256 {
    static let k: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01,
        0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
        0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da, 0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147,
        0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070, 0x19a4c116, 0x1e376c08,
        0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
        0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2]

    public static func hex(_ data: Data) -> String {
        var h: [UInt32] = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]
        var msg = [UInt8](data)
        let bitLen = UInt64(msg.count) * 8
        msg.append(0x80)
        while msg.count % 64 != 56 { msg.append(0) }
        for i in (0..<8).reversed() { msg.append(UInt8((bitLen >> (UInt64(i) * 8)) & 0xff)) }
        var w = [UInt32](repeating: 0, count: 64)
        func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 { (x >> n) | (x << (32 - n)) }
        for chunk in stride(from: 0, to: msg.count, by: 64) {
            for i in 0..<16 {
                let j = chunk + i * 4
                w[i] = UInt32(msg[j]) << 24 | UInt32(msg[j + 1]) << 16 | UInt32(msg[j + 2]) << 8 | UInt32(msg[j + 3])
            }
            for i in 16..<64 {
                let s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3)
                let s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10)
                w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
            }
            var a = h[0], b = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], hh = h[7]
            for i in 0..<64 {
                let s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
                let ch = (e & f) ^ (~e & g)
                let t1 = hh &+ s1 &+ ch &+ k[i] &+ w[i]
                let s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
                let maj = (a & b) ^ (a & c) ^ (b & c)
                let t2 = s0 &+ maj
                hh = g; g = f; f = e; e = d &+ t1; d = c; c = b; b = a; a = t1 &+ t2
            }
            h[0] = h[0] &+ a; h[1] = h[1] &+ b; h[2] = h[2] &+ c; h[3] = h[3] &+ d
            h[4] = h[4] &+ e; h[5] = h[5] &+ f; h[6] = h[6] &+ g; h[7] = h[7] &+ hh
        }
        return h.map { String(format: "%08x", $0) }.joined()
    }
}
