import Foundation
import RawCore

#if canImport(CoreImage)
import CoreImage

let usage = """
raw-bench — CIRAWFilter spike CLI

  raw-bench info <raw>...                         decoder versions, per-file defaults, support flags
  raw-bench analyze <raw>...                      scene context (light stats, headroom, Vision) + auto decisions
  raw-bench render <raw> [--mode appleDefault|explicit|sceneLinear|auto] [--look NAME|path.cube]
                   [--intensity 0..1] [--format heic10|png16|jpeg] [--scale 0..1] [--out FILE]
  raw-bench compare <raw> [--mode ...] [--look ...] [--long-edge N]   metrics + ΔE00 vs appleDefault
  raw-bench bench <dir>... --out <dir> [--manifest corpus.json] [--long-edge N] [--full]

Looks: \(BuiltInLook.allCases.map(\.rawValue).joined(separator: ", ")) or a .cube path.
"""

struct Args {
    var positional: [String] = []
    var options: [String: String] = [:]
    var flags: Set<String> = []
    init(_ argv: [String]) {
        var i = 0
        while i < argv.count {
            let a = argv[i]
            if a.hasPrefix("--") {
                let key = String(a.dropFirst(2))
                if i + 1 < argv.count, !argv[i + 1].hasPrefix("--") { options[key] = argv[i + 1]; i += 1 } else { flags.insert(key) }
            } else { positional.append(a) }
            i += 1
        }
    }
}

let dev = Developer()
let decoder = dev.decoder
let renderer = dev.renderer
let rawExtensions: Set<String> = ["dng", "cr2", "cr3", "nef", "arw", "raf", "orf", "rw2"]

func log(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

struct Variant {
    var name: String
    var settings: RenderSettings
    var auto: Bool
}

func variant(from a: Args) -> Variant {
    let modeName = a.options["mode"] ?? "appleDefault"
    let auto = modeName == "auto"
    var s = RenderSettings(mode: auto ? .explicit : (RenderSettings.Mode(rawValue: modeName) ?? .appleDefault))
    s.decoderVersion = a.options["decoder"]
    s.look = a.options["look"]
    if let i = a.options["intensity"], let f = Float(i) { s.lookIntensity = f }
    return Variant(name: modeName, settings: s, auto: auto)
}

// MARK: corpus manifest

struct CorpusEntry: Codable {
    var id: String
    var file: String
    var location: String?
    var category: String
    var condition: String
    var split: String
    var provenance: String
    var camera: String?
    var author: String
    var source: String
    var license: String
}
struct CorpusManifest: Codable { var files: [CorpusEntry] }

// MARK: bench

struct VariantResult: Codable {
    var name: String
    var deltaE00Mean: Double
    var deltaE00MeanUnclipped: Double
    var deltaE00P95: Double
    var ringOnReferenceMask: Double?
    var metrics: ImageMetrics
    var seconds: Double
    var recipe: DecodeRecipe
    var context: SceneContext?
}

struct Gates: Codable {
    var gate1: Bool
    var gate2: Bool
    var gate2Reasons: [String]
}

struct FileResult: Codable {
    var file: String
    var corpus: CorpusEntry?
    var camera: String?
    var iso: Double?
    var analysisSize: [Int]
    var reference: ImageMetrics?
    var variants: [VariantResult]
    var gates: Gates?
    var error: String?
}

func gates(_ vs: [VariantResult]) -> Gates? {
    guard let ref = vs.first(where: { $0.name == "appleDefault" }), let exp = vs.first(where: { $0.name == "explicit" }),
          let auto = vs.first(where: { $0.name == "auto" }) else { return nil }
    var why: [String] = []
    if auto.deltaE00MeanUnclipped > 3 { why.append(String(format: "ΔE unclipped %.2f > 3", auto.deltaE00MeanUnclipped)) }
    if auto.metrics.blackP1 > ref.metrics.blackP1 + 0.002 { why.append(String(format: "black p1 raised %.4f -> %.4f", ref.metrics.blackP1, auto.metrics.blackP1)) }
    if let a = auto.ringOnReferenceMask, let r = ref.metrics.highlightRingMeanY, a > r + 0.01 {
        why.append(String(format: "halo ring (reference mask) brighter %.3f -> %.3f", r, a))
    }
    return Gates(gate1: exp.deltaE00Mean < 0.5, gate2: why.isEmpty, gate2Reasons: why)
}

func benchFile(_ url: URL, entry: CorpusEntry?, outDir: URL, longEdge: Int, full: Bool) throws -> FileResult {
    let stem = url.deletingPathExtension().lastPathComponent
    let scale = try decoder.scaleFactor(url: url, longEdge: longEdge)
    let analysis = try dev.analyze(url: url)
    let variants: [Variant] = [
        Variant(name: "explicit", settings: .explicit, auto: false),
        Variant(name: "sceneLinear", settings: .sceneLinear, auto: false),
        Variant(name: "auto", settings: .explicit, auto: true),
        Variant(name: "auto+warmNegative", settings: RenderSettings(mode: .explicit, look: "warmNegative", lookIntensity: 0.8), auto: true),
        Variant(name: "auto+coolSlide", settings: RenderSettings(mode: .explicit, look: "coolSlide", lookIntensity: 0.8), auto: true),
    ]
    var t0 = Date()
    let ref = try dev.develop(url: url, settings: .appleDefault, auto: false, scaleFactor: scale)
    let refSeconds = Date().timeIntervalSince(t0)
    var renders: [(Variant, Developer.Output, Double)] = []
    for v in variants {
        t0 = Date()
        let o = try dev.develop(url: url, settings: v.settings, auto: v.auto, scaleFactor: scale, analysis: analysis)
        renders.append((v, o, Date().timeIntervalSince(t0) + (v.auto ? analysis.seconds : 0)))
    }
    let all = [ref.image] + renders.map(\.1.image)
    let w = all.map { Int($0.extent.integral.width) }.min()!, h = all.map { Int($0.extent.integral.height) }.min()!
    let refLin = try renderer.linearImage(ref.image, size: (w, h))
    let refMetrics = ImageMetrics.measure(refLin)
    try renderer.export(ref.image, format: .jpeg).write(to: outDir.appendingPathComponent("\(stem)__appleDefault.jpg"))
    try ref.recipe.prettyJSON().write(to: outDir.appendingPathComponent("\(stem)__appleDefault.recipe.json"), atomically: true, encoding: .utf8)

    var results = [VariantResult(name: "appleDefault", deltaE00Mean: 0, deltaE00MeanUnclipped: 0, deltaE00P95: 0,
                                 ringOnReferenceMask: refMetrics.highlightRingMeanY, metrics: refMetrics, seconds: refSeconds, recipe: ref.recipe, context: nil)]
    for (v, o, secs) in renders {
        let cmp = try ComparisonMetrics.compare(candidate: renderer.linearImage(o.image, size: (w, h)), reference: refLin)
        let safe = v.name.replacingOccurrences(of: "+", with: "_")
        try renderer.export(o.image, format: .jpeg).write(to: outDir.appendingPathComponent("\(stem)__\(safe).jpg"))
        try o.recipe.prettyJSON().write(to: outDir.appendingPathComponent("\(stem)__\(safe).recipe.json"), atomically: true, encoding: .utf8)
        results.append(VariantResult(name: v.name, deltaE00Mean: cmp.deltaE00Mean, deltaE00MeanUnclipped: cmp.deltaE00MeanUnclipped,
                                     deltaE00P95: cmp.deltaE00P95, ringOnReferenceMask: cmp.candidateRingOnReferenceMask, metrics: cmp.candidate, seconds: secs, recipe: o.recipe, context: o.context))
    }
    if full {
        for v in [Variant(name: "appleDefault", settings: .appleDefault, auto: false), variants[3]] {
            let t = Date()
            let o = try dev.develop(url: url, settings: v.settings, auto: v.auto, scaleFactor: 1, analysis: analysis)
            let data = try renderer.export(o.image, format: .heic10)
            try data.write(to: outDir.appendingPathComponent("\(stem)__\(v.name.replacingOccurrences(of: "+", with: "_"))__full.heic"))
            log(String(format: "  full-res %@ HEIC10: %.2fs, %.1f MB", v.name, Date().timeIntervalSince(t), Double(data.count) / 1e6))
        }
    }
    return FileResult(file: url.lastPathComponent, corpus: entry, camera: ref.recipe.camera, iso: ref.recipe.iso, analysisSize: [w, h],
                      reference: refMetrics, variants: results, gates: gates(results), error: nil)
}

func f2(_ v: Double?) -> String { v.map { String(format: "%.2f", $0) } ?? "–" }

func markdown(_ files: [FileResult]) -> String {
    var md = "# raw-bench summary\n\n"
    md += "Reference = Apple's default CIRAWFilter decode of the same file (pixel-aligned). Metrics: docs/METRICS.md.\n"
    md += "OS: \(ProcessInfo.processInfo.operatingSystemVersionString)\n\n"
    md += "## Gates\n\n| id | file | category | split | camera | Gate 1 | Gate 2 (auto) | auto decisions |\n|---|---|---|---|---|---|---|---|\n"
    for f in files {
        let c = f.corpus
        let g1 = f.gates.map { $0.gate1 ? "PASS" : "FAIL" } ?? (f.error == nil ? "–" : "ERROR")
        let g2 = f.gates.map { $0.gate2 ? "PASS" : "FAIL: " + $0.gate2Reasons.joined(separator: "; ") } ?? (f.error ?? "–")
        let dec = f.variants.first(where: { $0.name == "auto" })?.recipe.decisions.joined(separator: "; ") ?? ""
        md += "| \(c?.id ?? "") | \(f.file) | \(c?.category ?? "") | \(c?.split ?? "") | \(f.camera ?? "?") | \(g1) | \(g2) | \(dec) |\n"
    }
    md += "\n"
    for f in files {
        md += "## \(f.corpus?.id ?? "") \(f.file) — \(f.camera ?? "?")" + (f.iso.map { ", ISO \(Int($0))" } ?? "") + "\n\n"
        if let c = f.corpus { md += "\(c.category) · \(c.condition) · split **\(c.split)** · \(c.provenance) · \(c.author), \(c.license)\n\n" }
        if let e = f.error { md += "**ERROR:** \(e)\n\n"; continue }
        if let r = f.variants.first?.recipe {
            md += "decoder `\(r.decoderVersion)` (supported: \(r.supportedDecoderVersions.joined(separator: ", "))), native \(r.nativeSize[0])x\(r.nativeSize[1]), analysis \(f.analysisSize[0])x\(f.analysisSize[1])\n\n"
        }
        md += "| variant | ΔE00 mean | ΔE00 unclipped | ΔE00 p95 | black p1 | mean Y | clipped % | local contrast | halo ring Y (own / ref mask) | chroma | s |\n"
        md += "|---|---|---|---|---|---|---|---|---|---|---|\n"
        for v in f.variants {
            let m = v.metrics
            md += String(format: "| %@ | %.2f | %.2f | %.2f | %.4f | %.3f | %.2f | %.3f | %@ | %.1f | %.2f |\n",
                         v.name, v.deltaE00Mean, v.deltaE00MeanUnclipped, v.deltaE00P95, m.blackP1, m.meanY, m.clippedFraction * 100,
                         m.localContrast, f2(m.highlightRingMeanY) + " / " + f2(v.ringOnReferenceMask), m.meanChroma, v.seconds)
        }
        if let c = f.variants.first(where: { $0.name == "auto" })?.context {
            md += String(format: "\ncontext: DR %.1f stops (p1 %.2f, p50 %.2f, p99.9 %@), sensor clipped %.2f%%, display clipped %@%%, EDR headroom %@x, faces %@",
                         c.dynamicRangeStops, c.logP1, c.logP50, f2(c.logP999), c.clippedFraction * 100,
                         f2(c.displayClippedFraction.map { $0 * 100 }), f2(c.edrHeadroom), c.faceCount.map(String.init) ?? "n/a")
            if let l = c.labels, !l.isEmpty {
                md += ", labels " + l.sorted { $0.value > $1.value }.prefix(5).map { String(format: "%@ %.2f", $0.key, $0.value) }.joined(separator: ", ")
            }
            md += "\n"
        }
        md += "\n"
    }
    return md
}

func run() throws -> Int32 {
    let a = Args(Array(CommandLine.arguments.dropFirst()))
    guard let cmd = a.positional.first else { print(usage); return 2 }
    let rest = Array(a.positional.dropFirst())
    switch cmd {
    case "info":
        guard !rest.isEmpty else { print(usage); return 2 }
        for p in rest { print(try decoder.decode(url: URL(fileURLWithPath: p), settings: .appleDefault, scaleFactor: 0.1).recipe.prettyJSON()) }
        if let f = CIFilter(name: "CIToneMapHeadroom") { log("CIToneMapHeadroom inputs: \(f.inputKeys)") } else { log("CIToneMapHeadroom: not available") }
    case "analyze":
        for p in rest {
            let an = try dev.analyze(url: URL(fileURLWithPath: p))
            let d = DecisionEngine.decide(context: an.context, defaults: an.defaults, support: an.support)
            print(an.prettyJSON()); print(d.reasons.joined(separator: "\n"))
        }
    case "render":
        guard let p = rest.first else { print(usage); return 2 }
        let url = URL(fileURLWithPath: p)
        let v = variant(from: a)
        let format = Renderer.Format(rawValue: a.options["format"] ?? "heic10") ?? .heic10
        let t = Date()
        let o = try dev.develop(url: url, settings: v.settings, auto: v.auto, scaleFactor: a.options["scale"].flatMap(Float.init) ?? 1)
        let ext = format == .heic10 ? "heic" : (format == .png16 ? "png" : "jpg")
        let outPath = a.options["out"] ?? url.deletingPathExtension().lastPathComponent + "__\(v.name).\(ext)"
        try renderer.export(o.image, format: format).write(to: URL(fileURLWithPath: outPath))
        try o.recipe.prettyJSON().write(toFile: outPath + ".recipe.json", atomically: true, encoding: .utf8)
        log(String(format: "wrote %@ (%.2fs)", outPath, Date().timeIntervalSince(t)))
    case "compare":
        guard let p = rest.first else { print(usage); return 2 }
        let url = URL(fileURLWithPath: p)
        let scale = try decoder.scaleFactor(url: url, longEdge: a.options["long-edge"].flatMap(Int.init) ?? 1024)
        let ref = try dev.develop(url: url, settings: .appleDefault, auto: false, scaleFactor: scale)
        let v = variant(from: a)
        let cand = try dev.develop(url: url, settings: v.settings, auto: v.auto, scaleFactor: scale)
        let w = min(Int(ref.image.extent.integral.width), Int(cand.image.extent.integral.width))
        let h = min(Int(ref.image.extent.integral.height), Int(cand.image.extent.integral.height))
        print(try ComparisonMetrics.compare(candidate: renderer.linearImage(cand.image, size: (w, h)), reference: renderer.linearImage(ref.image, size: (w, h))).prettyJSON())
        log("decisions: " + cand.recipe.decisions.joined(separator: "; "))
    case "bench":
        guard !rest.isEmpty, let out = a.options["out"] else { print(usage); return 2 }
        let outDir = URL(fileURLWithPath: out)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        var manifest: [String: CorpusEntry] = [:]
        if let m = a.options["manifest"] {
            for e in try JSONDecoder().decode(CorpusManifest.self, from: Data(contentsOf: URL(fileURLWithPath: m))).files { manifest[e.file] = e }
        }
        var urls: [URL] = []
        for dir in rest {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
            urls += names.filter { rawExtensions.contains(($0 as NSString).pathExtension.lowercased()) }.sorted()
                .map { URL(fileURLWithPath: dir).appendingPathComponent($0) }
        }
        let longEdge = a.options["long-edge"].flatMap(Int.init) ?? 1024
        var results: [FileResult] = []
        for url in urls {
            log("bench \(url.lastPathComponent)")
            let entry = manifest[url.lastPathComponent]
            do { results.append(try benchFile(url, entry: entry, outDir: outDir, longEdge: longEdge, full: a.flags.contains("full"))) } catch {
                log("  ERROR \(error)")
                results.append(FileResult(file: url.lastPathComponent, corpus: entry, camera: nil, iso: nil, analysisSize: [0, 0],
                                          reference: nil, variants: [], gates: nil, error: "\(error)"))
            }
        }
        try results.prettyJSON().write(to: outDir.appendingPathComponent("summary.json"), atomically: true, encoding: .utf8)
        let md = markdown(results)
        try md.write(to: outDir.appendingPathComponent("summary.md"), atomically: true, encoding: .utf8)
        print(md)
        // Unsupported RAW formats are reported, not fatal: the corpus is also a compatibility probe.
    default:
        print(usage); return 2
    }
    return 0
}

do { exit(try run()) } catch { log("error: \(error)"); exit(1) }
#else
FileHandle.standardError.write(Data("raw-bench needs Core Image (macOS).\n".utf8))
exit(1)
#endif
