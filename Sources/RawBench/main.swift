import Foundation
import RawCore

#if canImport(CoreImage)
import CoreImage

let usage = """
raw-bench — CIRAWFilter spike CLI

  raw-bench info <raw>...                         decoder versions, per-file defaults, support flags
  raw-bench render <raw> [--mode appleDefault|explicit|sceneLinear|auto] [--look NAME|path.cube]
                   [--intensity 0..1] [--format heic10|png16|jpeg] [--scale 0..1] [--out FILE]
  raw-bench compare <raw> [--mode ...] [--look ...] [--long-edge N]   metrics + ΔE00 vs appleDefault
  raw-bench bench <dir> --out <dir> [--long-edge N] [--full]          all variants for every RAW in dir

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

let decoder = RawDecoder()
let renderer = Renderer()
let rawExtensions: Set<String> = ["dng", "cr2", "cr3", "nef", "arw", "raf", "orf", "rw2"]

func log(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

struct Variant {
    var name: String
    var settings: RenderSettings
    var auto: Bool
}

/// Render one variant. `auto` runs context analysis on a scene-linear thumbnail first.
func develop(_ url: URL, _ v: Variant, scale: Float) throws -> (CIImage, DecodeRecipe, SceneContext?) {
    var settings = v.settings
    var decisions: [String] = []
    var ctx: SceneContext?
    if v.auto {
        let thumbScale = try decoder.scaleFactor(url: url, longEdge: 512)
        let lin = try decoder.decode(url: url, settings: .sceneLinear, scaleFactor: thumbScale)
        var c = SceneContext.measure(sceneLinear: try renderer.linearImage(lin.image), iso: lin.recipe.iso)
        #if canImport(Vision)
        let preview = try decoder.decode(url: url, settings: .appleDefault, scaleFactor: thumbScale)
        if let cg = renderer.cgImage(preview.image) { VisionAnalyzer.enrich(&c, image: cg) }
        #endif
        let decision = DecisionEngine.decide(context: c, defaults: lin.recipe.defaults, support: lin.recipe.support,
                                             base: RenderSettings(mode: .explicit, decoderVersion: settings.decoderVersion,
                                                                  look: settings.look, lookIntensity: settings.lookIntensity))
        settings = decision.settings
        decisions = decision.reasons
        ctx = c
    }
    let out = try decoder.decode(url: url, settings: settings, scaleFactor: scale, decisions: decisions)
    var image = out.image
    if let lut = try renderer.resolveLook(settings.look) {
        image = try renderer.applyLook(lut, to: image, intensity: settings.lookIntensity)
    }
    return (image, out.recipe, ctx)
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

struct VariantResult: Codable {
    var name: String
    var deltaE00Mean: Double
    var deltaE00Median: Double
    var deltaE00P95: Double
    var metrics: ImageMetrics
    var seconds: Double
    var recipe: DecodeRecipe
    var context: SceneContext?
}

struct FileResult: Codable {
    var file: String
    var camera: String?
    var iso: Double?
    var analysisSize: [Int]
    var reference: ImageMetrics?
    var variants: [VariantResult]
    var error: String?
}

func benchFile(_ url: URL, outDir: URL, longEdge: Int, full: Bool) throws -> FileResult {
    let stem = url.deletingPathExtension().lastPathComponent
    let scale = try decoder.scaleFactor(url: url, longEdge: longEdge)
    let variants: [Variant] = [
        Variant(name: "explicit", settings: .explicit, auto: false),
        Variant(name: "sceneLinear", settings: .sceneLinear, auto: false),
        Variant(name: "auto", settings: .explicit, auto: true),
        Variant(name: "auto+warmNegative", settings: RenderSettings(mode: .explicit, look: "warmNegative", lookIntensity: 0.8), auto: true),
        Variant(name: "auto+coolSlide", settings: RenderSettings(mode: .explicit, look: "coolSlide", lookIntensity: 0.8), auto: true),
    ]
    var t0 = Date()
    let (refImage, refRecipe, _) = try develop(url, Variant(name: "appleDefault", settings: .appleDefault, auto: false), scale: scale)
    let refSeconds = Date().timeIntervalSince(t0)
    var renders: [(Variant, CIImage, DecodeRecipe, SceneContext?, Double)] = []
    for v in variants {
        t0 = Date()
        let (img, rec, ctx) = try develop(url, v, scale: scale)
        renders.append((v, img, rec, ctx, Date().timeIntervalSince(t0)))
    }
    // Common size so every comparison is pixel-aligned.
    let all = [refImage] + renders.map(\.1)
    let w = all.map { Int($0.extent.integral.width) }.min()!, h = all.map { Int($0.extent.integral.height) }.min()!
    let ref = try renderer.linearImage(refImage, size: (w, h))
    let refMetrics = ImageMetrics.measure(ref)
    try renderer.export(refImage, format: .jpeg).write(to: outDir.appendingPathComponent("\(stem)__appleDefault.jpg"))
    try refRecipe.prettyJSON().write(to: outDir.appendingPathComponent("\(stem)__appleDefault.recipe.json"), atomically: true, encoding: .utf8)

    var results: [VariantResult] = [VariantResult(name: "appleDefault", deltaE00Mean: 0, deltaE00Median: 0, deltaE00P95: 0,
                                                  metrics: refMetrics, seconds: refSeconds, recipe: refRecipe, context: nil)]
    for (v, img, rec, ctx, secs) in renders {
        let cand = try renderer.linearImage(img, size: (w, h))
        let cmp = try ComparisonMetrics.compare(candidate: cand, reference: ref)
        let safe = v.name.replacingOccurrences(of: "+", with: "_")
        try renderer.export(img, format: .jpeg).write(to: outDir.appendingPathComponent("\(stem)__\(safe).jpg"))
        try rec.prettyJSON().write(to: outDir.appendingPathComponent("\(stem)__\(safe).recipe.json"), atomically: true, encoding: .utf8)
        results.append(VariantResult(name: v.name, deltaE00Mean: cmp.deltaE00Mean, deltaE00Median: cmp.deltaE00Median,
                                     deltaE00P95: cmp.deltaE00P95, metrics: cmp.candidate, seconds: secs, recipe: rec, context: ctx))
    }
    if full {
        for v in [Variant(name: "appleDefault", settings: .appleDefault, auto: false), variants[3]] {
            let t = Date()
            let (img, _, _) = try develop(url, v, scale: 1)
            let data = try renderer.export(img, format: .heic10)
            let safe = v.name.replacingOccurrences(of: "+", with: "_")
            try data.write(to: outDir.appendingPathComponent("\(stem)__\(safe)__full.heic"))
            log(String(format: "  full-res %@ HEIC10: %.2fs, %.1f MB", v.name, Date().timeIntervalSince(t), Double(data.count) / 1e6))
        }
    }
    return FileResult(file: url.lastPathComponent, camera: refRecipe.camera, iso: refRecipe.iso, analysisSize: [w, h],
                      reference: refMetrics, variants: results, error: nil)
}

func markdown(_ files: [FileResult]) -> String {
    var md = "# raw-bench summary\n\n"
    md += "Reference = Apple's default CIRAWFilter decode of the same file (pixel-aligned). Metrics: docs/METRICS.md.\n"
    md += "OS: \(ProcessInfo.processInfo.operatingSystemVersionString)\n\n"
    for f in files {
        md += "## \(f.file) — \(f.camera ?? "?")" + (f.iso.map { ", ISO \(Int($0))" } ?? "") + "\n\n"
        if let e = f.error { md += "**ERROR:** \(e)\n\n"; continue }
        if let r = f.variants.first?.recipe {
            md += "decoder `\(r.decoderVersion)` (supported: \(r.supportedDecoderVersions.joined(separator: ", "))), native \(r.nativeSize[0])x\(r.nativeSize[1]), analysis \(f.analysisSize[0])x\(f.analysisSize[1])\n\n"
        }
        md += "| variant | ΔE00 mean | ΔE00 p95 | black p1 | black p5 | mean Y | median Y | clipped % | local contrast | halo ring Y | chroma | s |\n"
        md += "|---|---|---|---|---|---|---|---|---|---|---|---|\n"
        for v in f.variants {
            let m = v.metrics
            md += String(format: "| %@ | %.2f | %.2f | %.4f | %.4f | %.3f | %.3f | %.2f | %.3f | %@ | %.1f | %.2f |\n",
                         v.name, v.deltaE00Mean, v.deltaE00P95, m.blackP1, m.blackP5, m.meanY, m.medianY, m.clippedFraction * 100,
                         m.localContrast, m.highlightRingMeanY.map { String(format: "%.3f", $0) } ?? "–", m.meanChroma, v.seconds)
        }
        if let auto = f.variants.first(where: { $0.name == "auto" }) {
            md += "\nauto decisions: " + auto.recipe.decisions.joined(separator: "; ") + "\n"
            if let c = auto.context {
                md += String(format: "context: DR %.1f stops, log p1/p50/p99 %.2f/%.2f/%.2f, clipped %.2f%%", c.dynamicRangeStops, c.logP1, c.logP50, c.logP99, c.clippedFraction * 100)
                md += ", faces \(c.faceCount.map(String.init) ?? "n/a")"
                if let l = c.labels, !l.isEmpty {
                    md += ", labels " + l.sorted { $0.value > $1.value }.prefix(5).map { String(format: "%@ %.2f", $0.key, $0.value) }.joined(separator: ", ")
                }
                md += "\n"
            }
        }
        if let d = f.variants.first?.recipe.defaults {
            md += "\nApple defaults: exposure \(d.exposure), baselineExposure \(d.baselineExposure), shadowBias \(d.shadowBias), boost \(d.boostAmount), boostShadow \(d.boostShadowAmount), LTM \(d.localToneMapAmount), sharpness \(d.sharpnessAmount), contrast \(d.contrastAmount), detail \(d.detailAmount), lumNR \(d.luminanceNoiseReductionAmount), colorNR \(d.colorNoiseReductionAmount), moire \(d.moireReductionAmount), EDR \(d.extendedDynamicRangeAmount), lens \(d.lensCorrection), gamutMap \(d.gamutMapping), temp \(d.neutralTemperature), tint \(d.neutralTint)\n"
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
        for p in rest {
            let url = URL(fileURLWithPath: p)
            let out = try decoder.decode(url: url, settings: .appleDefault, scaleFactor: 0.1)
            print(out.recipe.prettyJSON())
        }
    case "render":
        guard let p = rest.first else { print(usage); return 2 }
        let url = URL(fileURLWithPath: p)
        let v = variant(from: a)
        let format = Renderer.Format(rawValue: a.options["format"] ?? "heic10") ?? .heic10
        let scale = a.options["scale"].flatMap(Float.init) ?? 1
        let t = Date()
        let (img, rec, _) = try develop(url, v, scale: scale)
        let ext = format == .heic10 ? "heic" : (format == .png16 ? "png" : "jpg")
        let outPath = a.options["out"] ?? url.deletingPathExtension().lastPathComponent + "__\(v.name).\(ext)"
        try renderer.export(img, format: format).write(to: URL(fileURLWithPath: outPath))
        try rec.prettyJSON().write(toFile: outPath + ".recipe.json", atomically: true, encoding: .utf8)
        log(String(format: "wrote %@ (%.2fs)", outPath, Date().timeIntervalSince(t)))
    case "compare":
        guard let p = rest.first else { print(usage); return 2 }
        let url = URL(fileURLWithPath: p)
        let scale = try decoder.scaleFactor(url: url, longEdge: a.options["long-edge"].flatMap(Int.init) ?? 1024)
        let (ref, _, _) = try develop(url, Variant(name: "appleDefault", settings: .appleDefault, auto: false), scale: scale)
        let (cand, rec, _) = try develop(url, variant(from: a), scale: scale)
        let w = min(Int(ref.extent.integral.width), Int(cand.extent.integral.width))
        let h = min(Int(ref.extent.integral.height), Int(cand.extent.integral.height))
        let cmp = try ComparisonMetrics.compare(candidate: renderer.linearImage(cand, size: (w, h)), reference: renderer.linearImage(ref, size: (w, h)))
        print(cmp.prettyJSON())
        log("decisions: " + rec.decisions.joined(separator: "; "))
    case "bench":
        guard let dir = rest.first, let out = a.options["out"] else { print(usage); return 2 }
        let outDir = URL(fileURLWithPath: out)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let files = try FileManager.default.contentsOfDirectory(atPath: dir)
            .filter { rawExtensions.contains(($0 as NSString).pathExtension.lowercased()) }.sorted()
        let longEdge = a.options["long-edge"].flatMap(Int.init) ?? 1024
        var results: [FileResult] = []
        for f in files {
            log("bench \(f)")
            let url = URL(fileURLWithPath: dir).appendingPathComponent(f)
            do { results.append(try benchFile(url, outDir: outDir, longEdge: longEdge, full: a.flags.contains("full"))) } catch {
                log("  ERROR \(error)")
                results.append(FileResult(file: f, camera: nil, iso: nil, analysisSize: [0, 0], reference: nil,
                                          variants: [], error: "\(error)"))
            }
        }
        try results.prettyJSON().write(to: outDir.appendingPathComponent("summary.json"), atomically: true, encoding: .utf8)
        let md = markdown(results)
        try md.write(to: outDir.appendingPathComponent("summary.md"), atomically: true, encoding: .utf8)
        print(md)
        if results.contains(where: { $0.error != nil }) { return 1 }
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
