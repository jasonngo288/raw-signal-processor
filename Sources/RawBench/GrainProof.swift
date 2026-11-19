#if canImport(CoreImage)
import CoreImage
import Foundation
import RawCore

/// `raw-bench grain-proof --out DIR`: offline proof of the order-B grain (film-lab GRAIN_PROFILE 2026-11-19).
/// Flat wedges through the real renderer (linear P3 working space, half-float intermediates); numbers are 8-bit codes of the
/// encoded Display P3 value. Writes `grain_proof.md` and `grain_proof.json` into DIR.
private func flat(_ w: Int, _ h: Int, encoded v: Double) -> CIImage {
    let lin = CGFloat(ColorMath.decodeTransfer(v))
    return CIImage(color: CIColor(red: lin, green: lin, blue: lin, colorSpace: Renderer.linearP3)!).cropped(to: CGRect(x: 0, y: 0, width: w, height: h))
}

struct GrainStats { var meanCode: Double; var lumaRMS: Double; var chromaRMS: Double; var channelSumRMS: Double }

/// Encoded-code statistics of a rendered flat patch against the encoded level `v` it started from.
private func stats(_ img: LinearImage, level v: Double) -> GrainStats {
    let w = ColorMath.p3LuminanceWeights
    var lumas = [Double](); lumas.reserveCapacity(img.pixelCount)
    var chroma2 = 0.0, sum2 = 0.0
    for i in 0..<img.pixelCount {
        let r = ColorMath.encodeTransfer(Double(img.pixels[i * 3])) * 255
        let g = ColorMath.encodeTransfer(Double(img.pixels[i * 3 + 1])) * 255
        let b = ColorMath.encodeTransfer(Double(img.pixels[i * 3 + 2])) * 255
        lumas.append(Double(w.r) * r + Double(w.g) * g + Double(w.b) * b)
        let m = (r + g + b) / 3
        chroma2 += ((r - m) * (r - m) + (g - m) * (g - m) + (b - m) * (b - m)) / 3
        sum2 += m * m
    }
    let mean = lumas.reduce(0, +) / Double(lumas.count)
    let varL = lumas.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(lumas.count)
    _ = v
    return GrainStats(meanCode: mean, lumaRMS: varL.squareRoot(), chromaRMS: (chroma2 / Double(img.pixelCount)).squareRoot(),
                      channelSumRMS: 0)
}

func grainProofCommand(out: String) throws -> String {
    let dir = URL(fileURLWithPath: out)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    // (stock, cellPx, sigma50, chroma) from the approved table.
    let table: [(String, Double, Double, Double)] = [
        ("rr-nang-100", 2.00, 0.70, 0.20), ("rr-la-phong-100", 2.00, 0.80, 0.20), ("rr-da-mem-160", 2.25, 0.85, 0.20),
        ("rr-mat-200", 2.50, 1.00, 0.20), ("rr-vang-200", 2.50, 1.05, 0.20), ("rr-sao-mai-200", 2.75, 1.10, 0.20),
        ("rr-am-200", 2.75, 1.10, 0.20), ("rr-hoai-co-200", 2.75, 1.15, 0.20), ("rr-graduate-400", 2.50, 1.00, 0.25),
        ("rr-bling-400", 2.75, 1.10, 0.25), ("rr-gio-400", 3.50, 1.45, 0.25), ("rr-sao-hom-400", 3.75, 1.50, 0.25),
        ("rr-lang-kinh-400", 3.75, 1.55, 0.25), ("rr-den-vang-800t", 4.50, 2.00, 0.30),
    ]
    let r = Renderer()
    var md = "# Grain order B: RSP offline proof\n\nFlat wedge 1536x1536, encoded L = 0.5, real RSP renderer (half-float working format). Numbers are 8-bit codes.\n\n"
    md += "| stock | cellPx | sigma50 | luma RMS | ratio | chroma RMS / luma RMS (target) | mean shift (code) |\n|---|---|---|---|---|---|---|\n"
    var worst = 0.0
    var rows: [[String: Double]] = []
    for (name, cell, sigma, chroma) in table {
        let prof = GrainProfile(cellPx: cell, sigma50: sigma, chroma: chroma)
        let img = try r.linearImage(FilmFinisher.applyGrain(flat(1536, 1536, encoded: 0.5), profile: prof, seed: 7))
        let s = stats(img, level: 0.5)
        let ratio = s.lumaRMS / sigma
        worst = max(worst, abs(ratio - 1))
        md += String(format: "| %@ | %.2f | %.2f | %.3f | %.3f | %.3f (%.2f) | %+.3f |\n", name, cell, sigma, s.lumaRMS, ratio,
                     s.chromaRMS / s.lumaRMS, chroma, s.meanCode - 127.5)
        rows.append(["cellPx": cell, "sigma50": sigma, "lumaRMS": s.lumaRMS, "ratio": ratio, "chromaOverLuma": s.chromaRMS / s.lumaRMS])
    }
    md += String(format: "\nWorst |ratio - 1| at L = 0.5: %.1f %% (limit 5 %%).\n", worst * 100)
    // Chroma off: luma RMS unchanged? (chroma adds only zero-sum noise)
    // Density curve: RMS at several L vs sigma50 * s(L).
    md += "\n## Density curve (cell 2.75 px, sigma50 1.10, chroma 0)\n\n| L | measured RMS | expected sigma50*s(L) | ratio |\n|---|---|---|---|\n"
    let cp = GrainProfile(cellPx: 2.75, sigma50: 1.10)
    for l in [0.05, 0.15, 0.30, 0.50, 0.70, 0.85, 0.95] {
        let img = try r.linearImage(FilmFinisher.applyGrain(flat(1024, 1024, encoded: l), profile: cp, seed: 7))
        let s = stats(img, level: l)
        let exp = 1.10 * cp.weight(at: l)
        md += String(format: "| %.2f | %.3f | %.3f | %.2f |\n", l, s.lumaRMS, exp, exp > 0 ? s.lumaRMS / exp : 0)
    }
    // Resolution independence: same cell px, different frame size -> same RMS and same lattice.
    let a = try r.linearImage(FilmFinisher.applyGrain(flat(1024, 1024, encoded: 0.5), profile: cp, seed: 7))
    let b = try r.linearImage(FilmFinisher.applyGrain(flat(2048, 2048, encoded: 0.5), profile: cp, seed: 7))
    let c = try r.linearImage(FilmFinisher.applyGrain(flat(1024, 1024, encoded: 0.5), profile: cp, seed: 7))
    md += String(format: "\n## Size independence and determinism\n\nRMS at 1024^2: %.3f, at 2048^2: %.3f (cell fixed in output px). Same seed twice identical: %@.\n",
                 stats(a, level: 0.5).lumaRMS, stats(b, level: 0.5).lumaRMS, a.pixels == c.pixels ? "yes" : "NO")
    // Chroma diagnostic: chroma 1 => per-channel RMS = sigma x sqrt(2), channel-pair correlation (1 - 1/2) / 2 = 0.25.
    let cd = GrainProfile(cellPx: 2.75, sigma50: 4, chroma: 1)
    let ci = try r.linearImage(FilmFinisher.applyGrain(flat(1024, 1024, encoded: 0.5), profile: cd, seed: 7))
    func chan(_ k: Int) -> [Double] { (0..<ci.pixelCount).map { ColorMath.encodeTransfer(Double(ci.pixels[$0 * 3 + k])) * 255 } }
    let ch = [chan(0), chan(1), chan(2)]
    func sd(_ a: [Double]) -> Double { let m = a.reduce(0, +) / Double(a.count); return (a.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Double(a.count)).squareRoot() }
    func corr(_ a: [Double], _ b: [Double]) -> Double {
        let ma = a.reduce(0, +) / Double(a.count), mb = b.reduce(0, +) / Double(b.count)
        var s = 0.0; for i in 0..<a.count { s += (a[i] - ma) * (b[i] - mb) }
        return s / Double(a.count) / (sd(a) * sd(b))
    }
    md += String(format: "\n## Chroma diagnostic (chroma 1, sigma50 4)\n\nper-channel RMS %.3f %.3f %.3f (expect %.3f at ratio 1); correlation RG %.3f RB %.3f GB %.3f (expect 0.25: shared luma part sigma^2 over total 2 sigma^2 minus the zero-sum -1/2).\n",
                 sd(ch[0]), sd(ch[1]), sd(ch[2]), 4 * 2.0.squareRoot(), corr(ch[0], ch[1]), corr(ch[0], ch[2]), corr(ch[1], ch[2]))
    // Headroom: a patch at linear 1.2 must keep its mean through encode / grain / decode.
    let hdr = CIImage(color: CIColor(red: 1.2, green: 1.2, blue: 1.2, colorSpace: Renderer.linearP3)!).cropped(to: CGRect(x: 0, y: 0, width: 300, height: 300))
    let hp = try r.linearImage(FilmFinisher.applyGrain(hdr, profile: cp, seed: 4)).pixels
    md += String(format: "\n## Headroom\n\nLinear 1.2 patch: mean after grain %.4f (must stay ~1.2).\n", Double(hp.reduce(0, +)) / Double(hp.count))
    try md.write(to: dir.appendingPathComponent("grain_proof.md"), atomically: true, encoding: .utf8)
    try JSONSerialization.data(withJSONObject: rows, options: .prettyPrinted).write(to: dir.appendingPathComponent("grain_proof.json"))
    return md
}
#endif
