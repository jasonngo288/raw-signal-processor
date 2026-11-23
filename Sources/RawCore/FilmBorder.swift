import Foundation

// Film Border Renderer — pure-Swift model (spec: FILM_BORDER_RENDERER_SPEC.md v1.0, 2026-11-21).
//
// - The border is a separate stage AFTER film development. It gets a developed image plus a
//   `FilmBorderConfiguration`, never film-stock parameters, and applies no colour transform to the photo.
// - Five independent components, each a section of the configuration:
//     A. `shape`    border shape: straight scan edge or deckle (scalloped) paper edge, corner radii
//     B. `paper`    paper texture: base colour, fibre texture, mottle, aging, speckles
//     C. `edge`     edge imperfection: irregular photo opening, gate shadow, wear / dust, edge burn
//     D. `filmEdge` film edge: film base, sprocket holes, edge markings (frame numbers, arrow, bars)
//     E. `layout`   border layout: insets, size multiplier, canvas / opening aspect, fit mode, backdrop
// - All geometry is normalized, so a preview and an export of the same configuration and seed match.
// - All variation comes from `render.randomSeed`; nothing is random per refresh.
// - Everything is procedural: no raster assets and no AI.
//
// Mask convention (every mask in the renderer): 1 = visible / inside, 0 = excluded, values in between = antialiased
// coverage. The paper mask is the paper region, the opening mask is the photo opening, the hole mask is the holes.

/// sRGB colour as 0...1 components (`#RRGGBB` in JSON).
public struct BorderColor: Codable, Equatable, Sendable {
    public var r: Float, g: Float, b: Float
    public init(r: Float, g: Float, b: Float) { self.r = r; self.g = g; self.b = b }
    public init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        r = Float((v >> 16) & 0xFF) / 255; g = Float((v >> 8) & 0xFF) / 255; b = Float(v & 0xFF) / 255
    }
    public var hex: String {
        func c(_ x: Float) -> Int { Int((min(max(x, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", c(r), c(g), c(b))
    }
    public init(from decoder: Decoder) throws {
        let s = try decoder.singleValueContainer().decode(String.self)
        guard let c = BorderColor(hex: s) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "bad colour \(s)"))
        }
        self = c
    }
    public func encode(to encoder: Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(hex) }
}

public struct FilmBorderConfiguration: Codable, Equatable, Sendable {
    public static let schemaVersion = 1

    public enum FitMode: String, Codable, Sendable { case aspectFit, aspectFill }
    public enum Outline: String, Codable, Sendable { case straight, deckle }

    /// A. Border shape.
    public struct Shape: Codable, Equatable, Sendable {
        /// Outer paper edge: a straight (scanned / cut) edge, or a deckle (scalloped) edge.
        public var outline: Outline = .straight
        /// Deckle scallop depth (fraction of the canvas short edge) and scallops per long paper edge.
        public var deckleDepth: Float = 0.006
        public var deckleCount: Int = 44
        /// Corner radius of the paper and of the photo opening (fraction of the canvas short edge).
        public var paperCornerRadius: Float = 0
        public var openingCornerRadius: Float = 0
        public init() {}
    }

    /// B. Paper texture.
    public struct Paper: Codable, Equatable, Sendable {
        public var color: BorderColor = BorderColor(hex: "#ECE9E1")!
        /// Fine fibre texture (luminance modulation), 0...1.
        public var textureStrength: Float = 0.12
        /// Low-frequency mottle (uneven paper tone), 0...1.
        public var mottleStrength: Float = 0.10
        /// Aging: warm yellow-brown toward the paper edge plus soft stains, 0...1.
        public var agingStrength: Float = 0
        /// Sparse dark speckles on the paper, 0...1.
        public var speckles: Float = 0
        /// Paper fibres: short faint curved strokes, light and dark, 0...1.
        public var fibres: Float = 0
        public init() {}
    }

    /// C. Edge imperfection.
    public struct Edge: Codable, Equatable, Sendable {
        /// Deviation of the photo opening from a clean rectangle, 0...1 (1 ≈ 0.3 % of the short edge).
        public var irregularity: Float = 0.35
        /// Fine jagged edge (torn emulsion / film-gate edge as in a real scan: serrations of a few px), 0...1
        /// (1 ≈ 0.14 % of the short edge).
        public var roughness: Float = 0
        /// Soft photo edge (feather), 0...1 (1 ≈ 0.12 % of the short edge).
        public var softness: Float = 0
        /// Warm thin fringe along parts of the edge (yellow-orange line seen at scanned frame edges), 0...1.
        public var fringe: Float = 0
        /// Dark gate shadow all round the photo opening, 0...1 (thin, patchy).
        public var darkening: Float = 0.18
        /// Scan tilt: the photo and its opening are rotated by up to this many degrees (seeded, ±), 0...1.
        /// A slightly crooked frame is what makes a real scan's border uneven.
        public var rotation: Float = 0
        /// Film-gate line on ONE side (same side for the whole roll): a thin, jagged, broken dark line, 0...1.
        public var gateLine: Float = 0
        /// Light band just inside the photo edge (scans often brighten the last few px), 0...1.
        public var lift: Float = 0
        /// Sparse small wear marks along the opening, 0...1.
        public var wear: Float = 0.12
        /// Scan dust over the whole print (tiny light and dark specks), 0...1.
        public var dust: Float = 0.05
        /// Amber edge burn (light reaching the frame edge), 0...1, on `burnEdges` sides chosen by the seed.
        public var burn: Float = 0
        public var burnEdges: Int = 1
        public init() {}
    }

    /// D. Film edge (a film strip instead of paper).
    public struct FilmEdge: Codable, Equatable, Sendable {
        public var enabled = false
        /// Film base colour (the strip around the frame).
        public var baseColor: BorderColor = BorderColor(hex: "#D8D6D1")!
        /// Sprocket holes along both long sides of the strip.
        public var sprocketHoles = true
        /// Edge print colour (frame numbers, arrow, bars) and strength 0...1 (0 = no markings).
        public var markingColor: BorderColor = BorderColor(hex: "#C2561C")!
        public var markings: Float = 0.85
        /// Frame number printed on the edge ("12" and "12A"); nil = derived from the seed.
        public var frameNumber: Int? = nil
        public init() {}
    }

    /// E. Border layout.
    public struct Layout: Codable, Equatable, Sendable {
        /// Border widths: top / bottom as fractions of the canvas height, left / right of the canvas width.
        public var top: Float = 0.012
        public var bottom: Float = 0.016
        public var left: Float = 0.009
        public var right: Float = 0.011
        /// User border-size control: scales the four widths together (relative differences kept).
        public var sizeMultiplier: Float = 1
        /// Canvas width / height. nil = adapt to the photo (the opening keeps the photo's aspect).
        public var canvasAspect: Float? = nil
        /// Photo opening width / height. nil = the photo's own aspect. Used with `aspectFill` (e.g. a square instant print).
        public var openingAspect: Float? = nil
        public var fitMode: FitMode = .aspectFit
        /// Space between the canvas edge and the paper (fraction of the canvas short edge), filled with `backdrop`.
        public var paperInset: Float = 0
        public var backdrop: BorderColor = BorderColor(hex: "#F4F4F2")!
        /// Per-photo variation of each border width, ± this fraction (seeded), so a roll's borders are not identical.
        public var jitter: Float = 0
        /// Instant-print card chosen by the photo's orientation (wide card for landscape, mini for portrait, square
        /// otherwise), opening aspect clamped to the card's range so a normal phone photo is not cropped.
        /// Overrides top / bottom / left / right and `openingAspect`.
        public var instantFormats = false
        public init() {}
    }

    public struct Render: Codable, Equatable, Sendable {
        public var randomSeed: UInt64 = 12345
        /// Seed shared by the whole roll (edge-print side, gate-line side, burn side). nil = `randomSeed`.
        public var rollSeed: UInt64? = nil
        /// Frame position in the roll (1-based) and roll length: frame number on the film edge and the edge-burn
        /// pattern (strong on the first frames, rare mid-roll). nil = single photo.
        public var frameIndex: Int? = nil
        public var rollLength: Int? = nil
        /// Working space of the compositing (documented policy; the renderer works in extended linear Display P3,
        /// colours above are sRGB-encoded and converted by Core Image).
        public var workingColorSpace = "extendedLinearDisplayP3"
        public init() {}
    }

    public var id: String
    public var version: Int = FilmBorderConfiguration.schemaVersion
    public var displayName: String
    public var shape = Shape()
    public var paper = Paper()
    public var edge = Edge()
    public var filmEdge = FilmEdge()
    public var layout = Layout()
    public var render = Render()

    public init(id: String, displayName: String) { self.id = id; self.displayName = displayName }

    /// The same template with a seed derived from a stable key (e.g. a frame id), so each photo keeps its own border.
    public func seeded(_ key: String) -> FilmBorderConfiguration {
        var c = self
        var h: UInt64 = 0xCBF2_9CE4_8422_2325   // FNV-1a 64
        for b in key.utf8 { h ^= UInt64(b); h = h &* 0x0000_0100_0000_01B3 }
        c.render.randomSeed = h
        return c
    }

    /// Effective border widths after the size multiplier.
    public var insets: (top: Float, bottom: Float, left: Float, right: Float) {
        let m = layout.sizeMultiplier
        return (layout.top * m, layout.bottom * m, layout.left * m, layout.right * m)
    }

    /// Clamp every user-facing intensity into its documented range (returns the clamped copy).
    public func clamped() -> FilmBorderConfiguration {
        func c(_ x: Float) -> Float { min(max(x, 0), 1) }
        var o = self
        o.paper.textureStrength = c(paper.textureStrength); o.paper.mottleStrength = c(paper.mottleStrength)
        o.paper.agingStrength = c(paper.agingStrength); o.paper.speckles = c(paper.speckles)
        o.edge.irregularity = c(edge.irregularity); o.edge.darkening = c(edge.darkening); o.edge.wear = c(edge.wear)
        o.edge.roughness = c(edge.roughness); o.edge.softness = c(edge.softness); o.edge.fringe = c(edge.fringe)
        o.edge.rotation = c(edge.rotation); o.edge.gateLine = c(edge.gateLine); o.edge.lift = c(edge.lift)
        o.paper.fibres = c(paper.fibres); o.layout.jitter = min(max(layout.jitter, 0), 0.5)
        o.edge.dust = c(edge.dust); o.edge.burn = c(edge.burn); o.edge.burnEdges = min(max(edge.burnEdges, 0), 4)
        o.filmEdge.markings = c(filmEdge.markings)
        o.layout.sizeMultiplier = min(max(layout.sizeMultiplier, 0.25), 3)
        o.shape.deckleDepth = min(max(shape.deckleDepth, 0), 0.02); o.shape.deckleCount = min(max(shape.deckleCount, 8), 200)
        o.shape.paperCornerRadius = min(max(shape.paperCornerRadius, 0), 0.05)
        o.shape.openingCornerRadius = min(max(shape.openingCornerRadius, 0), 0.05)
        return o
    }

    /// Smallest photo opening allowed, as a fraction of the canvas in each dimension.
    public static let minimumOpening: Float = 0.5

    /// Structural checks (intensities are clamped, not rejected).
    public func validate() throws {
        func bad(_ s: String) -> RawCoreError { .invalidSettings("film border \(id): \(s)") }
        guard version == Self.schemaVersion else { throw bad("unknown schema version \(version) (supported: \(Self.schemaVersion))") }
        let l = layout
        guard [l.top, l.bottom, l.left, l.right, l.paperInset].allSatisfy({ $0 >= 0 && $0.isFinite }) else { throw bad("negative border width") }
        guard l.sizeMultiplier > 0 else { throw bad("size multiplier must be > 0") }
        let i = clamped().insets
        guard i.top + i.bottom < 1, i.left + i.right < 1 else { throw bad("borders cover the whole canvas") }
        guard 1 - i.top - i.bottom >= Self.minimumOpening, 1 - i.left - i.right >= Self.minimumOpening else {
            throw bad(String(format: "photo opening below %.0f %% of the canvas", Self.minimumOpening * 100))
        }
        if let a = l.canvasAspect { guard a > 0.2, a < 5 else { throw bad("canvas aspect \(a) out of range") } }
        if let a = l.openingAspect { guard a > 0.2, a < 5 else { throw bad("opening aspect \(a) out of range") } }
        if l.paperInset > 0 {
            guard l.paperInset < min(i.top, i.bottom, i.left, i.right) else { throw bad("paper inset must be smaller than every border") }
        }
    }
}

// MARK: templates

public enum FilmBorderTemplates {
    /// P0. Scanned print as in the user's reference scans (art-director review 2026-11-21, measured on the
    /// references): near-white flat border (#FAF8F3, almost no texture), very thin and uneven because the frame sits
    /// slightly crooked (±0.3°) and varies per photo; soft, finely serrated photo edge, a little brighter at the
    /// edge, with a broken dark film-gate line on one side only and a warm fringe on parts of the edge.
    public static let classicScan: FilmBorderConfiguration = {
        var c = FilmBorderConfiguration(id: "classic_scan", displayName: "Classic Scan")
        c.paper.color = BorderColor(hex: "#FAF8F3")!
        c.paper.textureStrength = 0.015; c.paper.mottleStrength = 0.02
        c.edge.irregularity = 0.2; c.edge.roughness = 0.5; c.edge.softness = 0.9; c.edge.fringe = 0.25
        c.edge.darkening = 0; c.edge.gateLine = 0.7; c.edge.lift = 0.1; c.edge.rotation = 0.3
        c.edge.wear = 0.03; c.edge.dust = 0.03
        c.shape.openingCornerRadius = 0.003
        c.layout.top = 0.006; c.layout.bottom = 0.011; c.layout.left = 0.005; c.layout.right = 0.007
        c.layout.jitter = 0.25
        return c
    }()

    /// Photo-opening edge shared by every template (user 2026-11-23: "viền ảnh … nên giống frame của film scan"):
    /// the scanned film-frame edge of classic_scan — fine serrations, soft, slightly brighter just inside, a broken dark
    /// gate line on one side, a warm fringe on parts of the edge, barely rounded corners.
    static func scanFrameEdge(_ c: inout FilmBorderConfiguration, strength k: Float = 1) {
        c.edge.irregularity = 0.2; c.edge.roughness = 0.5 * k; c.edge.softness = 0.9
        c.edge.gateLine = 0.7 * k; c.edge.lift = 0.1 * k; c.edge.fringe = 0.25 * k
        c.shape.openingCornerRadius = 0.003
    }

    /// P0. Aged cream paper print, edge to edge (user 2026-11-23: no white backdrop around the card, less paper
    /// between photo and edge): straight worn paper edge, aging toward the edge, fibres, a few specks; the photo has
    /// the scanned film-frame edge.
    public static let agedPaper: FilmBorderConfiguration = {
        var c = FilmBorderConfiguration(id: "aged_paper", displayName: "Aged Paper")
        c.shape.outline = .straight
        c.paper.color = BorderColor(hex: "#EFE8D6")!
        c.paper.textureStrength = 0.05; c.paper.mottleStrength = 0.12; c.paper.agingStrength = 0.45
        c.paper.speckles = 0.2; c.paper.fibres = 0.5
        scanFrameEdge(&c)
        c.edge.darkening = 0.06; c.edge.wear = 0.05; c.edge.dust = 0.05
        c.layout.top = 0.04; c.layout.bottom = 0.045; c.layout.left = 0.032; c.layout.right = 0.032
        c.layout.paperInset = 0; c.layout.jitter = 0.08
        return c
    }()

    /// P1. Film strip, light (user 2026-11-23: "viền phim quá nặng"): the strip is shown as a scanner carrier does,
    /// with a narrower rebate (0.13 of the canvas instead of the full 0.157 of a 35 mm strip), smaller and fainter
    /// edge print, a lighter base, holes close to the base tone; the photo has the scanned film-frame edge. Edge burn on the
    /// frame's leading edge, following the roll position (strong on frames 1–2).
    public static let filmNegative: FilmBorderConfiguration = {
        var c = FilmBorderConfiguration(id: "film_negative", displayName: "Film Negative")
        c.filmEdge.enabled = true; c.filmEdge.markings = 0.45
        c.filmEdge.baseColor = BorderColor(hex: "#DDDCDD")!
        c.filmEdge.markingColor = BorderColor(hex: "#C9764A")!
        c.paper.textureStrength = 0.015; c.paper.mottleStrength = 0.05
        scanFrameEdge(&c)
        c.edge.darkening = 0.12; c.edge.wear = 0.05; c.edge.dust = 0.08
        c.edge.burn = 0.25; c.edge.burnEdges = 1
        c.layout.top = 0.13; c.layout.bottom = 0.13; c.layout.left = 0.03; c.layout.right = 0.03
        c.layout.backdrop = BorderColor(hex: "#EEEEEC")!
        return c
    }()

    /// P1. Instant print: card picked by the photo's orientation (wide / mini / square) so a phone photo is not cut
    /// to a square; smooth off-white card, rounded corners; the photo has a lighter scanned film-frame edge.
    public static let instantPrint: FilmBorderConfiguration = {
        var c = FilmBorderConfiguration(id: "instant_print", displayName: "Instant Print")
        c.paper.color = BorderColor(hex: "#F4F3EF")!
        c.paper.textureStrength = 0.015; c.paper.mottleStrength = 0.02
        c.shape.paperCornerRadius = 0.008
        scanFrameEdge(&c, strength: 0.6)
        c.edge.irregularity = 0.12; c.edge.darkening = 0.08; c.edge.wear = 0; c.edge.dust = 0.01
        c.layout.instantFormats = true; c.layout.fitMode = .aspectFill
        return c
    }()

    /// Instant cards (fractions of the card): (top, bottom, left / right, opening aspect range).
    /// Wide 108×86 mm with a 99×62 image, mini 54×86 with 46×62, square 88×107 with 79×79; bottom margins
    /// compressed from ≈ 0.20 to 0.17 for balance on a phone screen (art-director review).
    public static let instantWide = (top: Float(0.08), bottom: Float(0.17), side: Float(0.042), aspect: (1.25, 1.8))
    public static let instantMini = (top: Float(0.07), bottom: Float(0.17), side: Float(0.074), aspect: (0.62, 0.80))
    public static let instantSquare = (top: Float(0.05), bottom: Float(0.17), side: Float(0.051), aspect: (1.0, 1.0))

    public static let all: [FilmBorderConfiguration] = [classicScan, agedPaper, filmNegative, instantPrint]
    public static func named(_ id: String) -> FilmBorderConfiguration? { all.first { $0.id == id } }
}

// MARK: layout and procedural geometry (pixels, origin bottom-left as in Core Image)

public struct BorderRect: Codable, Equatable, Sendable {
    public var x: Double, y: Double, width: Double, height: Double
    public init(x: Double, y: Double, width: Double, height: Double) { self.x = x; self.y = y; self.width = width; self.height = height }
    public var maxX: Double { x + width }
    public var maxY: Double { y + height }
    public var aspect: Double { width / height }
}

public struct BorderPoint: Equatable, Sendable { public var x: Double, y: Double }

/// Deterministic generator (SplitMix64) and smooth 1-D value noise for edge shapes.
public struct BorderRandom: Sendable {
    var state: UInt64
    public init(seed: UInt64, stream: UInt64) { state = seed ^ (stream &* 0x9E37_79B9_7F4A_7C15) }
    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    /// Uniform in [0, 1).
    public mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
    /// Uniform in [-1, 1).
    public mutating func signed() -> Double { unit() * 2 - 1 }
}

/// Periodic smooth noise on [0, 1): `octaves` of cosine-interpolated lattice values, amplitude ~[-1, 1].
public struct EdgeNoise: Sendable {
    let lattices: [[Double]]
    let weights: [Double]
    public init(seed: UInt64, stream: UInt64, cells: [Int], weights: [Double]) {
        var r = BorderRandom(seed: seed, stream: stream)
        lattices = cells.map { n in (0..<max(n, 1)).map { _ in r.signed() } }
        let s = weights.reduce(0, +)
        self.weights = weights.map { $0 / max(s, 1e-9) }
    }
    public func value(_ t: Double) -> Double {
        var v = 0.0
        for (lat, w) in zip(lattices, weights) {
            let n = lat.count
            let p = (t - t.rounded(.down)) * Double(n)
            let i = Int(p) % n, j = (i + 1) % n
            let f = p - Double(Int(p))
            let s = (1 - cos(f * .pi)) / 2
            v += w * (lat[i] * (1 - s) + lat[j] * s)
        }
        return v
    }
}

public struct FilmBorderLayout: Equatable, Sendable {
    /// Canvas size in pixels.
    public var canvasWidth: Int, canvasHeight: Int
    /// Paper region (inside `paperInset`) and the photo opening.
    public var paper: BorderRect
    public var opening: BorderRect
    /// Where the photo is drawn (equals `opening` for aspect-fit; larger, then clipped, for aspect-fill).
    public var photo: BorderRect
    /// Scale applied to the developed image (1 = the photo keeps its pixels).
    public var photoScale: Double
    /// Fraction of the photo cut away by aspect-fill (0 for aspect-fit).
    public var cropFraction: Double
    /// Film strip direction: true = runs left-right (rebates top / bottom, landscape frame).
    public var filmHorizontal: Bool = true
    /// Scan tilt of the photo and its opening (radians, about the opening centre).
    public var rotation: Double = 0

    public var shortEdge: Double { Double(min(canvasWidth, canvasHeight)) }

    /// Layout for a developed photo of `photoWidth` × `photoHeight` pixels. The photo keeps its own pixel scale
    /// (`photoScale` = 1); with `outputLongEdge` the whole canvas is scaled to that long edge instead (previews).
    public static func compute(_ cfg: FilmBorderConfiguration, photoWidth pw: Int, photoHeight ph: Int,
                               outputLongEdge: Int? = nil) throws -> FilmBorderLayout {
        try cfg.validate()
        guard pw > 0, ph > 0 else { throw RawCoreError.invalidSettings("film border: empty photo") }
        var c = cfg.clamped()
        let photoAspect = Double(pw) / Double(ph)
        if c.layout.instantFormats {
            let f = photoAspect >= 1.15 ? FilmBorderTemplates.instantWide
                : (photoAspect <= 0.87 ? FilmBorderTemplates.instantMini : FilmBorderTemplates.instantSquare)
            c.layout.top = f.top; c.layout.bottom = f.bottom; c.layout.left = f.side; c.layout.right = f.side
            c.layout.openingAspect = Float(min(max(photoAspect, f.aspect.0), f.aspect.1))
        }
        var i = c.insets
        if c.layout.jitter > 0 {
            var r = BorderRandom(seed: c.render.randomSeed, stream: 10)
            let j = c.layout.jitter
            i = (top: i.top * (1 + j * Float(r.signed())), bottom: i.bottom * (1 + j * Float(r.signed())),
                 left: i.left * (1 + j * Float(r.signed())), right: i.right * (1 + j * Float(r.signed())))
        }
        // A film strip runs along the frame's long side: for a portrait photo the rebates (and holes) go left / right.
        let portraitOpening = Double(c.layout.openingAspect ?? Float(photoAspect)) < 1
        if c.filmEdge.enabled && portraitOpening { i = (top: i.left, bottom: i.right, left: i.top, right: i.bottom) }
        let fw = Double(1 - i.left - i.right), fh = Double(1 - i.top - i.bottom)   // opening fraction of canvas
        let openingAspect = Double(c.layout.openingAspect ?? Float(photoAspect))
        // Canvas aspect: given, or the one that makes the content rectangle exactly the opening aspect.
        let canvasAspect = Double(c.layout.canvasAspect ?? Float(openingAspect * fh / fw))
        // Content rectangle in canvas units (canvas height = 1).
        let contentW = canvasAspect * fw, contentH = fh
        // Opening inside the content rectangle: the requested opening aspect, fitted.
        var oW = contentW, oH = contentH
        if oW / oH > openingAspect { oW = oH * openingAspect } else { oH = oW / openingAspect }
        // Scale (pixels per canvas unit) so the photo keeps its pixels: fit = photo fits the opening, fill = covers it.
        let fitScale: Double
        switch c.layout.fitMode {
        case .aspectFit: fitScale = min(oW / Double(pw), oH / Double(ph))
        case .aspectFill: fitScale = max(oW / Double(pw), oH / Double(ph))
        }
        var unit = 1 / fitScale   // pixels per canvas-height unit
        if let le = outputLongEdge, le > 0 { unit = Double(le) / max(canvasAspect, 1) }
        let cw = max(Int((canvasAspect * unit).rounded()), 1), ch = max(Int(unit.rounded()), 1)
        let W = Double(cw), H = Double(ch)
        let cx = W * Double(i.left) + (W * fw - oW * unit) / 2   // opening centred in the content rectangle
        let cy = H * Double(i.bottom) + (H * fh - oH * unit) / 2
        let opening = BorderRect(x: cx, y: cy, width: oW * unit, height: oH * unit)
        // Photo placement.
        let s: Double
        switch c.layout.fitMode {
        case .aspectFit: s = min(opening.width / Double(pw), opening.height / Double(ph))
        case .aspectFill: s = max(opening.width / Double(pw), opening.height / Double(ph))
        }
        let w = Double(pw) * s, h = Double(ph) * s
        let photo = BorderRect(x: opening.x + (opening.width - w) / 2, y: opening.y + (opening.height - h) / 2, width: w, height: h)
        let shown = min(opening.width, w) * min(opening.height, h)
        let inset = Double(c.layout.paperInset) * min(W, H)
        let paper = BorderRect(x: inset, y: inset, width: W - 2 * inset, height: H - 2 * inset)
        // Scan tilt: seeded angle, reduced until the tilted opening keeps 0.2 % of the short edge of paper all round.
        var angle = 0.0
        if c.edge.rotation > 0 {
            var r = BorderRandom(seed: c.render.randomSeed, stream: 11)
            angle = Double(c.edge.rotation) * r.signed() * .pi / 180
            let margin = 0.002 * min(W, H), cxm = opening.x + opening.width / 2, cym = opening.y + opening.height / 2
            for _ in 0..<20 {
                let hx = (opening.width * abs(cos(angle)) + opening.height * abs(sin(angle))) / 2
                let hy = (opening.width * abs(sin(angle)) + opening.height * abs(cos(angle))) / 2
                if cxm - hx >= paper.x + margin, cxm + hx <= paper.maxX - margin,
                   cym - hy >= paper.y + margin, cym + hy <= paper.maxY - margin { break }
                angle *= 0.7
            }
        }
        return FilmBorderLayout(canvasWidth: cw, canvasHeight: ch, paper: paper, opening: opening, photo: photo,
                                photoScale: s, cropFraction: max(0, 1 - shown / (w * h)), filmHorizontal: !portraitOpening,
                                rotation: angle)
    }

    /// Closed outline of `rect` with rounded corners (`radius` px), sampled every ~`step` px, each point displaced
    /// outward along the normal by `displace(t)` px (t = 0...1 around the perimeter).
    public static func outline(_ rect: BorderRect, radius r0: Double, step: Double,
                               displace: (Double) -> Double) -> [BorderPoint] {
        let r = min(max(r0, 0), min(rect.width, rect.height) / 2)
        let sw = rect.width - 2 * r, sh = rect.height - 2 * r
        let arc = Double.pi / 2 * r
        let perimeter = 2 * (sw + sh) + 4 * arc
        let n = max(Int(perimeter / max(step, 0.5)), 16)
        var pts: [BorderPoint] = []
        pts.reserveCapacity(n)
        // Walk: bottom edge (left → right), bottom-right arc, right edge (up), top-right arc, top (right → left), ...
        let segs: [(len: Double, f: (Double) -> (Double, Double, Double, Double))] = [
            (sw, { u in (rect.x + r + u * sw, rect.y, 0, -1) }),
            (arc, { u in let a = -Double.pi / 2 + u * .pi / 2; return (rect.maxX - r + r * cos(a), rect.y + r + r * sin(a), cos(a), sin(a)) }),
            (sh, { u in (rect.maxX, rect.y + r + u * sh, 1, 0) }),
            (arc, { u in let a = u * .pi / 2; return (rect.maxX - r + r * cos(a), rect.maxY - r + r * sin(a), cos(a), sin(a)) }),
            (sw, { u in (rect.maxX - r - u * sw, rect.maxY, 0, 1) }),
            (arc, { u in let a = Double.pi / 2 + u * .pi / 2; return (rect.x + r + r * cos(a), rect.maxY - r + r * sin(a), cos(a), sin(a)) }),
            (sh, { u in (rect.x, rect.maxY - r - u * sh, -1, 0) }),
            (arc, { u in let a = Double.pi + u * .pi / 2; return (rect.x + r + r * cos(a), rect.y + r + r * sin(a), cos(a), sin(a)) }),
        ]
        for k in 0..<n {
            var d = Double(k) / Double(n) * perimeter
            let t = Double(k) / Double(n)
            for (idx, s) in segs.enumerated() where s.len > 0 || idx == segs.count - 1 {
                if d <= s.len || idx == segs.count - 1 {
                    let u = s.len > 0 ? min(d / s.len, 1) : 0
                    let (x, y, nx, ny) = s.f(u)
                    let off = displace(t)
                    pts.append(BorderPoint(x: x + nx * off, y: y + ny * off))
                    break
                }
                d -= s.len
            }
        }
        return pts
    }

    /// Photo opening outline: the opening with corner radius, edge irregularity (low-frequency, no spikes) and
    /// wear nicks. Never leaves the paper.
    public func openingOutline(_ cfg: FilmBorderConfiguration) -> [BorderPoint] {
        let c = cfg.clamped()
        let amp = Double(c.edge.irregularity) * 0.003 * shortEdge
        let noise = EdgeNoise(seed: c.render.randomSeed, stream: 1, cells: [7, 23, 61], weights: [1, 0.45, 0.2])
        // Serrations: lattice spacing ≈ 0.35 % and 0.12 % of the short edge along the perimeter.
        let rough = Double(c.edge.roughness) * 0.0014 * shortEdge
        let perimeter = 2 * (opening.width + opening.height)
        let jag = EdgeNoise(seed: c.render.randomSeed, stream: 9,
                            cells: [max(Int(perimeter / (0.0035 * shortEdge)), 8), max(Int(perimeter / (0.0012 * shortEdge)), 8)],
                            weights: [1, 0.7])
        let limit = min(opening.x - paper.x, opening.y - paper.y, paper.maxX - opening.maxX, paper.maxY - opening.maxY) * 0.8
        let step = rough > 0 ? max(0.6, shortEdge / 2600) : max(1, shortEdge / 900)
        let pts = Self.outline(opening, radius: Double(c.shape.openingCornerRadius) * shortEdge, step: step) { t in
            min(amp * noise.value(t) + rough * jag.value(t), limit)
        }
        return rotated(pts)
    }

    /// Points rotated by the scan tilt about the opening centre.
    public func rotated(_ pts: [BorderPoint]) -> [BorderPoint] {
        guard rotation != 0 else { return pts }
        let cx = opening.x + opening.width / 2, cy = opening.y + opening.height / 2
        let cs = cos(rotation), sn = sin(rotation)
        return pts.map { p in
            let dx = p.x - cx, dy = p.y - cy
            return BorderPoint(x: cx + dx * cs - dy * sn, y: cy + dx * sn + dy * cs)
        }
    }

    /// Film-gate line: polylines (broken into pieces) running just inside one side of the opening, jagged. Side
    /// chosen by the roll seed so a whole roll shares it. Width in px is the second value.
    public func gateLine(_ cfg: FilmBorderConfiguration) -> (pieces: [[BorderPoint]], width: Double) {
        let c = cfg.clamped()
        guard c.edge.gateLine > 0 else { return ([], 0) }
        var r = BorderRandom(seed: c.render.rollSeed ?? c.render.randomSeed, stream: 12)
        let side = Int(r.next() % 4)   // 0 bottom, 1 right, 2 top, 3 left
        let o = opening
        let len = side % 2 == 0 ? o.width : o.height
        let jag = EdgeNoise(seed: c.render.randomSeed, stream: 13, cells: [max(Int(len / (0.003 * shortEdge)), 8)], weights: [1])
        let gaps = EdgeNoise(seed: c.render.randomSeed, stream: 14, cells: [max(Int(len / (0.04 * shortEdge)), 4)], weights: [1])
        let inset = 0.0009 * shortEdge, amp = 0.0008 * shortEdge
        let n = max(Int(len / max(0.7, shortEdge / 2000)), 16)
        var pieces: [[BorderPoint]] = [], cur: [BorderPoint] = []
        for k in 0...n {
            let t = Double(k) / Double(n)
            let on = gaps.value(t) > -0.35   // ≈ 30 % broken
            let d = inset + amp * jag.value(t)
            let p: BorderPoint
            switch side {
            case 0: p = BorderPoint(x: o.x + t * o.width, y: o.y + d)
            case 1: p = BorderPoint(x: o.maxX - d, y: o.y + t * o.height)
            case 2: p = BorderPoint(x: o.x + t * o.width, y: o.maxY - d)
            default: p = BorderPoint(x: o.x + d, y: o.y + t * o.height)
            }
            if on { cur.append(p) } else if cur.count > 1 { pieces.append(rotated(cur)); cur = [] } else { cur = [] }
        }
        if cur.count > 1 { pieces.append(rotated(cur)) }
        return (pieces, 0.0011 * shortEdge)
    }

    /// Paper outline: straight (with a faint waviness from the irregularity) or deckle scallops (outward lobes,
    /// inward cusps, jittered). Stays inside the canvas.
    public func paperOutline(_ cfg: FilmBorderConfiguration) -> [BorderPoint] {
        let c = cfg.clamped()
        let radius = Double(c.shape.paperCornerRadius) * shortEdge
        let room = min(paper.x, paper.y)   // backdrop margin
        switch c.shape.outline {
        case .straight:
            let amp = min(Double(c.edge.irregularity) * 0.0008 * shortEdge, room * 0.8)
            let noise = EdgeNoise(seed: c.render.randomSeed, stream: 2, cells: [5, 17], weights: [1, 0.4])
            return Self.outline(paper, radius: radius, step: max(1, shortEdge / 900)) { t in amp > 0 ? amp * noise.value(t) : 0 }
        case .deckle:
            let depth = Double(c.shape.deckleDepth) * shortEdge
            let perimeter = 2 * (paper.width + paper.height)
            let lobes = (Double(c.shape.deckleCount) * perimeter / (2 * max(paper.width, paper.height))).rounded()   // integer: no seam spike
            let jitter = EdgeNoise(seed: c.render.randomSeed, stream: 3, cells: [Int(lobes.rounded()), 9], weights: [1, 0.6])
            let wear = EdgeNoise(seed: c.render.randomSeed, stream: 4, cells: [97], weights: [1])
            let base = -depth   // pull the edge in by the scallop depth, then push the lobes out
            return Self.outline(paper, radius: radius, step: max(0.7, shortEdge / 1400)) { t in
                let u = t * lobes + 0.35 * jitter.value(t)
                let lobe = sqrt(max(0, sin(Double.pi * (u - u.rounded(.down)))))
                let v = base + depth * lobe * (0.7 + 0.6 * jitter.value(t + 0.37)) + 0.12 * depth * wear.value(t)
                return min(v, room * 0.9)
            }
        }
    }

    /// Sprocket holes (35 mm geometry scaled to the strip): rounded rectangles along both long sides, centred in
    /// the rebate. Returns rects and the corner radius in px.
    public func sprocketHoles(_ cfg: FilmBorderConfiguration) -> (holes: [BorderRect], radius: Double) {
        let c = cfg.clamped()
        guard c.filmEdge.enabled, c.filmEdge.sprocketHoles else { return ([], 0) }
        let W = Double(canvasWidth), H = Double(canvasHeight)
        let horizontal = filmHorizontal   // strip runs along the frame's long side
        let stripWidth = horizontal ? H : W
        // Scale from the visible rebate (a 35 mm rebate is 5.5 mm), so a narrower rebate shrinks the perforations
        // with it and they never touch the photo; holes centred in the rebate.
        let mm = filmMillimetre
        let pitch = 4.75 * mm, holeAlong = 1.98 * mm, holeAcross = 2.8 * mm, centre = rebate / 2
        let length = horizontal ? W : H
        let count = max(Int((length / pitch).rounded(.down)), 1)
        var r = BorderRandom(seed: c.render.randomSeed, stream: 5)
        let phase = (length - Double(count - 1) * pitch) / 2 + (r.unit() - 0.5) * pitch * 0.3
        var out: [BorderRect] = []
        for k in 0..<count {
            let a = phase + Double(k) * pitch - holeAlong / 2
            guard a >= 0, a + holeAlong <= length else { continue }
            for side in [centre, stripWidth - centre] {
                let b = side - holeAcross / 2
                out.append(horizontal ? BorderRect(x: a, y: b, width: holeAlong, height: holeAcross)
                                      : BorderRect(x: b, y: a, width: holeAcross, height: holeAlong))
            }
        }
        return (out, 0.5 * mm)
    }

    /// Width of the narrower film rebate in px (between the strip edge and the photo).
    public var rebate: Double {
        filmHorizontal ? min(opening.y, Double(canvasHeight) - opening.maxY) : min(opening.x, Double(canvasWidth) - opening.maxX)
    }
    /// One "film millimetre" in px: the visible rebate is 5.5 mm, as on 35 mm film.
    public var filmMillimetre: Double { rebate / 5.5 }

    /// Edge-marking frame number: the configured one, else derived from the seed (1...36).
    public static func frameNumber(_ cfg: FilmBorderConfiguration) -> Int {
        if let n = cfg.filmEdge.frameNumber { return n }
        if let n = cfg.render.frameIndex { return n }
        var r = BorderRandom(seed: cfg.render.randomSeed, stream: 6)
        return 1 + Int(r.next() % 36)
    }

    /// Sides that get an edge burn (0 bottom, 1 right, 2 top, 3 left). On a film strip only the frame's ends (the
    /// short sides along the strip), the same end for the whole roll; otherwise any side, by the seed.
    public func burnSides(_ cfg: FilmBorderConfiguration) -> [Int] {
        let c = cfg.clamped()
        let n = c.edge.burnEdges
        guard n > 0, Self.burnAmount(cfg) > 0 else { return [] }
        if c.filmEdge.enabled {
            let ends = filmHorizontal ? [1, 3] : [0, 2]
            var r = BorderRandom(seed: c.render.rollSeed ?? c.render.randomSeed, stream: 7)
            let first = ends[Int(r.next() % 2)]
            return n >= 2 ? ends : [first]
        }
        var r = BorderRandom(seed: c.render.randomSeed, stream: 7)
        var sides = [0, 1, 2, 3]
        for i in stride(from: 3, to: 0, by: -1) { sides.swapAt(i, Int(r.next() % UInt64(i + 1))) }
        return Array(sides.prefix(n)).sorted()
    }

    /// Edge-burn strength for this frame. With a roll position: frames 1–2 strong (×2.4), the last frame ×1.2,
    /// mid-roll 8 % of frames faint (×0.5), the rest none, so a roll does not repeat one burn 36 times.
    /// Without one: the configured amount.
    public static func burnAmount(_ cfg: FilmBorderConfiguration) -> Float {
        let b = cfg.clamped().edge.burn
        guard b > 0, let f = cfg.render.frameIndex, let n = cfg.render.rollLength, n > 0 else { return b }
        if f <= 2 { return min(1, b * 2.4) }
        if f == n { return min(1, b * 1.2) }
        var r = BorderRandom(seed: cfg.render.randomSeed, stream: 15)
        return r.unit() < 0.08 ? b * 0.5 : 0
    }
}

/// What a border render did, for the recipe (spec §10: everything needed to reproduce it).
public struct FilmBorderRecord: Codable, Equatable, Sendable {
    public var configuration: FilmBorderConfiguration
    public var canvasSize: [Int]
    public var opening: BorderRect
    public var photo: BorderRect
    public var cropFraction: Double
    public var rotationDegrees: Double = 0
    /// Share canvas, when the print was padded for sharing (nil = the print alone).
    public var share: ShareCanvas? = nil
    public var shareCanvasSize: [Int]? = nil
    public var notes: [String]
}

// MARK: share canvas (Instagram)

/// A fixed-aspect canvas for sharing (product-designer review 2026-11-21): the bordered print is padded onto a
/// backdrop and is NEVER cropped, so Instagram's own 4:5 / 1:1 / 9:16 crop cannot cut the border off.
/// Stories keep the print inside the safe area (Instagram draws its UI over the top ≈ 14 % and bottom ≈ 20 %).
public struct ShareCanvas: Codable, Equatable, Sendable {
    public enum Aspect: String, Codable, CaseIterable, Sendable {
        case portrait4x5 = "4x5", square = "1x1", story9x16 = "9x16"
        /// Width / height.
        public var ratio: Double { switch self { case .portrait4x5: 0.8; case .square: 1; case .story9x16: 9.0 / 16.0 } }
        /// Instagram's upload size for this aspect (width × height, px).
        public var instagramSize: (Int, Int) {
            switch self { case .portrait4x5: (1080, 1350); case .square: (1080, 1080); case .story9x16: (1080, 1920) }
        }
    }

    public var aspect: Aspect = .portrait4x5
    /// Free space around the print as a fraction of the constraining dimension on each side (0.05 → the print
    /// fills ≈ 90 %).
    public var margin: Float = 0.05
    /// Backdrop colour (presets: `light`, `dark`, `white`).
    public var background: BorderColor = ShareCanvas.light
    /// Soft contact shadow under the print, 0...1 (0 = none).
    public var shadow: Float = 0.4
    /// Output width in px. nil = keep the print's own pixels (the canvas grows around it); `instagram` presets set 1080.
    public var outputWidth: Int? = nil

    public static let light = BorderColor(hex: "#E4E1DA")!
    public static let dark = BorderColor(hex: "#1C1B19")!
    public static let white = BorderColor(hex: "#FFFFFF")!

    public init(aspect: Aspect = .portrait4x5, margin: Float = 0.05, background: BorderColor = ShareCanvas.light,
                shadow: Float = 0.4, outputWidth: Int? = nil) {
        self.aspect = aspect; self.margin = margin; self.background = background; self.shadow = shadow; self.outputWidth = outputWidth
    }

    /// Instagram preset: 1080 px wide at the aspect's upload size.
    public static func instagram(_ a: Aspect, background: BorderColor = ShareCanvas.light) -> ShareCanvas {
        ShareCanvas(aspect: a, background: background, outputWidth: a.instagramSize.0)
    }

    /// Fractions of the canvas height Instagram covers with its own UI, top and bottom (stories only).
    public var safeTop: Double { aspect == .story9x16 ? 0.14 : 0 }
    public var safeBottom: Double { aspect == .story9x16 ? 0.20 : 0 }

    public func validate() throws {
        guard margin >= 0, margin < 0.3 else { throw RawCoreError.invalidSettings("share canvas: margin \(margin) out of 0..<0.3") }
        guard shadow >= 0, shadow <= 1 else { throw RawCoreError.invalidSettings("share canvas: shadow \(shadow) out of 0...1") }
        if let w = outputWidth { guard w >= 64 else { throw RawCoreError.invalidSettings("share canvas: width \(w) too small") } }
    }
}

public struct ShareCanvasLayout: Equatable, Sendable {
    public var canvasWidth: Int, canvasHeight: Int
    /// Where the print goes (px, origin bottom-left) and its scale (1 = the print keeps its pixels).
    public var print: BorderRect
    public var scale: Double

    /// Fit the print (`printWidth` × `printHeight`) inside the canvas minus margins and safe zones, centred in the
    /// usable area. The print is scaled uniformly, never cropped or stretched.
    public static func compute(_ s: ShareCanvas, printWidth pw: Int, printHeight ph: Int) throws -> ShareCanvasLayout {
        try s.validate()
        guard pw > 0, ph > 0 else { throw RawCoreError.invalidSettings("share canvas: empty print") }
        let r = s.aspect.ratio, m = Double(s.margin)
        // Usable area in canvas units (canvas height = 1, width = r): margins on every side, plus the story safe zones.
        let usableW = r * (1 - 2 * m)
        let usableH = 1 - s.safeTop - s.safeBottom - 2 * m * (s.aspect == .story9x16 ? r : 1)
        let printAspect = Double(pw) / Double(ph)
        var w = usableW, h = usableW / printAspect
        if h > usableH { h = usableH; w = h * printAspect }
        // Pixels per canvas-height unit: the requested width, else what keeps the print at its own pixels.
        let unit = s.outputWidth.map { Double($0) / r } ?? Double(ph) / h
        let cw = max(Int((r * unit).rounded()), 1), ch = max(Int(unit.rounded()), 1)
        let pwPx = w * unit, phPx = h * unit
        let x = (Double(cw) - pwPx) / 2
        let bottom = s.safeBottom * Double(ch), top = s.safeTop * Double(ch)
        let y = bottom + (Double(ch) - top - bottom - phPx) / 2
        return ShareCanvasLayout(canvasWidth: cw, canvasHeight: ch, print: BorderRect(x: x, y: y, width: pwPx, height: phPx),
                                 scale: pwPx / Double(pw))
    }
}

public extension FilmBorderConfiguration {
    /// The configuration for one frame of a roll: per-frame seed from "rollID/frameID", roll seed from rollID (edge-print
    /// side, gate-line side, burn end shared by the roll), frame position for the frame number and the burn pattern.
    /// Same inputs → same border, so preview, export and a re-open months later match.
    func forFrame(rollID: String, frameID: String, index: Int? = nil, count: Int? = nil) -> FilmBorderConfiguration {
        var c = seeded("\(rollID)/\(frameID)")
        c.render.rollSeed = seeded(rollID).render.randomSeed
        c.render.frameIndex = index
        c.render.rollLength = count
        return c
    }
}
