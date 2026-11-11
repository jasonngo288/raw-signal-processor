#if canImport(CoreImage)
import CoreImage
import Foundation
import ImageIO
import RawCore
import UniformTypeIdentifiers

/// `raw-bench storage`: can the DNG be deleted right after capture? Develops the base render (auto, no look),
/// stores it in candidate intermediate formats, reads it back, and measures what is lost against the in-memory base:
/// the base itself, and the final picture (stock look + halation, exported as 8-bit JPEG the way MoodRoll ships it).
/// Grain is left out on purpose: it is seeded noise and would be identical on both paths.
struct StorageRow: Codable {
    var file: String
    var format: String
    var bytes: Int
    var dngBytes: Int
    var encodeSeconds: Double
    var baseDeltaE00Mean: Double
    var baseDeltaE00P95: Double
    var finalDeltaE00Mean: Double
    var finalDeltaE00P95: Double
}

private struct Candidate {
    var name: String
    var encode: (CIImage) throws -> Data?
}

private func cgDestination(_ image: CIImage, type: String, format: CIFormat, colorSpace: CGColorSpace, props: [CFString: Any]) -> Data? {
    guard let cg = renderer.context.createCGImage(image, from: image.extent.integral, format: format, colorSpace: colorSpace) else { return nil }
    let data = NSMutableData()
    guard let dest = CGImageDestinationCreateWithData(data, type as CFString, 1, nil) else { return nil }
    CGImageDestinationAddImage(dest, cg, props as CFDictionary)
    return CGImageDestinationFinalize(dest) ? data as Data : nil
}

private let candidates: [Candidate] = [
    Candidate(name: "heic10 q0.92") { try renderer.export($0, format: .heic10, quality: 0.92) },
    Candidate(name: "heic10 q1.0") { try renderer.export($0, format: .heic10, quality: 1.0) },
    Candidate(name: "png16") { try renderer.export($0, format: .png16) },
    Candidate(name: "tiff16 lzw") {
        cgDestination($0, type: UTType.tiff.identifier, format: .RGBA16, colorSpace: Renderer.displayP3,
                      props: [kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFCompression: 5]])
    },
    Candidate(name: "exr half (linear)") {
        cgDestination($0, type: "com.ilm.openexr-image", format: .RGBAh, colorSpace: Renderer.linearP3, props: [:])
    },
    Candidate(name: "jpeg8 q0.92 (floor)") { try renderer.export($0, format: .jpeg, quality: 0.92) },
]

/// The look stage as the product would run it on a stored base: stock LUT at its intensity, then halation.
private func finalPicture(_ base: CIImage, stock: FilmStock) throws -> LinearImage {
    var finish = stock.finish
    finish.grainAmount = 0
    let looked = FilmFinisher.apply(try renderer.applyLook(stock.lut(), to: base, intensity: stock.lookIntensity), finish)
    let jpeg = try renderer.export(looked, format: .jpeg, quality: 0.92)
    guard let back = CIImage(data: jpeg) else { throw RawCoreError.renderFailed("final JPEG unreadable") }
    return try renderer.linearImage(back)
}

func storageCommand(_ paths: [String], stockName: String, out: String?) throws -> String {
    guard let stock = FilmStock.named(stockName) else { throw RawCoreError.invalidSettings("unknown stock \(stockName)") }
    var rows: [StorageRow] = []
    for p in paths {
        let url = URL(fileURLWithPath: p)
        log("storage \(url.lastPathComponent)")
        let dngBytes = (try FileManager.default.attributesOfItem(atPath: p)[.size] as? Int) ?? 0
        var st = RenderSettings(mode: .explicit)
        st.stock = nil; st.look = nil; st.finish = nil
        let base = try dev.develop(url: url, settings: st, auto: true, scaleFactor: 1).image
        let baseLin = try renderer.linearImage(base)
        let finalRef = try finalPicture(base, stock: stock)
        for c in candidates {
            let t = Date()
            guard let data = try c.encode(base) else { log("  \(c.name): cannot write on this OS, skipped"); continue }
            let secs = Date().timeIntervalSince(t)
            guard let back = CIImage(data: data) else { log("  \(c.name): written but unreadable, skipped"); continue }
            let size = (baseLin.width, baseLin.height)
            let b = try ComparisonMetrics.compare(candidate: renderer.linearImage(back, size: size), reference: baseLin)
            let f = try ComparisonMetrics.compare(candidate: finalPicture(back, stock: stock), reference: finalRef)
            rows.append(StorageRow(file: url.lastPathComponent, format: c.name, bytes: data.count, dngBytes: dngBytes, encodeSeconds: secs,
                                   baseDeltaE00Mean: b.deltaE00Mean, baseDeltaE00P95: b.deltaE00P95,
                                   finalDeltaE00Mean: f.deltaE00Mean, finalDeltaE00P95: f.deltaE00P95))
            log(String(format: "  %@: %.1f MB, final dE00 %.3f / p95 %.3f", c.name, Double(data.count) / 1e6, f.deltaE00Mean, f.deltaE00P95))
        }
    }
    var md = "# Storage: stored base render vs in-memory base (stock \(stock.name), final = look + halation → JPEG 8-bit)\n\n"
    md += "| file | format | size MB | vs DNG | encode s | base ΔE00 mean / p95 | final ΔE00 mean / p95 |\n|---|---|---|---|---|---|---|\n"
    for r in rows {
        md += String(format: "| %@ | %@ | %.1f | %.0f %% | %.2f | %.3f / %.3f | %.3f / %.3f |\n", r.file, r.format, Double(r.bytes) / 1e6,
                     100 * Double(r.bytes) / Double(max(r.dngBytes, 1)), r.encodeSeconds,
                     r.baseDeltaE00Mean, r.baseDeltaE00P95, r.finalDeltaE00Mean, r.finalDeltaE00P95)
    }
    if let out {
        try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
        try rows.prettyJSON().write(toFile: out + "/storage.json", atomically: true, encoding: .utf8)
        try md.write(toFile: out + "/storage.md", atomically: true, encoding: .utf8)
    }
    return md
}
#endif
