#if canImport(CoreImage) && canImport(CoreText)
import CoreImage
import CoreText
import Foundation

/// Output of a border render: the composite (opaque, canvas at the origin) and what was done (for the recipe).
public struct FilmBorderResult {
    public var image: CIImage
    public var record: FilmBorderRecord
}

/// Film Border Renderer (FilmBorder.swift has the model). Core Image compositing plus Core Graphics / Core Text masks.
///
/// Order, back to front: backdrop → paper (base colour × fibre texture × mottle, aging, speckles) inside the paper
/// outline → film base, sprocket holes and edge print (film edge) → photo inside the irregular opening → gate shadow
/// and wear along the opening → edge burn → scan dust.
///
/// Works in the context's working space (extended linear Display P3). The photo is only placed (scaled when a preview
/// size or aspect-fill asks for it) and masked; no colour transform touches it apart from the edge effects the
/// configuration asks for (gate shadow, wear, burn, dust).
///
/// Noise is CIRandomGenerator sampled on a fixed reference grid tied to the canvas short edge (`referenceShortEdge`)
/// and then scaled to the canvas, so fibres, mottle and speckles keep their size relative to the print at every
/// output resolution. Each field is rotated and offset by the seed.
public enum FilmBorderRenderer {
    public static let referenceShortEdge: CGFloat = 1600

    public static func render(_ developed: CIImage, configuration: FilmBorderConfiguration,
                              outputLongEdge: Int? = nil) throws -> FilmBorderResult {
        try configuration.validate()
        let cfg = configuration.clamped()
        let src = developed.transformed(by: CGAffineTransform(translationX: -developed.extent.minX, y: -developed.extent.minY))
        let pw = Int(src.extent.width.rounded()), ph = Int(src.extent.height.rounded())
        let L = try FilmBorderLayout.compute(cfg, photoWidth: pw, photoHeight: ph, outputLongEdge: outputLongEdge)
        let W = L.canvasWidth, H = L.canvasHeight
        let canvas = CGRect(x: 0, y: 0, width: W, height: H)
        let short = CGFloat(L.shortEdge)
        let seed = cfg.render.randomSeed
        var notes: [String] = []
        let f = Fields(seed: seed, canvas: canvas)

        // 1. Backdrop and paper.
        let paperColor = cfg.filmEdge.enabled ? cfg.filmEdge.baseColor : cfg.paper.color
        var paper = constant(paperColor, canvas)
        let fine = f.field(stream: 10, cells: referenceShortEdge, sigma: 1.3)
        let mottle = f.field(stream: 11, cells: 90, sigma: 1.4)
        // Luminance modulation 1 + 0.53·t·fine + 0.42·m·mottle (unit-variance fields), with a hint of chroma (mottle slightly warmer).
        let texture = add(scale(fine, rgb: (0.53, 0.53, 0.54), bias: 0), scale(mottle, rgb: (0.42, 0.42, 0.40), bias: 0),
                          weights: (CGFloat(cfg.paper.textureStrength), CGFloat(cfg.paper.mottleStrength)))
        paper = multiply(paper, by: texture.offset(by: 1))
        if cfg.paper.agingStrength > 0 {
            // Warm toward the paper edge (inner falloff of the paper rectangle) plus soft stains.
            let a = CGFloat(cfg.paper.agingStrength)
            let inner = rasterize(W, H) { ctx in
                ctx.fill(CGRect(x: L.paper.x, y: L.paper.y, width: L.paper.width, height: L.paper.height))
            }.clampedToExtent().applyingGaussianBlur(sigma: Double(short) * 0.05).cropped(to: canvas)
            let toward = constant(BorderColor(r: 0.80, g: 0.66, b: 0.44), canvas)
            let edgeWeight = ramp(inner, from: 1, to: 0.35, strength: a * 0.9)   // 0 in the middle, up to a·0.9 at the edge
            paper = CIFilter(name: "CIBlendWithMask", parameters: [kCIInputImageKey: multiply(paper, by: toward),
                                                                   kCIInputBackgroundImageKey: paper, kCIInputMaskImageKey: edgeWeight])!.outputImage!
            let stainField = f.field(stream: 12, cells: 28, sigma: 1.1)
            let stain = ramp(stainField, from: 0.53, to: 0.91, strength: a * 0.7)
            paper = CIFilter(name: "CIBlendWithMask", parameters: [kCIInputImageKey: multiply(paper, by: constant(BorderColor(r: 0.72, g: 0.56, b: 0.36), canvas)),
                                                                   kCIInputBackgroundImageKey: paper, kCIInputMaskImageKey: stain])!.outputImage!
            notes.append(String(format: "aging %.2f: warm paper edge + stains", a))
        }
        if cfg.paper.speckles > 0 {
            // Sparse dark fibre specks on the paper (count scales with the paper area, size with the short edge).
            let n = Int(Double(cfg.paper.speckles) * 500 * (L.paper.width * L.paper.height) / (L.shortEdge * L.shortEdge))
            let dots = rasterize(W, H) { ctx in drawSpecks(ctx, count: n, seed: seed, stream: 20, short: L.shortEdge,
                                                            size: (0.0004, 0.0016), hairs: 0.15, alpha: (0.25, 0.8)) }
            paper = blend(multiply(paper, by: constant(BorderColor(r: 0.42, g: 0.36, b: 0.28), canvas)), over: paper, mask: dots)
        }
        if cfg.paper.fibres > 0 {
            // Paper fibres: short faint curved strokes, dark and light (≈ 400 per short-edge² at fibres 1).
            let n = Int(Double(cfg.paper.fibres) * 400 * (L.paper.width * L.paper.height) / (L.shortEdge * L.shortEdge))
            let darkF = rasterize(W, H) { ctx in drawSpecks(ctx, count: n, seed: seed, stream: 23, short: L.shortEdge,
                                                             size: (0.0006, 0.0012), hairs: 1, alpha: (0.04, 0.10)) }
            let lightF = rasterize(W, H) { ctx in drawSpecks(ctx, count: n, seed: seed, stream: 24, short: L.shortEdge,
                                                              size: (0.0006, 0.0012), hairs: 1, alpha: (0.05, 0.12)) }
            paper = blend(multiply(paper, by: constant(BorderColor(r: 0.55, g: 0.50, b: 0.42), canvas)), over: paper, mask: darkF)
            paper = blend(constant(BorderColor(r: 1, g: 1, b: 0.98), canvas), over: paper, mask: lightF)
        }
        let paperMask = rasterize(W, H) { ctx in fill(ctx, L.paperOutline(cfg)) }
        var backdrop = constant(cfg.layout.backdrop, canvas)
        if cfg.layout.paperInset > 0 {
            // Contact shadow under the card (blur 0.6 %, offset down 0.2 % of the short edge, 15 %), so a print on a
            // light backdrop reads as an object.
            let sh = paperMask.clampedToExtent().applyingGaussianBlur(sigma: Double(short) * 0.006)
                .transformed(by: CGAffineTransform(translationX: 0, y: -short * 0.002)).cropped(to: canvas)
            backdrop = multiply(backdrop, by: sh.applyingFilter("CIColorMatrix", parameters: colorMatrix(gain: -0.15, bias: 1)))
        }
        var out = blend(paper, over: backdrop, mask: paperMask)

        // 2. Film edge: holes show the backdrop; edge print in the rebate.
        if cfg.filmEdge.enabled {
            let (holes, radius) = L.sprocketHoles(cfg)
            if !holes.isEmpty {
                let holeMask = rasterize(W, H) { ctx in
                    for h in holes {
                        ctx.addPath(CGPath(roundedRect: CGRect(x: h.x, y: h.y, width: h.width, height: h.height),
                                           cornerWidth: radius, cornerHeight: radius, transform: nil))
                    }
                    ctx.fillPath()
                }
                out = blend(constant(cfg.layout.backdrop, canvas), over: out, mask: holeMask)
                notes.append("film edge: \(holes.count) sprocket holes")
            }
            if cfg.filmEdge.markings > 0 {
                let n = FilmBorderLayout.frameNumber(cfg)
                let ink = rasterize(W, H) { ctx in drawMarkings(ctx, L, cfg, frame: n) }
                    .applyingGaussianBlur(sigma: Double(short) / 35 * 0.1).cropped(to: canvas)   // ~0.1 mm ink bleed
                let m = ink.applyingFilter("CIColorMatrix", parameters: colorMatrix(gain: CGFloat(cfg.filmEdge.markings), bias: 0))
                out = blend(constant(cfg.filmEdge.markingColor, canvas), over: out, mask: m)
                notes.append("film edge print: frame \(n), \(n)A")
            }
        }

        // 3. Photo inside the irregular opening. The photo is clamped at its edges so the opening's outward wiggle
        //    never shows a gap.
        let ocx = L.opening.x + L.opening.width / 2, ocy = L.opening.y + L.opening.height / 2
        let placed = src.clampedToExtent()
            .transformed(by: CGAffineTransform(scaleX: L.photoScale, y: L.photoScale)
                .concatenating(CGAffineTransform(translationX: L.photo.x - ocx, y: L.photo.y - ocy))
                .concatenating(CGAffineTransform(rotationAngle: L.rotation))
                .concatenating(CGAffineTransform(translationX: ocx, y: ocy)))
            .cropped(to: canvas)
        if L.rotation != 0 { notes.append(String(format: "scan tilt %.2f°", L.rotation * 180 / .pi)) }
        let openingPts = L.openingOutline(cfg)
        var openingMask = rasterize(W, H) { ctx in fill(ctx, openingPts) }
        if cfg.edge.softness > 0 {
            openingMask = openingMask.clampedToExtent()
                .applyingGaussianBlur(sigma: max(0.3, Double(cfg.edge.softness) * 0.0012 * Double(short))).cropped(to: canvas)
        }
        out = blend(placed, over: out, mask: openingMask)

        // 4. Gate shadow: a thin, patchy dark line straddling the opening edge (ring = 4·b·(1−b) of the slightly
        //    blurred opening, broken up by noise), plus an optional warm fringe on parts of the edge.
        if cfg.edge.darkening > 0 || cfg.edge.wear > 0 || cfg.edge.fringe > 0 || cfg.edge.lift > 0 {
            let b = openingMask.clampedToExtent().applyingGaussianBlur(sigma: Double(short) * 0.0011).cropped(to: canvas)
            let ring = multiply(b, by: b.applyingFilter("CIColorMatrix", parameters: colorMatrix(gain: -1, bias: 1)))
                .applyingFilter("CIColorMatrix", parameters: colorMatrix(gain: 4, bias: 0))
            let patches = ramp(f.field(stream: 17, cells: 220, sigma: 1.2), from: -0.6, to: 0.8, strength: 1)   // 0…1, patchy
            if cfg.edge.darkening > 0 {
                let k = CGFloat(cfg.edge.darkening) * 0.75
                let dark = multiply(ring, by: patches)
                out = multiply(out, by: dark.applyingFilter("CIColorMatrix", parameters: colorMatrix(gain: -k, bias: 1)))
            }
            if cfg.edge.lift > 0 {
                // Light band just inside the edge: inner half of the ring, screened toward the paper colour.
                let inner = multiply(ring, by: openingMask)
                    .applyingFilter("CIColorMatrix", parameters: colorMatrix(gain: CGFloat(cfg.edge.lift), bias: 0))
                let lifted = CIFilter(name: "CIScreenBlendMode", parameters: [kCIInputImageKey: constant(cfg.paper.color, canvas),
                                                                             kCIInputBackgroundImageKey: out])!.outputImage!
                out = blend(lifted, over: out, mask: inner)
            }
            if cfg.edge.fringe > 0 {
                // Warm line on some stretches of the edge only (another noise stream, sparser).
                let where_ = ramp(f.field(stream: 18, cells: 40, sigma: 1.2), from: 0.3, to: 1.2, strength: 1)
                let m = multiply(multiply(ring, by: where_), by: patches)
                    .applyingFilter("CIColorMatrix", parameters: colorMatrix(gain: CGFloat(cfg.edge.fringe), bias: 0))
                out = blend(constant(BorderColor(r: 0.93, g: 0.74, b: 0.36), canvas), over: out, mask: m)
            }
            if cfg.edge.wear > 0 {
                let wide = openingMask.clampedToExtent().applyingGaussianBlur(sigma: Double(short) * 0.006).cropped(to: canvas)
                let band = multiply(wide, by: wide.applyingFilter("CIColorMatrix", parameters: colorMatrix(gain: -1, bias: 1)))
                    .applyingFilter("CIColorMatrix", parameters: colorMatrix(gain: 4, bias: 0))
                let nicks = multiply(ramp(f.field(stream: 14, cells: referenceShortEdge, sigma: 1.2), from: 0.68, to: 0.98, strength: 1), by: band)
                    .applyingFilter("CIColorMatrix", parameters: colorMatrix(gain: CGFloat(cfg.edge.wear), bias: 0))
                // Wear = emulsion flaking off: the paper shows through (light), never grey dirt.
                out = blend(constant(cfg.paper.color, canvas), over: out, mask: nicks)
            }
        }

        // 4b. Film-gate line on one side (same side for the whole roll): thin, jagged, broken dark line.
        let gate = L.gateLine(cfg)
        if !gate.pieces.isEmpty {
            let line = rasterize(W, H) { ctx in
                ctx.setStrokeColor(gray: 1, alpha: 1); ctx.setLineWidth(gate.width); ctx.setLineCap(.round); ctx.setLineJoin(.round)
                for piece in gate.pieces {
                    ctx.beginPath(); ctx.move(to: CGPoint(x: piece[0].x, y: piece[0].y))
                    for p in piece.dropFirst() { ctx.addLine(to: CGPoint(x: p.x, y: p.y)) }
                    ctx.strokePath()
                }
            }.applyingGaussianBlur(sigma: max(0.3, Double(short) * 0.0003)).cropped(to: canvas)
            let k = CGFloat(cfg.edge.gateLine) * 0.65
            out = multiply(out, by: line.applyingFilter("CIColorMatrix", parameters: colorMatrix(gain: -k, bias: 1)))
            notes.append(String(format: "gate line %.2f on one side (%d pieces)", cfg.edge.gateLine, gate.pieces.count))
        }

        // 5. Edge burn (light reaching the frame end): a thin band hugging the edge, dark → orange → amber into the
        //    image, ragged; strength follows the roll position (FilmBorderLayout.burnAmount).
        let sides = L.burnSides(cfg)
        if !sides.isEmpty {
            let a = CGFloat(FilmBorderLayout.burnAmount(cfg))
            let o = L.opening
            let ragged = f.field(stream: 15, cells: 220, sigma: 1.3)
            let swell = f.field(stream: 19, cells: 10, sigma: 1.2)
            for s in sides {
                let depth = (s == 0 || s == 2 ? o.height : o.width) * 0.03
                let (p0, p1): (CGPoint, CGPoint) = {
                    switch s {
                    case 0: return (CGPoint(x: 0, y: o.y), CGPoint(x: 0, y: o.y + depth))
                    case 1: return (CGPoint(x: o.maxX, y: 0), CGPoint(x: o.maxX - depth, y: 0))
                    case 2: return (CGPoint(x: 0, y: o.maxY), CGPoint(x: 0, y: o.maxY - depth))
                    default: return (CGPoint(x: o.x, y: 0), CGPoint(x: o.x + depth, y: 0))
                    }
                }()
                let grad = CIFilter(name: "CILinearGradient", parameters: [
                    "inputPoint0": CIVector(cgPoint: p0), "inputPoint1": CIVector(cgPoint: p1),
                    "inputColor0": CIColor(red: 1, green: 1, blue: 1), "inputColor1": CIColor(red: 0, green: 0, blue: 0),
                ])!.outputImage!.cropped(to: canvas)
                // Raggedness: modulate the gradient by noise, then keep it inside the opening.
                // Smooth gradient; the noise only nudges it a little, so the bands stay smooth and only the very edge
                // gets ragged.
                // Depth also varies slowly along the edge (low-frequency field), so the band is organic, not a stripe.
                let rag = add(add(grad, ragged, weights: (1, 0.06)), swell, weights: (1, 0.28))
                // Three bands from the edge inward: amber glow (widest), orange, dark brown at the very edge.
                let inner = multiply(ramp(rag, from: 0.0, to: 0.55, strength: a), by: openingMask)
                let mid = multiply(ramp(rag, from: 0.45, to: 0.85, strength: a), by: openingMask)
                let edge = multiply(ramp(rag, from: 0.8, to: 1.0, strength: a), by: openingMask)
                // Warm first (blue dies, so a blue sky turns amber, not pink), then lift with amber light.
                let tinted = multiply(out, by: constant(BorderColor(r: 1.0, g: 0.75, b: 0.45), canvas))
                let amber = CIFilter(name: "CIScreenBlendMode", parameters: [kCIInputImageKey: constant(BorderColor(r: 0.91, g: 0.63, b: 0.31), canvas),
                                                                            kCIInputBackgroundImageKey: tinted])!.outputImage!
                out = blend(amber, over: out, mask: inner)
                out = blend(constant(BorderColor(r: 0.71, g: 0.31, b: 0.06), canvas), over: out, mask: mid)
                out = blend(constant(BorderColor(r: 0.16, g: 0.05, b: 0.01), canvas), over: out, mask: edge)
            }
            notes.append("edge burn \(String(format: "%.2f", a)) on sides \(sides.map { ["bottom", "right", "top", "left"][$0] }.joined(separator: ", "))")
        }

        // 6. Scan dust over the whole print: rare light and dark specks.
        if cfg.edge.dust > 0 {
            // Scanner dust: a few dozen specks and short hairs (dust 1 ≈ 120 on a 3:2 print), light and dark.
            let area = Double(W * H) / (L.shortEdge * L.shortEdge)
            let n = Int(Double(cfg.edge.dust) * 80 * area)
            let light = rasterize(W, H) { ctx in drawSpecks(ctx, count: n, seed: seed, stream: 21, short: L.shortEdge,
                                                             size: (0.0003, 0.0011), hairs: 0.25, alpha: (0.3, 0.9)) }
            let dark = rasterize(W, H) { ctx in drawSpecks(ctx, count: n / 2, seed: seed, stream: 22, short: L.shortEdge,
                                                            size: (0.0003, 0.0009), hairs: 0.2, alpha: (0.3, 0.8)) }
            // Dust sits on the photo (on plain paper it reads as dirt), except on a film strip where the base is film too.
            let keep = cfg.filmEdge.enabled ? nil : openingMask
            out = blend(constant(BorderColor(r: 0.96, g: 0.96, b: 0.95), canvas), over: out, mask: keep.map { multiply(light, by: $0) } ?? light)
            out = blend(constant(BorderColor(r: 0.08, g: 0.08, b: 0.08), canvas), over: out, mask: keep.map { multiply(dark, by: $0) } ?? dark)
            notes.append("scan dust: \(n) light + \(n / 2) dark specks")
        }

        if L.cropFraction > 0.0005 { notes.append(String(format: "aspect-fill crops %.1f %% of the photo", L.cropFraction * 100)) }
        notes.insert(String(format: "film border %@ v%d, seed %llu, canvas %dx%d, photo scale %.3f", cfg.id, cfg.version, seed, W, H, L.photoScale), at: 0)
        let record = FilmBorderRecord(configuration: cfg, canvasSize: [W, H], opening: L.opening, photo: L.photo,
                                      cropFraction: L.cropFraction, rotationDegrees: L.rotation * 180 / .pi, share: nil,
                                      shareCanvasSize: nil, notes: notes)
        return FilmBorderResult(image: out.cropped(to: canvas), record: record)
    }

    // MARK: noise fields

    /// Zero-mean, unit-variance noise fields over the canvas, seeded and resolution-independent.
    struct Fields {
        let seed: UInt64, canvas: CGRect
        /// `cells` = noise cells across the canvas short edge (the reference grid), `sigma` = blur in cells.
        func field(stream: UInt64, cells: CGFloat, sigma: CGFloat) -> CIImage {
            var r = BorderRandom(seed: seed, stream: stream)
            let aspect = canvas.width / canvas.height
            let gw = (aspect >= 1 ? cells * aspect : cells).rounded(.up), gh = (aspect >= 1 ? cells : cells / aspect).rounded(.up)
            let grid = CGRect(x: 0, y: 0, width: gw, height: gh)
            let angle = CGFloat(r.unit()) * 2 * .pi
            let random = CIFilter(name: "CIRandomGenerator")!.outputImage!
                .transformed(by: CGAffineTransform(rotationAngle: angle)
                    .concatenating(CGAffineTransform(translationX: CGFloat(r.unit()) * 4096, y: CGFloat(r.unit()) * 4096)))
            // R − G of two independent uniform channels → zero mean whatever the generator's encoding; blur; normalise
            // (std of one uniform channel ≈ 0.2887, × √2 for the difference, shrunk by the Gaussian blur).
            // sigma ≥ 1.1 cells: below that Core Image's small blur is not Gaussian enough for the normalisation.
            let grey = random.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 1, y: -1, z: 0, w: 0), "inputGVector": CIVector(x: 1, y: -1, z: 0, w: 0),
                "inputBVector": CIVector(x: 1, y: -1, z: 0, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 1),   // opaque: the generator's alpha is random too
            ])
            let sg = max(sigma, 1.1)
            let blurred = grey.applyingGaussianBlur(sigma: Double(sg))
            let std = 2.65 * 0.2887 * sqrt(2) / (2 * sqrt(Double.pi) * Double(sg))   // 2.65: measured (FilmBorderTests), the generator is not unit-uniform after Core Image's sampling
            let unit = blurred.applyingFilter("CIColorMatrix", parameters: FilmBorderRenderer.colorMatrix(gain: CGFloat(1 / std), bias: 0))
                .cropped(to: grid)
            return unit.clampedToExtent()
                .transformed(by: CGAffineTransform(scaleX: canvas.width / gw, y: canvas.height / gh))
                .cropped(to: canvas)
        }
    }

    // MARK: compositing helpers

    static func colorMatrix(gain: CGFloat, bias: CGFloat) -> [String: Any] {
        ["inputRVector": CIVector(x: gain, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: gain, z: 0, w: 0),
         "inputBVector": CIVector(x: 0, y: 0, z: gain, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
         "inputBiasVector": CIVector(x: bias, y: bias, z: bias, w: 0)]
    }

    /// sRGB-encoded colour as a constant image (Core Image converts to the working space).
    static func constant(_ c: BorderColor, _ rect: CGRect) -> CIImage {
        let cg = CGColor(colorSpace: Renderer.sRGB, components: [CGFloat(c.r), CGFloat(c.g), CGFloat(c.b), 1])!
        return CIImage(color: CIColor(cgColor: cg)).cropped(to: rect)
    }

    /// Per-channel gains on a grey field (R channel), plus bias.
    static func scale(_ n: CIImage, rgb: (CGFloat, CGFloat, CGFloat), bias: CGFloat) -> CIImage {
        n.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: rgb.0, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: rgb.1, y: 0, z: 0, w: 0),
            "inputBVector": CIVector(x: rgb.2, y: 0, z: 0, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputBiasVector": CIVector(x: bias, y: bias, z: bias, w: 0),
        ])
    }

    /// Weighted sum of two opaque images. The second term gets alpha 0, so the premultiplied addition keeps alpha 1
    /// (CIAdditionCompositing adds alpha too).
    static func add(_ a: CIImage, _ b: CIImage, weights: (CGFloat, CGFloat)) -> CIImage {
        let wa = a.applyingFilter("CIColorMatrix", parameters: colorMatrix(gain: weights.0, bias: 0))
        var m = colorMatrix(gain: weights.1, bias: 0)
        m["inputAVector"] = CIVector(x: 0, y: 0, z: 0, w: 0)
        let wb = b.applyingFilter("CIColorMatrix", parameters: m)
        return wb.applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: wa])
    }

    static func multiply(_ a: CIImage, by b: CIImage) -> CIImage {
        a.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: b])
    }

    static func blend(_ top: CIImage, over bottom: CIImage, mask: CIImage) -> CIImage {
        top.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: bottom, kCIInputMaskImageKey: mask])
    }

    /// Linear ramp of a field: 0 at `from`, `strength` at `to` (either direction), clamped.
    static func ramp(_ n: CIImage, from: CGFloat, to: CGFloat, strength: CGFloat) -> CIImage {
        let g = strength / (to - from)
        return n.applyingFilter("CIColorMatrix", parameters: colorMatrix(gain: g, bias: -from * g))
            .applyingFilter("CIColorClamp", parameters: [
                "inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputMaxComponents": CIVector(x: max(strength, 0), y: max(strength, 0), z: max(strength, 0), w: 1),
            ])
    }

    // MARK: masks

    /// Grey mask (1 = inside) drawn with antialiasing in linear grey, so coverage stays linear.
    static func rasterize(_ w: Int, _ h: Int, _ draw: (CGContext) -> Void) -> CIImage {
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: Renderer.linearGray, bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
            return CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: w, height: h))
        }
        ctx.setShouldAntialias(true)
        ctx.setFillColor(gray: 1, alpha: 1)
        draw(ctx)
        guard let img = ctx.makeImage() else { return CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: w, height: h)) }
        return CIImage(cgImage: img)
    }

    /// Seeded specks (round dots) and short curved hairs, sizes as fractions of the short edge, grey = opacity.
    static func drawSpecks(_ ctx: CGContext, count: Int, seed: UInt64, stream: UInt64, short: Double,
                           size: (Double, Double), hairs: Double, alpha: (Double, Double)) {
        guard count > 0 else { return }
        var r = BorderRandom(seed: seed, stream: stream)
        let W = Double(ctx.width), H = Double(ctx.height)
        for _ in 0..<count {
            let x = r.unit() * W, y = r.unit() * H
            let a = alpha.0 + (alpha.1 - alpha.0) * r.unit()
            let d = (size.0 + (size.1 - size.0) * r.unit() * r.unit()) * short   // mostly small
            ctx.setFillColor(gray: a, alpha: 1); ctx.setStrokeColor(gray: a, alpha: 1)
            if r.unit() < hairs {
                let len = (0.002 + 0.008 * r.unit()) * short, ang = r.unit() * 2 * .pi, bend = (r.unit() - 0.5) * len
                ctx.setLineWidth(max(0.6, d * 0.35)); ctx.setLineCap(.round)
                ctx.beginPath(); ctx.move(to: CGPoint(x: x, y: y))
                ctx.addQuadCurve(to: CGPoint(x: x + cos(ang) * len, y: y + sin(ang) * len),
                                 control: CGPoint(x: x + cos(ang) * len / 2 - sin(ang) * bend, y: y + sin(ang) * len / 2 + cos(ang) * bend))
                ctx.strokePath()
            } else {
                ctx.fillEllipse(in: CGRect(x: x - d / 2, y: y - d / 2, width: d, height: d * (0.6 + 0.4 * r.unit())))
            }
        }
    }

    static func fill(_ ctx: CGContext, _ pts: [BorderPoint]) {
        guard let first = pts.first else { return }
        ctx.beginPath()
        ctx.move(to: CGPoint(x: first.x, y: first.y))
        for p in pts.dropFirst() { ctx.addLine(to: CGPoint(x: p.x, y: p.y)) }
        ctx.closePath()
        ctx.fillPath()
    }

    /// Edge print in the rebate band between the strip edge and the holes on one side (chosen by the seed):
    /// frame number, arrow + "nA", and a run of bars. Generic markings only, no maker names.
    static func drawMarkings(_ ctx: CGContext, _ L: FilmBorderLayout, _ cfg: FilmBorderConfiguration, frame n: Int) {
        let W = CGFloat(L.canvasWidth), H = CGFloat(L.canvasHeight)
        let horizontal = L.filmHorizontal
        let length = horizontal ? W : H, strip = horizontal ? H : W
        let mm = strip / 35
        var side = BorderRandom(seed: cfg.render.rollSeed ?? cfg.render.randomSeed, stream: 8)
        let farSide = side.unit() < 0.5   // edge print sits on the same edge for the whole roll
        var r = BorderRandom(seed: cfg.render.randomSeed, stream: 16)
        // Work in strip coordinates: x along the strip, y across it (0 = band edge); map to the canvas.
        // Rotations only (no mirroring), so the print always reads correctly along its edge, as on real film.
        ctx.saveGState()
        if horizontal {
            if farSide { ctx.translateBy(x: W, y: H); ctx.rotate(by: .pi) }               // top edge, upside down
        } else if farSide {
            ctx.translateBy(x: W, y: 0); ctx.rotate(by: .pi / 2)                          // right edge, reads upward
        } else {
            ctx.translateBy(x: 0, y: H); ctx.rotate(by: -.pi / 2)                         // left edge, reads downward
        }
        let font = CTFontCreateWithName("AvenirNextCondensed-Bold" as CFString, 2.4 * mm, nil)
        func text(_ s: String, at x: CGFloat) {
            let attr = NSAttributedString(string: s, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
            ])
            let line = CTLineCreateWithAttributedString(attr)
            ctx.textPosition = CGPoint(x: x, y: 0.2 * mm)
            CTLineDraw(line, ctx)
        }
        let start = CGFloat(r.unit()) * 0.1 * length
        text("\(n)", at: start + 0.12 * length)
        text("\u{25B6} \(n)A", at: start + 0.52 * length)
        // Bars (a generic code-like run).
        var x = start + 0.72 * length
        for _ in 0..<12 {
            let w = (0.25 + CGFloat(r.unit()) * 0.6) * mm
            if r.unit() < 0.7 { ctx.fill(CGRect(x: x, y: 0, width: w, height: 1.8 * mm)) }   // code blocks sit on the strip edge
            x += w + 0.3 * mm
        }
        ctx.restoreGState()
    }
}

private extension CIImage {
    /// Adds a constant to every colour channel.
    func offset(by v: CGFloat) -> CIImage {
        applyingFilter("CIColorMatrix", parameters: FilmBorderRenderer.colorMatrix(gain: 1, bias: v))
    }
}
#endif

#if canImport(CoreImage) && canImport(CoreText)
public extension FilmBorderRenderer {
    /// Pad a bordered print onto a fixed-aspect share canvas (`ShareCanvas`): backdrop, soft contact shadow, the print
    /// scaled to fit (never cropped). Deterministic; no randomness. Returns the image and a note for the recipe.
    static func share(_ print: CIImage, canvas s: ShareCanvas) throws -> (image: CIImage, layout: ShareCanvasLayout, note: String) {
        let src = print.transformed(by: CGAffineTransform(translationX: -print.extent.minX, y: -print.extent.minY))
        let L = try ShareCanvasLayout.compute(s, printWidth: Int(src.extent.width.rounded()), printHeight: Int(src.extent.height.rounded()))
        let canvas = CGRect(x: 0, y: 0, width: L.canvasWidth, height: L.canvasHeight)
        let placed = src.transformed(by: CGAffineTransform(scaleX: L.scale, y: L.scale)
            .concatenating(CGAffineTransform(translationX: L.print.x, y: L.print.y)))
        var back = constant(s.background, canvas)
        if s.shadow > 0 {
            let short = Double(min(L.canvasWidth, L.canvasHeight))
            let box = CIImage(color: .white).cropped(to: CGRect(x: L.print.x, y: L.print.y, width: L.print.width, height: L.print.height))
            let shade = box.composited(over: CIImage(color: .black).cropped(to: canvas))
                .clampedToExtent().applyingGaussianBlur(sigma: short * 0.012)
                .transformed(by: CGAffineTransform(translationX: 0, y: -short * 0.004)).cropped(to: canvas)
            back = multiply(back, by: shade.applyingFilter("CIColorMatrix", parameters: colorMatrix(gain: -0.3 * CGFloat(s.shadow), bias: 1)))
        }
        let out = placed.composited(over: back).cropped(to: canvas)
        let note = String(format: "share canvas %@ %dx%d, print scale %.3f at (%.0f, %.0f), margin %.2f, shadow %.2f, background %@",
                          s.aspect.rawValue, L.canvasWidth, L.canvasHeight, L.scale, L.print.x, L.print.y, s.margin, s.shadow, s.background.hex)
        return (out, L, note)
    }
}
#endif

#if canImport(CoreImage) && canImport(CoreText)
public extension FilmBorderRenderer {
    /// Border + share canvas in one call. The print's own backdrop (corners of a rounded card, the margin around a
    /// deckle card, sprocket holes) takes the share background, so no second box shows; a card that already has a
    /// contact shadow (`paperInset` > 0) gets no extra box shadow.
    static func renderForShare(_ developed: CIImage, configuration: FilmBorderConfiguration, canvas: ShareCanvas,
                               outputLongEdge: Int? = nil) throws -> FilmBorderResult {
        var cfg = configuration
        cfg.layout.backdrop = canvas.background
        var r = try render(developed, configuration: cfg, outputLongEdge: outputLongEdge)
        var s = canvas
        if cfg.layout.paperInset > 0 { s.shadow = 0 }
        let shared = try share(r.image, canvas: s)
        r.image = shared.image
        r.record.share = s
        r.record.shareCanvasSize = [shared.layout.canvasWidth, shared.layout.canvasHeight]
        r.record.notes.append(shared.note)
        return r
    }
}
#endif
