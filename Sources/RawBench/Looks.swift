#if canImport(CoreImage)
import CoreImage
import Foundation
import RawCore

/// `raw-bench looks <raw|dir>... --out <dir> [--looks a,b] [--long-edge N]`: for the look review tool.
/// Per file: Apple's default render, our auto base (no look) developed once, then every look finished on that base.
/// Writes <out>/<file>/<name>.jpg and <out>/looks.json with per-image metrics vs the base and vs appleDefault.
struct LookRow: Codable {
    var file: String
    var id: String?
    var category: String?
    var split: String?
    var look: String
    var image: String
    var clippedPercent: Double
    var blackP1: Double
    var meanY: Double
    var deltaE00VsBase: Double
    var chromaRatioVsBase: Double
    /// Mean OKLCh hue shift (degrees) on skin-coloured pixels inside the Vision person mask; nil without people.
    var skinHueShift: Double?
    var skinPixels: Int
    /// Sky (blue-hue, bright pixels in the top 40 % of the frame, chosen on the base): OKLab lightness, chroma and
    /// lightness spread of the same pixels in this render. nil when the frame has < 0.5 % sky. "Washed sky" = chroma
    /// down and spread (gradient depth) down vs base.
    var skyL: Double? = nil
    var skyChroma: Double? = nil
    var skySpread: Double? = nil
    var decisions: [String]
}

struct LooksRun: Codable {
    var created: String
    var longEdge: Int
    var looks: [String]
    var rows: [LookRow]
}

private func jpeg(_ image: CIImage, to url: URL) throws {
    try renderer.export(image, format: .jpeg, quality: 0.9).write(to: url)
}

/// Skin pixels: inside the person mask (> 0.5) and skin-coloured in the base (OKLCh hue 20…90°, chroma > 0.03).
private func skinShift(base: LinearImage, looked: LinearImage, mask: LinearImage?) -> (Double?, Int) {
    guard let mask else { return (nil, 0) }
    var sum = SIMD2<Double>(0, 0), n = 0
    func lch(_ img: LinearImage, _ i: Int) -> SIMD3<Float> {
        let lab = OKLab.fromLinearP3(SIMD3(img.pixels[i * 3], img.pixels[i * 3 + 1], img.pixels[i * 3 + 2]))
        var h = atan2(lab.z, lab.y) * 180 / .pi; if h < 0 { h += 360 }
        return SIMD3(lab.x, (lab.y * lab.y + lab.z * lab.z).squareRoot(), h)
    }
    for i in stride(from: 0, to: base.pixelCount, by: 2) where mask.pixels[i * 3] > 0.5 {
        let a = lch(base, i)
        guard a.z >= 20, a.z <= 90, a.y > 0.03 else { continue }
        let b = lch(looked, i)
        var d = Double(b.z - a.z); if d > 180 { d -= 360 }; if d < -180 { d += 360 }
        sum += SIMD2(cos(d * .pi / 180), sin(d * .pi / 180)); n += 1
    }
    guard n >= 200 else { return (nil, n) }
    return (atan2(sum.y, sum.x) * 180 / .pi, n)
}

private func lchAt(_ img: LinearImage, _ i: Int) -> SIMD3<Float> {
    let c = SIMD3(min(max(img.pixels[i * 3], 0), 1), min(max(img.pixels[i * 3 + 1], 0), 1), min(max(img.pixels[i * 3 + 2], 0), 1))
    let lab = OKLab.fromLinearP3(c)
    var h = atan2(lab.z, lab.y) * 180 / .pi
    if h < 0 { h += 360 }
    return SIMD3(lab.x, (lab.y * lab.y + lab.z * lab.z).squareRoot(), h)
}

/// Sky pixels on the base: top 40 % of rows, OKLCh hue 190...290, L > 0.55, chroma > 0.02.
private func skyMask(_ base: LinearImage) -> [Int] {
    var idx: [Int] = []
    let rows = Int(Double(base.height) * 0.4)
    for y in 0..<rows {
        for x in 0..<base.width {
            let i = y * base.width + x
            let l = lchAt(base, i)
            if l.x > 0.55, l.y > 0.02, (190...290).contains(l.z) { idx.append(i) }
        }
    }
    return Double(idx.count) >= 0.005 * Double(base.width * base.height) ? idx : []
}

private func skyStats(_ img: LinearImage, _ idx: [Int]) -> (Double, Double, Double)? {
    guard !idx.isEmpty else { return nil }
    var ls: [Double] = [], c = 0.0
    for i in idx {
        let l = lchAt(img, i)
        ls.append(Double(l.x)); c += Double(l.y)
    }
    let m = ls.reduce(0, +) / Double(ls.count)
    let sd = (ls.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Double(ls.count)).squareRoot()
    return (m, c / Double(idx.count), sd)
}

private func chroma(_ img: LinearImage) -> Double {
    var s = 0.0
    for i in stride(from: 0, to: img.pixelCount, by: 4) {
        let lab = OKLab.fromLinearP3(SIMD3(img.pixels[i * 3], img.pixels[i * 3 + 1], img.pixels[i * 3 + 2]))
        s += Double((lab.y * lab.y + lab.z * lab.z).squareRoot())
    }
    return s / Double(max(img.pixelCount / 4, 1))
}

func looksCommand(_ inputs: [String], out: String, looks wanted: [String]?, longEdge: Int, manifest: String?,
                  sceneIntensity: Bool = true) throws -> LooksRun {
    var entries: [String: CorpusEntry] = [:]
    if let m = manifest {
        for e in try JSONDecoder().decode(CorpusManifest.self, from: Data(contentsOf: URL(fileURLWithPath: m))).files { entries[e.file] = e }
    }
    let lookNames = wanted ?? FilmLooks2026.names
    for n in lookNames where FilmStock.named(n) == nil { throw RawCoreError.invalidSettings("unknown look \(n)") }
    var urls: [URL] = []
    for p in inputs {
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: p, isDirectory: &isDir), isDir.boolValue {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: p)) ?? []
            urls += names.filter { rawExtensions.contains(($0 as NSString).pathExtension.lowercased()) }.sorted()
                .map { URL(fileURLWithPath: p).appendingPathComponent($0) }
        } else { urls.append(URL(fileURLWithPath: p)) }
    }
    let outDir = URL(fileURLWithPath: out)
    try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
    var rows: [LookRow] = []
    for url in urls {
        let stem = url.deletingPathExtension().lastPathComponent
        let e = entries[url.lastPathComponent]
        log("looks \(url.lastPathComponent)")
        do {
            let dir = outDir.appendingPathComponent(stem)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let scale = try decoder.scaleFactor(url: url, longEdge: longEdge)
            let analysis = try dev.analyze(url: url)
            let apple = try dev.develop(url: url, settings: .appleDefault, auto: false, scaleFactor: scale).image
            var base = try dev.developBase(url: url, settings: .explicit, auto: true, scaleFactor: scale, analysis: analysis)
            let baseOut = try dev.finish(base)
            let size = (Int(baseOut.image.extent.integral.width), Int(baseOut.image.extent.integral.height))
            let baseLin = try renderer.linearImage(baseOut.image, size: size)
            let baseChroma = chroma(baseLin)
            let sky = skyMask(baseLin)
            var maskLin: LinearImage?
            if let m = base.personMask {
                let me = m.extent, be = baseOut.image.extent
                let scaled = m.transformed(by: CGAffineTransform(translationX: -me.minX, y: -me.minY))
                    .transformed(by: CGAffineTransform(scaleX: be.width / me.width, y: be.height / me.height))
                    .transformed(by: CGAffineTransform(translationX: be.minX, y: be.minY))
                maskLin = try? renderer.linearImage(scaled.cropped(to: be), size: size)
            }
            func row(_ name: String, _ img: CIImage, _ decisions: [String]) throws -> LookRow {
                let file = "\(stem)/\(name).jpg"
                try jpeg(img, to: outDir.appendingPathComponent(file))
                let lin = try renderer.linearImage(img, size: size)
                let m = ImageMetrics.measure(lin)
                let cmp = try ComparisonMetrics.compare(candidate: lin, reference: baseLin)
                let mono = FilmStock.named(name)?.lut().isMonochrome ?? false
                let (skin, nSkin) = name == "base" || name == "apple" || mono ? (nil, 0) : skinShift(base: baseLin, looked: lin, mask: maskLin)
                return LookRow(file: url.lastPathComponent, id: e?.id, category: e?.category, split: e?.split, look: name, image: file,
                               clippedPercent: m.clippedFraction * 100, blackP1: m.blackP1, meanY: m.meanY,
                               deltaE00VsBase: cmp.deltaE00Mean, chromaRatioVsBase: chroma(lin) / max(baseChroma, 1e-6),
                               skinHueShift: skin, skinPixels: nSkin,
                               skyL: skyStats(lin, sky)?.0, skyChroma: skyStats(lin, sky)?.1, skySpread: skyStats(lin, sky)?.2,
                               decisions: decisions)
            }
            rows.append(try row("apple", apple, []))
            rows.append(try row("base", baseOut.image, baseOut.recipe.decisions))
            for n in lookNames {
                base.settings.stock = n; base.settings.look = nil; base.settings.finish = nil
                if !sceneIntensity { base.settings.lookIntensityOffset = 0 }   // --no-scene-intensity: diagnostic only
                let o = try dev.finish(base)
                let lookDecisions = o.recipe.decisions.filter { !baseOut.recipe.decisions.contains($0) }
                rows.append(try row(n, o.image, lookDecisions))
            }
        } catch {
            log("  ERROR \(error)")
        }
    }
    let run = LooksRun(created: ISO8601DateFormatter().string(from: Date()), longEdge: longEdge, looks: lookNames, rows: rows)
    try run.prettyJSON().write(to: outDir.appendingPathComponent("looks.json"), atomically: true, encoding: .utf8)
    return run
}
#endif
