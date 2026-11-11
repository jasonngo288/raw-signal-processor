import Foundation
import RawCore

#if canImport(CoreImage)
import CoreImage

/// Native-resolution sharpness (docs/METRICS.md "Native-pixel sharpness"): renders at scaleFactor 1, cuts a 1024 px
/// centre crop and 4 tiles, measures each variant against the appleDefault crop of the same file.
struct NativeRow: Codable {
    var name: String
    var summary: SharpnessSummary
}

struct NativeResult: Codable {
    var cropRects: [[Int]]   // x, y, w, h in the native render
    var rows: [NativeRow]
}

/// Centre 1024² + 4 tiles of 1024² centred on the quarter points (clamped into the image).
func nativeCropRects(extent e: CGRect, size: Int = 1024) -> [CGRect] {
    let s = CGFloat(min(size, Int(min(e.width, e.height))))
    let centres = [(0.5, 0.5), (0.25, 0.25), (0.75, 0.25), (0.25, 0.75), (0.75, 0.75)]
    return centres.map { c in
        let x = min(max(e.minX + e.width * c.0 - s / 2, e.minX), e.maxX - s).rounded()
        let y = min(max(e.minY + e.height * c.1 - s / 2, e.minY), e.maxY - s).rounded()
        return CGRect(x: x, y: y, width: s, height: s)
    }
}

/// Variants measured at native size: the base renders and one film stock with and without grain (flat texture
/// before / after grain). `stockName` nil skips the stock rows.
func nativeVariants(stockName: String? = "warm400") -> [Variant] {
    var core = RenderSettings(mode: .explicit); core.plugins = []
    var v: [Variant] = [Variant(name: "explicit", settings: .explicit, auto: false),
                        Variant(name: "auto", settings: .explicit, auto: true),
                        Variant(name: "auto core", settings: core, auto: true)]
    if let stockName, let stock = FilmStock.named(stockName) {
        var noGrain = RenderSettings(mode: .explicit)
        noGrain.stock = stock.name
        var f = stock.finish; f.grainAmount = 0
        noGrain.finish = f
        v.append(Variant(name: "auto+\(stock.name) before grain", settings: noGrain, auto: true))
        var st = RenderSettings(mode: .explicit)
        st.stock = stock.name
        v.append(Variant(name: "auto+\(stock.name) after grain", settings: st, auto: true))
    }
    return v
}

func nativeSharpness(_ url: URL, variants: [Variant], analysis: Developer.Analysis) throws -> NativeResult {
    let ref = try dev.develop(url: url, settings: .appleDefault, auto: false, scaleFactor: 1, analysis: analysis)
    let rects = nativeCropRects(extent: ref.image.extent.integral)
    let refCrops = try rects.map { try renderer.linearImage(ref.image.cropped(to: $0)) }
    var rows: [NativeRow] = [NativeRow(name: "appleDefault", summary: SharpnessSummary(refCrops.map { SharpnessComparison.measureSelf($0) }))]
    for v in variants {
        let t = Date()
        let o = try dev.develop(url: url, settings: v.settings, auto: v.auto, scaleFactor: 1, analysis: analysis)
        var cmps: [SharpnessComparison] = []
        for (r, rc) in zip(rects, refCrops) {
            let c = try renderer.linearImage(o.image.cropped(to: r))
            cmps.append(try SharpnessComparison.compare(candidate: c, reference: rc))
        }
        rows.append(NativeRow(name: v.name, summary: SharpnessSummary(cmps)))
        log(String(format: "  native %@: %.1fs", v.name, Date().timeIntervalSince(t)))
    }
    return NativeResult(cropRects: rects.map { [Int($0.minX), Int($0.minY), Int($0.width), Int($0.height)] }, rows: rows)
}

func nativeMarkdown(_ n: NativeResult) -> String {
    func p(_ v: Double?, _ f: String = "%.1f") -> String { v.map { String(format: f, $0) } ?? "–" }
    var md = "native-resolution sharpness (scaleFactor 1, \(n.cropRects.count) crops of \(n.cropRects.first?[2] ?? 0)², mean over crops; reference = appleDefault crop):\n\n"
    md += "| variant | edge overshoot % | overshoot vs Apple % | HF energy (fine/coarse) | HF ratio | flat texture | flat ratio |\n|---|---|---|---|---|---|---|\n"
    for r in n.rows {
        let s = r.summary
        md += "| \(r.name) | \(p(s.overshootPercent)) | \(r.name == "appleDefault" ? "–" : p(s.overshootChangePercent, "%+.0f")) | \(p(s.hfEnergy, "%.3f")) | \(r.name == "appleDefault" ? "1.00" : p(s.hfRatio, "%.2f")) | \(p(s.flatTexture, "%.4f")) | \(r.name == "appleDefault" ? "1.00" : p(s.flatTextureRatio, "%.2f")) |\n"
    }
    return md + "\n"
}

extension SharpnessComparison {
    /// The reference measured against itself (its own sites and flat mask): the appleDefault row.
    static func measureSelf(_ image: LinearImage) -> SharpnessComparison {
        let m = SharpnessMetrics.measure(image)
        return SharpnessComparison(candidate: m, reference: m)
    }
}
#endif
