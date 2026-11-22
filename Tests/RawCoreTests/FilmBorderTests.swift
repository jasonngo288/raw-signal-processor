import XCTest
@testable import RawCore

/// Film Border Renderer (FilmBorder.swift, FilmBorderRenderer.swift): spec FILM_BORDER_RENDERER_SPEC.md §12.
final class FilmBorderTests: XCTestCase {
    func testTemplatesValidateAndRoundTrip() throws {
        XCTAssertEqual(FilmBorderTemplates.all.map(\.id), ["classic_scan", "aged_paper", "film_negative", "instant_print"])
        for t in FilmBorderTemplates.all {
            XCTAssertNoThrow(try t.validate(), t.id)
            let data = try JSONEncoder().encode(t)
            XCTAssertEqual(try JSONDecoder().decode(FilmBorderConfiguration.self, from: data), t, t.id)
        }
        XCTAssertTrue(String(data: try JSONEncoder().encode(FilmBorderTemplates.classicScan), encoding: .utf8)!.contains("\"#FAF8F3\""))
        XCTAssertEqual(BorderColor(hex: "#E9E4D8")?.hex, "#E9E4D8")
        XCTAssertNil(BorderColor(hex: "#12"))
    }

    func testValidationRejectsBadConfigurations() {
        var c = FilmBorderTemplates.classicScan
        c.version = 2; XCTAssertThrowsError(try c.validate(), "unknown schema version")
        c = FilmBorderTemplates.classicScan; c.layout.top = -0.01; XCTAssertThrowsError(try c.validate(), "negative width")
        c = FilmBorderTemplates.classicScan; c.layout.top = 0.6; c.layout.bottom = 0.5; XCTAssertThrowsError(try c.validate(), "top + bottom ≥ 1")
        c = FilmBorderTemplates.classicScan; c.layout.left = 0.3; c.layout.right = 0.25; XCTAssertThrowsError(try c.validate(), "opening below the minimum")
        c = FilmBorderTemplates.agedPaper; c.layout.paperInset = 0.2; XCTAssertThrowsError(try c.validate(), "paper inset larger than a border")
        // Intensities are clamped, not rejected.
        c = FilmBorderTemplates.classicScan; c.paper.textureStrength = 7; c.edge.burn = -1
        XCTAssertNoThrow(try c.validate())
        XCTAssertEqual(c.clamped().paper.textureStrength, 1); XCTAssertEqual(c.clamped().edge.burn, 0)
    }

    /// Normalized geometry: the same configuration gives the same proportions at any size; the photo is never stretched.
    func testLayoutIsProportionalAndNeverStretches() throws {
        for t in FilmBorderTemplates.all {
            let full = try FilmBorderLayout.compute(t, photoWidth: 4032, photoHeight: 3024)
            let small = try FilmBorderLayout.compute(t, photoWidth: 4032, photoHeight: 3024, outputLongEdge: 800)
            for (a, b) in [(full.opening.x / Double(full.canvasWidth), small.opening.x / Double(small.canvasWidth)),
                           (full.opening.y / Double(full.canvasHeight), small.opening.y / Double(small.canvasHeight)),
                           (full.opening.width / Double(full.canvasWidth), small.opening.width / Double(small.canvasWidth))] {
                XCTAssertEqual(a, b, accuracy: 0.003, t.id)
            }
            XCTAssertEqual(full.photo.width / full.photo.height, 4032.0 / 3024.0, accuracy: 1e-9, "\(t.id): no stretch")
            XCTAssertGreaterThanOrEqual(full.opening.x, 0); XCTAssertLessThanOrEqual(full.opening.maxX, Double(full.canvasWidth))
            if t.layout.fitMode == .aspectFit {
                XCTAssertEqual(full.photoScale, 1, accuracy: 1e-9, "\(t.id): export keeps the photo's pixels")
                XCTAssertEqual(full.cropFraction, 0, accuracy: 1e-9)
            }
        }
        // Without jitter / tilt the borders are exactly the configured fractions of the canvas.
        var fixed = FilmBorderTemplates.classicScan
        fixed.layout.jitter = 0; fixed.edge.rotation = 0
        fixed.layout.top = 0.012; fixed.layout.bottom = 0.016; fixed.layout.left = 0.009; fixed.layout.right = 0.011
        let l = try FilmBorderLayout.compute(fixed, photoWidth: 3000, photoHeight: 2000)
        XCTAssertEqual(l.opening.x / Double(l.canvasWidth), 0.009, accuracy: 0.001)
        XCTAssertEqual(l.opening.y / Double(l.canvasHeight), 0.016, accuracy: 0.001)
        XCTAssertEqual(1 - l.opening.maxY / Double(l.canvasHeight), 0.012, accuracy: 0.001)
        XCTAssertEqual(l.rotation, 0)
    }

    func testSizeMultiplierScalesAllEdgesTogether() throws {
        var c = FilmBorderTemplates.classicScan
        c.layout.sizeMultiplier = 2
        let i = c.insets
        XCTAssertEqual(i.top / i.bottom, 0.006 / 0.011, accuracy: 1e-6)
        XCTAssertEqual(i.left, 0.010, accuracy: 1e-6)
        let a = try FilmBorderLayout.compute(FilmBorderTemplates.classicScan, photoWidth: 3000, photoHeight: 2000)
        let b = try FilmBorderLayout.compute(c, photoWidth: 3000, photoHeight: 2000)
        XCTAssertGreaterThan(b.canvasWidth, a.canvasWidth)
        XCTAssertEqual(b.opening.width, a.opening.width, accuracy: 1, "the photo keeps its size, the border grows")
    }

    /// Instant cards follow the photo (user 2026-11-21: "nhiều khoảng trống"): wide card for landscape, mini for
    /// portrait, square for square; a normal phone photo is not cropped.
    func testInstantPrintPicksTheCardByOrientation() throws {
        let t = FilmBorderTemplates.instantPrint
        let land = try FilmBorderLayout.compute(t, photoWidth: 4000, photoHeight: 3000)
        XCTAssertGreaterThan(land.canvasWidth, land.canvasHeight, "wide card for a landscape photo")
        XCTAssertEqual(land.cropFraction, 0, accuracy: 0.001, "4:3 fits the wide card's range")
        let port = try FilmBorderLayout.compute(t, photoWidth: 3000, photoHeight: 4000)
        XCTAssertLessThan(port.canvasWidth, port.canvasHeight, "mini card for a portrait photo")
        XCTAssertEqual(port.cropFraction, 0, accuracy: 0.001)
        let sq = try FilmBorderLayout.compute(t, photoWidth: 3000, photoHeight: 3000)
        XCTAssertEqual(sq.opening.width, sq.opening.height, accuracy: 1)
        let pano = try FilmBorderLayout.compute(t, photoWidth: 6000, photoHeight: 2000)
        XCTAssertGreaterThan(pano.cropFraction, 0.3, "panorama is cropped to the wide card, and the record says so")
        for l in [land, port, sq] {
            let top = Double(l.canvasHeight) - l.opening.maxY
            XCTAssertGreaterThan(l.opening.y, 1.8 * top, "bottom margin is the wide one")
        }
    }

    /// Roll behaviour: per-photo jitter and tilt vary, roll-level choices (edge-print side, burn end) stay; the burn
    /// is strong on frames 1–2 and rare mid-roll.
    func testRollConsistency() throws {
        let base = FilmBorderTemplates.classicScan
        let a = try FilmBorderLayout.compute(base.seeded("f1"), photoWidth: 3000, photoHeight: 2000)
        let b = try FilmBorderLayout.compute(base.seeded("f2"), photoWidth: 3000, photoHeight: 2000)
        XCTAssertNotEqual(a.opening, b.opening, "borders vary per photo")
        XCTAssertLessThanOrEqual(abs(a.rotation), 0.3 * .pi / 180 + 1e-9)
        var film = FilmBorderTemplates.filmNegative
        film.render.rollSeed = 42; film.render.rollLength = 36
        var amounts: [Float] = []
        var ends = Set<[Int]>()
        for k in 1...36 {
            var c = film.seeded("frame-\(k)"); c.render.frameIndex = k
            let l = try FilmBorderLayout.compute(c, photoWidth: 3000, photoHeight: 2000)
            amounts.append(FilmBorderLayout.burnAmount(c))
            if FilmBorderLayout.burnAmount(c) > 0 { ends.insert(l.burnSides(c)) }
            XCTAssertEqual(FilmBorderLayout.frameNumber(c), k, "edge print shows the real frame number")
        }
        XCTAssertGreaterThan(amounts[0], 0.5); XCTAssertGreaterThan(amounts[1], 0.5)
        XCTAssertLessThanOrEqual(amounts[2..<35].filter { $0 > 0 }.count, 8, "mid-roll burns are rare")
        XCTAssertEqual(ends.count, 1, "same frame end burns for the whole roll")
        XCTAssertTrue(ends.first!.allSatisfy { $0 == 1 || $0 == 3 }, "landscape strip: burn on the frame ends only")
    }

    /// Film strip runs along the frame's long side: holes top / bottom for landscape, left / right for portrait.
    func testFilmStripFollowsTheFrame() throws {
        let t = FilmBorderTemplates.filmNegative
        let land = try FilmBorderLayout.compute(t, photoWidth: 3600, photoHeight: 2400)
        let holesL = land.sprocketHoles(t).holes
        XCTAssertGreaterThan(holesL.count, 10)
        XCTAssertTrue(holesL.allSatisfy { $0.maxY < land.opening.y || $0.y > land.opening.maxY }, "landscape: holes above / below")
        let port = try FilmBorderLayout.compute(t, photoWidth: 2400, photoHeight: 3600)
        XCTAssertFalse(port.filmHorizontal)
        let holesP = port.sprocketHoles(t).holes
        XCTAssertTrue(holesP.allSatisfy { $0.maxX < port.opening.x || $0.x > port.opening.maxX }, "portrait: holes left / right")
        // 35 mm: 4.75 mm perforation pitch on each side.
        XCTAssertEqual(Double(holesL.count / 2), Double(land.canvasWidth) / (Double(land.canvasHeight) / 35 * 4.75), accuracy: 1.5)
        XCTAssertTrue(land.sprocketHoles(FilmBorderTemplates.classicScan).holes.isEmpty, "no film edge, no holes")
    }

    /// Share canvas: exact Instagram aspect, the print fits whole inside the margins (never cropped or stretched),
    /// stories keep it out of Instagram's UI zones.
    func testShareCanvasNeverCropsThePrint() throws {
        for asp in ShareCanvas.Aspect.allCases {
            for (pw, ph) in [(2000, 1500), (1500, 2000), (2000, 2000), (3000, 1000)] {
                let s = ShareCanvas.instagram(asp)
                let l = try ShareCanvasLayout.compute(s, printWidth: pw, printHeight: ph)
                XCTAssertEqual(l.canvasWidth, asp.instagramSize.0); XCTAssertEqual(l.canvasHeight, asp.instagramSize.1)
                XCTAssertEqual(l.print.width / l.print.height, Double(pw) / Double(ph), accuracy: 1e-9, "no stretch")
                let m = Double(s.margin) * Double(l.canvasWidth) - 0.5
                XCTAssertGreaterThanOrEqual(l.print.x, m); XCTAssertLessThanOrEqual(l.print.maxX, Double(l.canvasWidth) - m)
                XCTAssertGreaterThanOrEqual(l.print.y, s.safeBottom * Double(l.canvasHeight) - 0.5, "\(asp) bottom safe zone")
                XCTAssertLessThanOrEqual(l.print.maxY, (1 - s.safeTop) * Double(l.canvasHeight) + 0.5, "\(asp) top safe zone")
            }
        }
        // Without a width the print keeps its pixels.
        let keep = try ShareCanvasLayout.compute(ShareCanvas(aspect: .portrait4x5), printWidth: 1500, printHeight: 2000)
        XCTAssertEqual(keep.scale, 1, accuracy: 1e-9)
        XCTAssertEqual(Double(keep.canvasWidth) / Double(keep.canvasHeight), 0.8, accuracy: 0.002)
        var bad = ShareCanvas(); bad.margin = 0.4
        XCTAssertThrowsError(try bad.validate())
    }

    func testOutlinesAreSeededAndStayInside() throws {
        for t in FilmBorderTemplates.all {
            let l = try FilmBorderLayout.compute(t, photoWidth: 3000, photoHeight: 2000)
            for pts in [l.paperOutline(t), l.openingOutline(t)] {
                XCTAssertGreaterThan(pts.count, 100)
                XCTAssertTrue(pts.allSatisfy { $0.x >= -0.5 && $0.y >= -0.5 && $0.x <= Double(l.canvasWidth) + 0.5 && $0.y <= Double(l.canvasHeight) + 0.5 }, t.id)
            }
            XCTAssertEqual(l.openingOutline(t), l.openingOutline(t), "same seed → same edge")
            var other = t; other.render.randomSeed &+= 1
            if t.edge.irregularity > 0 { XCTAssertNotEqual(l.openingOutline(t), l.openingOutline(other), "\(t.id): seed changes the edge") }
        }
        // The opening never leaves the paper.
        let t = FilmBorderTemplates.agedPaper
        let l = try FilmBorderLayout.compute(t, photoWidth: 3000, photoHeight: 2000)
        XCTAssertTrue(l.openingOutline(t).allSatisfy { $0.x > l.paper.x && $0.x < l.paper.maxX && $0.y > l.paper.y && $0.y < l.paper.maxY })
        // forFrame: stable per frame, roll seed shared, frame position set.
        let f3 = t.forFrame(rollID: "roll-1", frameID: "f3", index: 3, count: 36)
        XCTAssertEqual(f3, t.forFrame(rollID: "roll-1", frameID: "f3", index: 3, count: 36))
        XCTAssertEqual(f3.render.rollSeed, t.forFrame(rollID: "roll-1", frameID: "f9").render.rollSeed)
        XCTAssertNotEqual(f3.render.randomSeed, t.forFrame(rollID: "roll-1", frameID: "f9").render.randomSeed)
        XCTAssertEqual(f3.render.frameIndex, 3); XCTAssertEqual(f3.render.rollLength, 36)
        // seeded(key) is stable per key.
        XCTAssertEqual(t.seeded("roll-1/frame-3").render.randomSeed, t.seeded("roll-1/frame-3").render.randomSeed)
        XCTAssertNotEqual(t.seeded("roll-1/frame-3").render.randomSeed, t.seeded("roll-1/frame-4").render.randomSeed)
    }
}

#if canImport(CoreImage) && canImport(CoreText)
import CoreImage

extension FilmBorderTests {
    func photo(_ w: Int, _ h: Int) -> CIImage {
        // A colour ramp, so placement and colour are checkable.
        CIFilter(name: "CILinearGradient", parameters: [
            "inputPoint0": CIVector(x: 0, y: 0), "inputPoint1": CIVector(x: CGFloat(w), y: CGFloat(h)),
            "inputColor0": CIColor(red: 0.8, green: 0.2, blue: 0.1), "inputColor1": CIColor(red: 0.1, green: 0.3, blue: 0.9),
        ])!.outputImage!.cropped(to: CGRect(x: 0, y: 0, width: w, height: h))
    }

    func testNoiseFieldsAreZeroMeanUnitScale() throws {
        let r = Renderer()
        for (cells, sigma) in [(CGFloat(1600), CGFloat(1.3)), (90, 1.4), (28, 1.1), (60, 1.3)] {
            let f = FilmBorderRenderer.Fields(seed: 7, canvas: CGRect(x: 0, y: 0, width: 800, height: 600)).field(stream: 1, cells: cells, sigma: sigma)
            let img = try r.linearImage(f)
            let v = stride(from: 0, to: img.pixels.count, by: 3).map { Double(img.pixels[$0]) }
            let mean = v.reduce(0, +) / Double(v.count)
            let sd = sqrt(v.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(v.count))
            XCTAssertEqual(mean, 0, accuracy: 0.15, "cells \(cells)")   // coarse grids hold only a few hundred independent cells
            XCTAssertTrue((0.6...1.2).contains(sd), "cells \(cells): sd \(sd)")
        }
    }

    /// Same input + configuration + seed → identical pixels; another seed → a different border; the photo is
    /// placed without a colour transform (centre pixel unchanged when the edge effects are off).
    func testRenderIsDeterministicAndKeepsThePhoto() throws {
        let r = Renderer()
        let src = photo(600, 400)
        for t in FilmBorderTemplates.all {
            let a = try FilmBorderRenderer.render(src, configuration: t)
            let b = try FilmBorderRenderer.render(src, configuration: t)
            XCTAssertEqual(a.image.extent.size, CGSize(width: a.record.canvasSize[0], height: a.record.canvasSize[1]), t.id)
            let la = try r.linearImage(a.image), lb = try r.linearImage(b.image)
            XCTAssertEqual(la.pixels, lb.pixels, "\(t.id): deterministic")
            var other = t; other.render.randomSeed &+= 99
            let lc = try r.linearImage(try FilmBorderRenderer.render(src, configuration: other).image)
            XCTAssertNotEqual(la.pixels, lc.pixels, "\(t.id): seed matters")
        }
        // No colour transform on the photo: classic with every edge effect off, centre pixel vs the source.
        var clean = FilmBorderTemplates.classicScan
        clean.edge.irregularity = 0; clean.edge.darkening = 0; clean.edge.wear = 0; clean.edge.dust = 0
        clean.edge.rotation = 0; clean.edge.lift = 0; clean.edge.fringe = 0; clean.edge.gateLine = 0
        let out = try FilmBorderRenderer.render(src, configuration: clean)
        let o = out.record.photo
        let cx = Int(o.x + o.width / 2), cy = Int(o.y + o.height / 2)
        let got = try r.linearImage(out.image.cropped(to: CGRect(x: cx, y: cy, width: 1, height: 1))
            .transformed(by: CGAffineTransform(translationX: CGFloat(-cx), y: CGFloat(-cy))))
        let want = try r.linearImage(src.cropped(to: CGRect(x: 300, y: 200, width: 1, height: 1))
            .transformed(by: CGAffineTransform(translationX: -300, y: -200)))
        for k in 0..<3 { XCTAssertEqual(got.pixels[k], want.pixels[k], accuracy: 0.004) }
        XCTAssertTrue(out.record.notes.first!.hasPrefix("film border classic_scan v1"))
    }

    /// renderForShare: Instagram-sized output, the print's backdrop takes the share background, recipe notes the canvas.
    func testRenderForShare() throws {
        let sc = ShareCanvas.instagram(.portrait4x5, background: ShareCanvas.dark)
        let r = try FilmBorderRenderer.renderForShare(photo(1200, 800), configuration: FilmBorderTemplates.agedPaper, canvas: sc)
        XCTAssertEqual(r.image.extent.size, CGSize(width: 1080, height: 1350))
        XCTAssertEqual(r.record.shareCanvasSize, [1080, 1350])
        XCTAssertEqual(r.record.configuration.layout.backdrop, ShareCanvas.dark)
        XCTAssertEqual(r.record.share?.shadow, 0, "aged card already has its own contact shadow")
        XCTAssertTrue(r.record.notes.last!.hasPrefix("share canvas 4x5 1080x1350"))
        // Corner pixel = the share background (dark).
        let px = try Renderer().linearImage(r.image.cropped(to: CGRect(x: 0, y: 0, width: 1, height: 1)))
        XCTAssertLessThan(px.pixels[0], 0.05)
    }

    /// A preview (long edge 400) and an export of the same configuration have the same proportions.
    func testPreviewMatchesExportGeometry() throws {
        let t = FilmBorderTemplates.agedPaper
        let full = try FilmBorderRenderer.render(photo(1200, 800), configuration: t)
        let prev = try FilmBorderRenderer.render(photo(1200, 800), configuration: t, outputLongEdge: 400)
        XCTAssertEqual(Double(full.record.canvasSize[0]) / Double(full.record.canvasSize[1]),
                       Double(prev.record.canvasSize[0]) / Double(prev.record.canvasSize[1]), accuracy: 0.01)
        XCTAssertEqual(full.record.opening.x / Double(full.record.canvasSize[0]), prev.record.opening.x / Double(prev.record.canvasSize[0]), accuracy: 0.003)
        XCTAssertEqual(prev.record.canvasSize.max(), 400)
    }
}
#endif
