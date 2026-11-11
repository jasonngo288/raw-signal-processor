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
  raw-bench compare <raw> [--mode ...] [--look ...] [--long-edge N] [--native]   metrics + ΔE00 vs appleDefault; --native adds
                   edge overshoot / HF ratio / flat texture on native-pixel crops (centre 1024² + 4 tiles)
  raw-bench bench <dir>... --out <dir> [--manifest corpus.json] [--long-edge N] [--full] [--crops] [--native [--native-stock NAME|none]]
  raw-bench pairs <dir>... --out <dir> [--long-edge N]   device captures (<dir>/*/capture.dng + apple.heic): vs the camera HEIC
  raw-bench chart <raw> --corners x1,y1,x2,y2,x3,y3,x4,y4 [--model KEY] [--reference sheet.txt] [--calibration-out models.json] [--out chart.json]
                   ColorChecker Classic: corners = centres of dark skin (top-left), bluish green (top-right), black (bottom-right),
                   white (bottom-left), normalised 0..1 from the image's top-left. Fits the model's CCM, re-decodes to verify.
  raw-bench gate3 <chart.json> <chart.json>...    Gate 3: ΔE00 between models' corrected charts (pass: mean < 2)
  raw-bench lutcheck [dir]                        check LUT manifests (default: bundled Looks/): route, sha256, fields, licence
  raw-bench looks <raw|dir>... --out <dir> [--looks a,b] [--long-edge N] [--manifest corpus.json]   film-look set: base once, every look, metrics (look review tool)
  raw-bench lut <in.cube|in.mrlut> --out <out.cube|out.mrlut>   convert LUTs (MoodRoll .mrlut packed format), print round-trip error
  raw-bench storage <raw>... [--stock NAME] [--out <dir>]   base render stored as HEIC10/PNG16/TIFF16/EXR/JPEG: size and ΔE00 vs in-memory
  common options: --plugins none|highlightRecovery,cameraMatch,vignette   --calibration models.json

Looks: \(BuiltInLook.allCases.map(\.rawValue).joined(separator: ", ")) or a .cube path.
Stocks (--stock, look + grain/halation/vignette): \(FilmStock.all.map { "\($0.name) (\($0.summary))" }.joined(separator: "; "))
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

var dev = Developer()
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
    s.stock = a.options["stock"]
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
    var brightMeanY: Double?
    var brightLocalContrast: Double?
    var metrics: ImageMetrics
    var skinDeltaE: Double? = nil
    var nonSkinDeltaE: Double? = nil
    var seconds: Double
    var recipe: DecodeRecipe
    var context: SceneContext?
}

struct Gates: Codable {
    var gate1: Bool
    var gate2: Bool
    var gate2Reasons: [String]
    var gate2Core: Bool
    var gate2CoreReasons: [String]
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
    /// Scene-linear median log2 luminance (SceneContext.logP50): the input of the dark-scene rule, printed so its
    /// threshold can be set from tuning files only.
    var sceneMedianStops: Double? = nil
    /// Native-resolution sharpness (bench --native).
    var native: NativeResult? = nil
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
    var coreWhy: [String] = []
    if let core = vs.first(where: { $0.name == "auto core" }) {
        if core.deltaE00MeanUnclipped > 3 { coreWhy.append(String(format: "core ΔE unclipped %.2f > 3", core.deltaE00MeanUnclipped)) }
        if core.metrics.blackP1 > ref.metrics.blackP1 + 0.002 { coreWhy.append("core black p1 raised") }
        if let a = core.ringOnReferenceMask, let r = ref.metrics.highlightRingMeanY, a > r + 0.01 { coreWhy.append("core halo ring brighter") }
    }
    return Gates(gate1: exp.deltaE00Mean < 0.5, gate2: why.isEmpty, gate2Reasons: why, gate2Core: coreWhy.isEmpty, gate2CoreReasons: coreWhy)
}

/// Writes an image with its recipe embedded and a sidecar .recipe.json next to it (AGENTS.md rule 1).
func save(_ image: CIImage, recipe: DecodeRecipe, name: String, outDir: URL, format: Renderer.Format = .jpeg, quality: Double = 0.92) throws -> Int {
    let ext = format == .heic10 ? "heic" : (format == .png16 ? "png" : "jpg")
    let data = try renderer.export(image, format: format, quality: quality, recipe: recipe)
    try data.write(to: outDir.appendingPathComponent("\(name).\(ext)"))
    try recipe.prettyJSON().write(to: outDir.appendingPathComponent("\(name).recipe.json"), atomically: true, encoding: .utf8)
    return data.count
}

func benchFile(_ url: URL, entry: CorpusEntry?, outDir: URL, longEdge: Int, full: Bool, crops: Bool, native: Bool = false, nativeStock: String? = "warm400") throws -> FileResult {
    let stem = url.deletingPathExtension().lastPathComponent
    let scale = try decoder.scaleFactor(url: url, longEdge: longEdge)
    let analysis = try dev.analyze(url: url)
    var core = RenderSettings(mode: .explicit)
    core.plugins = []
    var variants: [Variant] = [
        Variant(name: "explicit", settings: .explicit, auto: false),
        Variant(name: "sceneLinear", settings: .sceneLinear, auto: false),
        Variant(name: "auto", settings: .explicit, auto: true),
        Variant(name: "auto core", settings: core, auto: true),   // roadmap core, every plugin unplugged
    ] + FilmStock.all.map { stock in
        var st = RenderSettings(mode: .explicit)
        st.stock = stock.name
        return Variant(name: "auto+\(stock.name)", settings: st, auto: true)
    }
    let hasPeople = (analysis.context.personFraction ?? 0) >= DecisionEngine.Threshold.personFraction
        || (analysis.context.largestFaceArea ?? 0) >= DecisionEngine.Threshold.faceArea
    if hasPeople {
        var st = RenderSettings(mode: .explicit)
        st.stock = "warm400"; st.skinProtection = 0
        variants.append(Variant(name: "auto+warm400 noSkin", settings: st, auto: true))
    }
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
    _ = try save(ref.image, recipe: ref.recipe, name: "\(stem)__appleDefault", outDir: outDir)

    // Person mask at bench size: skin ΔE = how much a look changes people (vs the auto base render).
    var skinMask: [Bool]?
    if hasPeople, let m = analysis.personMask {
        let e = ref.image.extent, me = m.extent
        let scaled = m.transformed(by: CGAffineTransform(translationX: -me.minX, y: -me.minY))
            .transformed(by: CGAffineTransform(scaleX: e.width / me.width, y: e.height / me.height))
            .transformed(by: CGAffineTransform(translationX: e.minX, y: e.minY)).cropped(to: e)
        let lin = try renderer.linearImage(scaled, size: (w, h))
        skinMask = (0..<(w * h)).map { lin.pixels[$0 * 3] > 0.25 }
    }
    let autoLin = try renderer.linearImage(renders.first { $0.0.name == "auto" }!.1.image, size: (w, h))

    var results = [VariantResult(name: "appleDefault", deltaE00Mean: 0, deltaE00MeanUnclipped: 0, deltaE00P95: 0,
                                 ringOnReferenceMask: refMetrics.highlightRingMeanY, brightMeanY: nil, brightLocalContrast: nil,
                                 metrics: refMetrics, seconds: refSeconds, recipe: ref.recipe, context: nil)]
    for (v, o, secs) in renders {
        let cand = try renderer.linearImage(o.image, size: (w, h))
        let cmp = try ComparisonMetrics.compare(candidate: cand, reference: refLin)
        _ = try save(o.image, recipe: o.recipe, name: "\(stem)__\(v.name.replacingOccurrences(of: "+", with: "_").replacingOccurrences(of: " ", with: "_"))", outDir: outDir)
        var r = VariantResult(name: v.name, deltaE00Mean: cmp.deltaE00Mean, deltaE00MeanUnclipped: cmp.deltaE00MeanUnclipped,
                              deltaE00P95: cmp.deltaE00P95, ringOnReferenceMask: cmp.candidateRingOnReferenceMask,
                              brightMeanY: cmp.brightMeanYCandidate, brightLocalContrast: cmp.brightLocalContrastCandidate,
                              metrics: cmp.candidate, seconds: secs, recipe: o.recipe, context: o.context)
        if let skinMask, v.name.hasPrefix("auto+") {
            let vsAuto = try ComparisonMetrics.compare(candidate: cand, reference: autoLin, mask: skinMask)
            r.skinDeltaE = vsAuto.deltaE00MeanMasked
            r.nonSkinDeltaE = vsAuto.deltaE00MeanOutsideMask
        }
        results.append(r)
    }
    if let firstCmp = try? ComparisonMetrics.compare(candidate: refLin, reference: refLin) {
        results[0].brightMeanY = firstCmp.brightMeanYReference
        results[0].brightLocalContrast = firstCmp.brightLocalContrastReference
    }
    // 100 % crops (full resolution, centre 640 x 640) to judge grain and halation at real pixel size.
    if crops {
        for v in [Variant(name: "appleDefault", settings: .appleDefault, auto: false)] + variants.filter({ ["auto+warm400", "auto+night800"].contains($0.name) }) {
            let o = try dev.develop(url: url, settings: v.settings, auto: v.auto, scaleFactor: 1, analysis: analysis)
            let e = o.image.extent
            let rect = CGRect(x: e.midX - 320, y: e.midY - 320, width: 640, height: 640)
            let crop = o.image.cropped(to: rect)
            var rec = o.recipe
            rec.decisions.append("bench crop: 640x640 at (\(Int(rect.minX)), \(Int(rect.minY))) of the full-resolution render")
            _ = try save(crop, recipe: rec, name: "\(stem)__crop100__\(v.name.replacingOccurrences(of: "+", with: "_"))", outDir: outDir, quality: 0.9)
        }
    }
    if full {
        for v in [Variant(name: "appleDefault", settings: .appleDefault, auto: false), variants.first(where: { $0.name == "auto+warm400" })!] {
            let t = Date()
            let o = try dev.develop(url: url, settings: v.settings, auto: v.auto, scaleFactor: 1, analysis: analysis)
            let bytes = try save(o.image, recipe: o.recipe, name: "\(stem)__\(v.name.replacingOccurrences(of: "+", with: "_"))__full", outDir: outDir, format: .heic10)
            log(String(format: "  full-res %@ HEIC10: %.2fs, %.1f MB", v.name, Date().timeIntervalSince(t), Double(bytes) / 1e6))
        }
    }
    var nativeResult: NativeResult?
    if native { nativeResult = try nativeSharpness(url, variants: nativeVariants(stockName: nativeStock), analysis: analysis) }
    return FileResult(file: url.lastPathComponent, corpus: entry, camera: ref.recipe.camera, iso: ref.recipe.iso, analysisSize: [w, h],
                      reference: refMetrics, variants: results, gates: gates(results), error: nil,
                      sceneMedianStops: analysis.context.logP50, native: nativeResult)
}

func f2(_ v: Double?) -> String { v.map { String(format: "%.2f", $0) } ?? "–" }

func markdown(_ files: [FileResult]) -> String {
    var md = "# raw-bench summary\n\n"
    md += "Reference = Apple's default CIRAWFilter decode of the same file (pixel-aligned). Metrics: docs/METRICS.md.\n"
    md += "OS: \(ProcessInfo.processInfo.operatingSystemVersionString)\n\n"
    md += "## Gates\n\n| id | file | category | split | camera | scene median (stops) | Gate 1 | Gate 2 (auto) | Gate 2 (core) | auto decisions |\n|---|---|---|---|---|---|---|---|---|---|\n"
    for f in files {
        let c = f.corpus
        // Gate 1 compares at different decoder versions when DecoderPolicy pins another version than Apple's default
        // (kept on purpose, user 2026-11-09): say so, so a version difference is not read as lost decoder control.
        let vRef = f.variants.first(where: { $0.name == "appleDefault" })?.recipe.decoderVersion
        let vExp = f.variants.first(where: { $0.name == "explicit" })?.recipe.decoderVersion
        let versionNote = (vRef != nil && vExp != nil && vRef != vExp) ? " (policy \(vExp!) ≠ Apple default \(vRef!))" : ""
        let g1 = f.gates.map { ($0.gate1 ? "PASS" : "FAIL") + versionNote } ?? (f.error == nil ? "–" : "ERROR")
        let g2 = f.gates.map { $0.gate2 ? "PASS" : "FAIL: " + $0.gate2Reasons.joined(separator: "; ") } ?? (f.error ?? "–")
        let dec = f.variants.first(where: { $0.name == "auto" })?.recipe.decisions.joined(separator: "; ") ?? ""
        let g2c = f.gates.map { $0.gate2Core ? "PASS" : "FAIL: " + $0.gate2CoreReasons.joined(separator: "; ") } ?? "–"
        md += "| \(c?.id ?? "") | \(f.file) | \(c?.category ?? "") | \(c?.split ?? "") | \(f.camera ?? "?") | \(f2(f.sceneMedianStops)) | \(g1) | \(g2) | \(g2c) | \(dec) |\n"
    }
    md += "\n"
    for f in files {
        md += "## \(f.corpus?.id ?? "") \(f.file) — \(f.camera ?? "?")" + (f.iso.map { ", ISO \(Int($0))" } ?? "") + "\n\n"
        if let c = f.corpus { md += "\(c.category) · \(c.condition) · split **\(c.split)** · \(c.provenance) · \(c.author), \(c.license)\n\n" }
        if let e = f.error { md += "**ERROR:** \(e)\n\n"; continue }
        if let r = f.variants.first?.recipe {
            md += "decoder `\(r.decoderVersion)` (supported: \(r.supportedDecoderVersions.joined(separator: ", "))), native \(r.nativeSize[0])x\(r.nativeSize[1]), analysis \(f.analysisSize[0])x\(f.analysisSize[1])\n\n"
        }
        md += "| variant | ΔE00 mean | ΔE00 unclipped | ΔE00 p95 | black p1 | mean Y | clipped % | local contrast | halo ring Y (own / ref mask) | bright Y | bright LC | chroma | s |\n"
        md += "|---|---|---|---|---|---|---|---|---|---|---|---|---|\n"
        for v in f.variants {
            let m = v.metrics
            md += String(format: "| %@ | %.2f | %.2f | %.2f | %.4f | %.3f | %.2f | %.3f | %@ | %@ | %@ | %.1f | %.2f |\n",
                         v.name, v.deltaE00Mean, v.deltaE00MeanUnclipped, v.deltaE00P95, m.blackP1, m.meanY, m.clippedFraction * 100,
                         m.localContrast, f2(m.highlightRingMeanY) + " / " + f2(v.ringOnReferenceMask),
                         v.brightMeanY.map { String(format: "%.3f", $0) } ?? "–", v.brightLocalContrast.map { String(format: "%.3f", $0) } ?? "–", m.meanChroma, v.seconds)
        }
        if let n = f.native { md += "\n" + nativeMarkdown(n) }
        let skin = f.variants.filter { $0.skinDeltaE != nil }
        if !skin.isEmpty {
            md += "\nlook change on people vs elsewhere (ΔE00 vs auto base, Vision person mask): "
            md += skin.map { String(format: "%@ skin %.2f / rest %.2f", $0.name, $0.skinDeltaE!, $0.nonSkinDeltaE ?? 0) }.joined(separator: "; ") + "\n"
        }
        if let c = f.variants.first(where: { $0.name == "auto" })?.context {
            md += String(format: "\ncontext: DR %.1f stops (p1 %.2f, p50 %.2f, p99.9 %@), sensor clipped %.2f%%, display clipped %@%%, EDR headroom %@x, faces %@",
                         c.dynamicRangeStops, c.logP1, c.logP50, f2(c.logP999), c.clippedFraction * 100,
                         f2(c.displayClippedFraction.map { $0 * 100 }), f2(c.edrHeadroom), c.faceCount.map(String.init) ?? "n/a")
            md += String(format: ", people %@%%, saliency %@, CCT %@ K", f2(c.personFraction.map { $0 * 100 }),
                         c.saliencyBox.map { $0.map { String(format: "%.2f", $0) }.joined(separator: ",") } ?? "–", f2(c.cct))
            if let l = c.labels, !l.isEmpty {
                md += ", labels " + l.sorted { $0.value > $1.value }.prefix(5).map { String(format: "%@ %.2f", $0.key, $0.value) }.joined(separator: ", ")
            }
            md += "\n"
        }
        md += "\n"
    }
    return md
}

/// Device pairs: our renders vs the camera's own HEIC from the same press (CaptureKit output folders).
func midEV(_ a: LinearImage, vs b: LinearImage) -> Double {
    let ya = a.pixelsLuminanceUnclamped().sorted(), yb = b.pixelsLuminanceUnclamped().sorted()
    var d: [Double] = []
    for q in stride(from: 0.30, through: 0.701, by: 0.05) {
        let i = Int(q * Double(ya.count - 1)), j = Int(q * Double(yb.count - 1))
        if ya[i] > 1e-4, yb[j] > 1e-4 { d.append(log2(Double(ya[i]) / Double(yb[j]))) }
    }
    d.sort()
    return d.isEmpty ? 0 : d[d.count / 2]
}

func benchPairs(_ dirs: [String], outDir: URL, longEdge: Int) throws -> String {
    var md = "# Device pairs: renders vs the camera HEIC (same shutter press)\n\n"
    md += "Reference = `apple.heic` (Apple's camera pipeline). mid EV = render minus HEIC on mid-tone quantiles (alignment-free); "
    md += "ΔE00 assumes the two images are pixel-aligned (same press, same size).\n\n"
    var folders: [URL] = []
    for d in dirs {
        let base = URL(fileURLWithPath: d)
        for n in ((try? FileManager.default.contentsOfDirectory(atPath: d)) ?? []).sorted() {
            let f = base.appendingPathComponent(n)
            if FileManager.default.fileExists(atPath: f.appendingPathComponent("capture.dng").path),
               FileManager.default.fileExists(atPath: f.appendingPathComponent("apple.heic").path) { folders.append(f) }
        }
    }
    for f in folders {
        let name = f.lastPathComponent
        log("pair \(name)")
        let dng = f.appendingPathComponent("capture.dng"), heicPath = f.appendingPathComponent("apple.heic").path
        guard let heic = CIImage(contentsOf: URL(fileURLWithPath: heicPath), options: [.applyOrientationProperty: true]) else {
            md += "## \(name)\n\napple.heic unreadable\n\n"; continue
        }
        let scale = try decoder.scaleFactor(url: dng, longEdge: longEdge)
        let an = try dev.analyze(url: dng)
        var core = RenderSettings(mode: .explicit); core.plugins = []
        var noMatch = RenderSettings(mode: .explicit); noMatch.plugins = ["highlightRecovery", "vignette"]
        var match = RenderSettings(mode: .explicit); match.cameraReference = heicPath
        var matchStock = match; matchStock.stock = "PRESET_26_CPM35"
        let variants: [(String, RenderSettings, Bool)] = [("appleDefault", .appleDefault, false), ("auto core", core, true),
            ("auto (no cameraMatch)", noMatch, true), ("auto+cameraMatch", match, true), ("auto+cameraMatch+PRESET_26_CPM35", matchStock, true)]
        var outs: [(String, Developer.Output)] = []
        for (n, st, auto) in variants { outs.append((n, try dev.develop(url: dng, settings: st, auto: auto, scaleFactor: scale, analysis: an))) }
        let e = outs[0].1.image.extent
        let hs = CameraMatchPlugin.small(heic, longEdge: max(e.width, e.height))
        let w = Int(min(hs.extent.width, outs.map { $0.1.image.extent.width }.min()!)), h = Int(min(hs.extent.height, outs.map { $0.1.image.extent.height }.min()!))
        let refLin = try renderer.linearImage(hs, size: (w, h))
        let refM = ImageMetrics.measure(refLin)
        _ = try save(hs, recipe: outs[0].1.recipe, name: "pair_\(name)__camera_heic", outDir: outDir)
        md += "## \(name) — \(outs[0].1.recipe.camera ?? "?"), ISO \(outs[0].1.recipe.iso.map { String(Int($0)) } ?? "?")\n\n"
        md += "| variant | mid EV vs HEIC | ΔE00 mean vs HEIC | ΔE00 p95 | clipped % | black p1 | mean Y |\n|---|---|---|---|---|---|---|\n"
        md += String(format: "| camera HEIC | 0.00 | 0.00 | 0.00 | %.2f | %.4f | %.3f |\n", refM.clippedFraction * 100, refM.blackP1, refM.meanY)
        for (n, o) in outs {
            let lin = try renderer.linearImage(o.image, size: (w, h))
            let cmp = try ComparisonMetrics.compare(candidate: lin, reference: refLin)
            md += String(format: "| %@ | %+.2f | %.2f | %.2f | %.2f | %.4f | %.3f |\n", n, midEV(lin, vs: refLin), cmp.deltaE00Mean, cmp.deltaE00P95,
                         cmp.candidate.clippedFraction * 100, cmp.candidate.blackP1, cmp.candidate.meanY)
            _ = try save(o.image, recipe: o.recipe, name: "pair_\(name)__\(n.replacingOccurrences(of: "+", with: "_").replacingOccurrences(of: " ", with: "_").replacingOccurrences(of: "(", with: "").replacingOccurrences(of: ")", with: ""))", outDir: outDir)
        }
        let dec = outs.first { $0.0 == "auto+cameraMatch" }!.1.recipe.decisions.filter { $0.hasPrefix("[cameraMatch]") }
        md += "\ncameraMatch: " + dec.joined(separator: "; ") + "\n\n"
    }
    return md
}

/// Gate 3 tooling: chart → CCM (verified by re-decoding with it) → calibration entry + chart file.
func chartCommand(_ url: URL, corners: ColorChecker.Corners, model: String?, referencePath: String?, calibrationOut: String?, out: String?) throws -> ChartMeasurement {
    var refLab = ColorChecker.referenceLabD50
    if let referencePath {
        guard let r = ColorChecker.parseReference(try String(contentsOfFile: referencePath, encoding: .utf8)) else {
            throw RawCoreError.invalidSettings("--reference \(referencePath): need exactly 24 'L a b' (D50) lines in chart order")
        }
        refLab = r
    }
    let scale = try decoder.scaleFactor(url: url, longEdge: 2048)
    let version = DecoderPolicy.pick(supported: try decoder.info(url: url).supported)
    func measure(_ ccm: [Float]?) throws -> [SIMD3<Double>] {
        var st = RenderSettings(mode: .sceneLinear, decoderVersion: version)
        st.ccm = ccm
        let o = try decoder.decode(url: url, settings: st, scaleFactor: scale)
        return ColorChecker.sample(try renderer.linearImage(o.image), corners: corners)
    }
    let measured = try measure(nil)
    guard let fit = ColorChecker.fit(measured: measured, reference: refLab.map(ColorChecker.referenceLinearP3)) else { throw RawCoreError.invalidSettings("chart fit failed: check --corners (patches not found)") }
    let corrected = try measure(fit.ccm.map(Float.init))
    let ref = refLab.map(ColorChecker.referenceLinearP3).map(ColorChecker.labD65)
    let verified = (0..<24).map { ColorChecker.deltaE(ColorChecker.labD65(corrected[$0] * fit.exposureScale), ref[$0]) }
    let fileKey = try dev.cameraKeys(url).compactMap { $0 }.first
    let key = model ?? fileKey ?? url.lastPathComponent
    let m = ChartMeasurement(model: key, rawKind: nil, file: url.lastPathComponent, corners: corners, measured: measured,
                             corrected: corrected, fit: fit, verifiedDeltaE: verified,
                             referenceLab: referencePath == nil ? nil : refLab, referenceSource: referencePath.map { URL(fileURLWithPath: $0).lastPathComponent })
    var md = "# ColorChecker \(url.lastPathComponent) → model `\(key)`\n\n"
    md += "reference: " + (referencePath.map { "`\(URL(fileURLWithPath: $0).lastPathComponent)` (--reference)" } ?? "built-in X-Rite post-2014 table") + "\n\n"
    md += String(format: "exposure scale %.3f (%.2f EV) · ΔE00 vs reference: before %.2f, fitted %.2f (max %.2f), **re-decoded with the CCM %.2f (max %.2f)**\n\n",
                 fit.exposureScale, log2(fit.exposureScale), fit.meanBefore, fit.meanAfter, fit.maxAfter,
                 verified.reduce(0, +) / 24, verified.max() ?? 0)
    md += "CCM (rows): " + (0..<3).map { r in (0..<3).map { String(format: "%.4f", fit.ccm[r * 3 + $0]) }.joined(separator: " ") }.joined(separator: " | ") + "\n\n"
    md += "| # | patch | measured (lin P3) | ΔE before | ΔE re-decoded |\n|---|---|---|---|---|\n"
    for i in 0..<24 {
        let p = measured[i]
        md += String(format: "| %d | %@ | %.3f %.3f %.3f%@ | %.2f | %.2f |\n", i + 1, ColorChecker.names[i], p.x, p.y, p.z, p.max() >= 0.98 ? " (clipped)" : "",
                     fit.deltaEBefore[i], verified[i])
    }
    print(md)
    if let out { try m.prettyJSON().write(to: URL(fileURLWithPath: out), atomically: true, encoding: .utf8) }
    if let calibrationOut {
        let u = URL(fileURLWithPath: calibrationOut)
        var table = (try? CalibrationTable.load(u)) ?? .empty
        table.models.removeAll { $0.model == key }
        table.models.append(ModelCalibration(model: key, ccm: fit.ccm.map(Float.init), exposureOffsetEV: 0, version: "chart-\(ISO8601DateFormatter().string(from: Date()).prefix(10))",
                                             source: String(format: "ColorChecker Classic, %@, reference %@, ΔE00 re-decoded %.2f", url.lastPathComponent,
                                                            referencePath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "built-in", verified.reduce(0, +) / 24)))
        try table.prettyJSON().write(to: u, atomically: true, encoding: .utf8)
        log("calibration entry \(key) written to \(calibrationOut)")
    }
    return m
}

func gate3Command(_ paths: [String]) throws -> Bool {
    let charts = try paths.map { try JSONDecoder().decode(ChartMeasurement.self, from: Data(contentsOf: URL(fileURLWithPath: $0))) }
    var pass = true
    print("# Gate 3: cross-model ColorChecker ΔE00 after each model's CCM (pass: mean < 2)\n")
    for i in 0..<charts.count {
        for j in (i + 1)..<charts.count {
            let a = charts[i], b = charts[j]
            if a.referenceLab != b.referenceLab { print("note: \(a.model) and \(b.model) were fitted to different reference tables") }
            let rl = a.referenceLab ?? ColorChecker.referenceLabD50
            let d = ColorChecker.compare(a.corrected ?? a.measured, b.corrected ?? b.measured, referenceLab: rl)
            let raw = ColorChecker.compare(a.measured, b.measured, referenceLab: rl)
            let mean = d.reduce(0, +) / Double(d.count)
            pass = pass && mean < 2
            print(String(format: "%@ vs %@: before CCM mean %.2f (max %.2f) → after CCM mean %.2f (max %.2f, %@) %@",
                         a.model, b.model, raw.reduce(0, +) / Double(raw.count), raw.max() ?? 0, mean, d.max() ?? 0,
                         ColorChecker.names[d.firstIndex(of: d.max() ?? 0) ?? 0], mean < 2 ? "PASS" : "FAIL"))
        }
    }
    return pass
}

func run() throws -> Int32 {
    let a = Args(Array(CommandLine.arguments.dropFirst()))
    guard let cmd = a.positional.first else { print(usage); return 2 }
    let rest = Array(a.positional.dropFirst())
    if let c = a.options["calibration"] { dev.calibration = try CalibrationTable.load(URL(fileURLWithPath: c)) }
    if let p = a.options["plugins"] {   // unplug from the CLI: --plugins none | id,id
        let ids = p == "none" ? [] : p.split(separator: ",").map(String.init)
        let known = Set(dev.plugins.available.map(\.id))
        if let bad = ids.first(where: { !known.contains($0) }) { throw RawCoreError.invalidSettings("unknown plugin \(bad)") }
        dev.plugins.defaultEnabled = ids
    }
    switch cmd {
    case "info":
        guard !rest.isEmpty else { print(usage); return 2 }
        for p in rest { print(try decoder.decode(url: URL(fileURLWithPath: p), settings: .appleDefault, scaleFactor: 0.1).recipe.prettyJSON()) }
        if let f = CIFilter(name: "CIToneMapHeadroom") { log("CIToneMapHeadroom inputs: \(f.inputKeys)") } else { log("CIToneMapHeadroom: not available") }
        log("plugins: " + dev.plugins.available.map { "\($0.id)\(dev.plugins.defaultEnabled.contains($0.id) ? " (on)" : " (off)"): \($0.summary)" }.joined(separator: "; "))
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
        try renderer.export(o.image, format: format, recipe: o.recipe).write(to: URL(fileURLWithPath: outPath))
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
        if a.flags.contains("native") {
            let an = try dev.analyze(url: url)
            let n = try nativeSharpness(url, variants: [v], analysis: an)
            print(nativeMarkdown(n))
        }
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
            do { results.append(try benchFile(url, entry: entry, outDir: outDir, longEdge: longEdge, full: a.flags.contains("full"), crops: a.flags.contains("crops"),
                                                 native: a.flags.contains("native"), nativeStock: a.options["native-stock"].map { $0 == "none" ? nil : $0 } ?? "warm400")) } catch {
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
    case "chart":
        guard let f = rest.first, let c = a.options["corners"].flatMap(ColorChecker.Corners.init) else { print(usage); return 2 }
        _ = try chartCommand(URL(fileURLWithPath: f), corners: c, model: a.options["model"], referencePath: a.options["reference"], calibrationOut: a.options["calibration-out"], out: a.options["out"])
    case "gate3":
        guard rest.count >= 2 else { print(usage); return 2 }
        return try gate3Command(rest) ? 0 : 1
    case "lutcheck":
        // LUT library contract: every <name>.manifest.json in the folder (default: RawCore's bundled Looks/).
        let lib = rest.first.map { LookLibrary(directory: URL(fileURLWithPath: $0)) } ?? LookLibrary.bundled
        var bad = 0
        for c in lib.checks {
            let route = c.route.map { "\($0)" } ?? "—"
            print("\(c.isUsable ? "OK  " : "FAIL") \(c.name)  route: \(route)")
            for p in c.problems { print("       ✗ \(p)") }
            for r in c.releaseBlockers { print("       ⚠︎ release: \(r)") }
            if !c.isUsable { bad += 1 }
        }
        print("\(lib.checks.count) manifests, \(lib.entries.count) usable, \(bad) rejected")
        return bad == 0 ? 0 : 1
    case "looks":
        guard !rest.isEmpty, let out = a.options["out"] else { print(usage); return 2 }
        let run = try looksCommand(rest, out: out, looks: a.options["looks"].map { $0.split(separator: ",").map(String.init) },
                                   longEdge: a.options["long-edge"].flatMap(Int.init) ?? 1600, manifest: a.options["manifest"],
                                   sceneIntensity: !a.flags.contains("no-scene-intensity"))
        log("wrote \(run.rows.count) renders to \(out)")
    case "lut":
        // Convert between .cube and .mrlut (MoodRoll's packed format) and report the round-trip error.
        guard let src = rest.first, let dst = a.options["out"] else { print(usage); return 2 }
        let lut = try CubeLUT.load(any: URL(fileURLWithPath: src))
        let outURL = URL(fileURLWithPath: dst)
        if outURL.pathExtension.lowercased() == LUTBinaryFormat.fileExtension {
            try LUTBinaryFormat.encode(lut).write(to: outURL)
        } else {
            try lut.cubeText(comments: ["converted by raw-bench lut"]).write(to: outURL, atomically: true, encoding: .utf8)
        }
        let back = try CubeLUT.load(any: outURL)
        let err = zip(lut.rgba, back.rgba).map { abs($0 - $1) }.max() ?? 0
        let bytes = (try? FileManager.default.attributesOfItem(atPath: dst)[.size] as? Int) ?? 0
        print(String(format: "%@ → %@: %d³, %d bytes, max round-trip error %.6f", src, dst, lut.size, bytes, err))
    case "storage":
        guard !rest.isEmpty else { print(usage); return 2 }
        print(try storageCommand(rest, stockName: a.options["stock"] ?? "slide100", out: a.options["out"]))
    case "pairs":
        guard !rest.isEmpty, let out = a.options["out"] else { print(usage); return 2 }
        let outDir = URL(fileURLWithPath: out)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let md = try benchPairs(rest, outDir: outDir, longEdge: a.options["long-edge"].flatMap(Int.init) ?? 1024)
        try md.write(to: outDir.appendingPathComponent("pairs.md"), atomically: true, encoding: .utf8)
        print(md)
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
