import Foundation
import RawCore
#if canImport(CoreImage)
import CoreImage

/// `raw-bench border`: develop (RAW) or load (already developed image), then render each requested border template.
/// Writes `<stem>__<template>.jpg` plus a `.border.json` record (and the full recipe for RAWs).
func borderCommand(_ files: [String], _ a: Args) throws {
    guard !files.isEmpty else { print(usage); return }
    let outDir = URL(fileURLWithPath: a.options["out"] ?? "bench-out/border")
    try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
    let ids = (a.options["template"] ?? "classic_scan") == "all" ? FilmBorderTemplates.all.map(\.id)
        : (a.options["template"] ?? "classic_scan").split(separator: ",").map(String.init)
    let longEdge = a.options["long-edge"].flatMap(Int.init)
    for (index, path) in files.enumerated() {
        let url = URL(fileURLWithPath: path)
        let stem = url.deletingPathExtension().lastPathComponent
        let isRaw = rawExtensions.contains(url.pathExtension.lowercased())
        var recipe: DecodeRecipe? = nil
        let developed: CIImage
        if isRaw {
            var s = RenderSettings(mode: .explicit)
            s.stock = a.options["stock"]
            let scale = try decoder.scaleFactor(url: url, longEdge: longEdge ?? 2400)
            let o = try dev.develop(url: url, settings: s, auto: true, scaleFactor: scale)
            developed = o.image; recipe = o.recipe
        } else {
            guard let img = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) else {
                log("cannot read \(path)"); continue
            }
            developed = img
        }
        for id in ids {
            guard var cfg = FilmBorderTemplates.named(id) else { log("unknown template \(id)"); continue }
            cfg = cfg.seeded(stem)
            if let v = a.options["seed"].flatMap(UInt64.init) { cfg.render.randomSeed = v }
            if let v = a.options["size"].flatMap(Float.init) { cfg.layout.sizeMultiplier = v }
            if let v = a.options["paper"].flatMap(BorderColor.init(hex:)) { cfg.paper.color = v }
            if let v = a.options["texture"].flatMap(Float.init) { cfg.paper.textureStrength = v }
            if let v = a.options["frame-number"].flatMap(Int.init) { cfg.filmEdge.frameNumber = v }
            // Roll context: --roll ID (shared seed), --frames N (roll length); frames are numbered in argument order.
            if let roll = a.options["roll"] { cfg.render.rollSeed = cfg.seeded(roll).render.randomSeed }
            if let n = a.options["frames"].flatMap(Int.init) { cfg.render.rollLength = n; cfg.render.frameIndex = index + 1 }
            let t = Date()
            // --share 4x5|1x1|9x16[,..] [--share-bg light|dark|white|#hex] [--share-width N]: Instagram canvases.
            let shares = (a.options["share"] ?? "").split(separator: ",").compactMap { ShareCanvas.Aspect(rawValue: String($0)) }
            let bg: BorderColor = {
                switch a.options["share-bg"] ?? "light" {
                case "dark": return ShareCanvas.dark
                case "white": return ShareCanvas.white
                case "light": return ShareCanvas.light
                case let h: return BorderColor(hex: h) ?? ShareCanvas.light
                }
            }()
            for asp in shares {
                var sc = ShareCanvas.instagram(asp, background: bg)
                if let w = a.options["share-width"].flatMap(Int.init) { sc.outputWidth = w }
                let r = try FilmBorderRenderer.renderForShare(developed, configuration: cfg, canvas: sc,
                                                              outputLongEdge: isRaw ? nil : longEdge)
                let name = "\(stem)__\(id)__\(asp.rawValue)"
                var rr = recipe   // AGENTS rule 1: the shared file carries its recipe too
                rr?.border = r.record
                rr?.decisions += r.record.notes.map { "[border] " + $0 }
                try renderer.export(r.image, format: .jpeg, quality: 0.92, recipe: rr).write(to: outDir.appendingPathComponent(name + ".jpg"))
                if let rr { try rr.prettyJSON().write(to: outDir.appendingPathComponent(name + ".recipe.json"), atomically: true, encoding: .utf8) }
                let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
                try enc.encode(r.record).write(to: outDir.appendingPathComponent(name + ".border.json"))
                log("\(name): \(r.record.shareCanvasSize ?? [])")
            }
            let r = try FilmBorderRenderer.render(developed, configuration: cfg,
                                                  outputLongEdge: isRaw ? nil : longEdge)
            let name = "\(stem)__\(id)"
            var rec = recipe
            rec?.border = r.record
            rec?.decisions += r.record.notes.map { "[border] " + $0 }
            let data = try renderer.export(r.image, format: .jpeg, quality: 0.92, recipe: rec)
            try data.write(to: outDir.appendingPathComponent(name + ".jpg"))
            let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try enc.encode(r.record).write(to: outDir.appendingPathComponent(name + ".border.json"))
            if let rec { try rec.prettyJSON().write(to: outDir.appendingPathComponent(name + ".recipe.json"), atomically: true, encoding: .utf8) }
            log(String(format: "%@: %dx%d in %.2fs", name, r.record.canvasSize[0], r.record.canvasSize[1], Date().timeIntervalSince(t)))
        }
    }
}
#endif
