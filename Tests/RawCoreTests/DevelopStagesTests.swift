#if canImport(CoreImage)
import CoreImage
import XCTest
@testable import RawCore

/// Capture-time analysis stored next to the DNG, the two develop stages, and how often a file is opened.
final class DevelopStagesTests: XCTestCase {
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    func original() throws -> URL {
        let dir = Self.root.appendingPathComponent("originals")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        guard let n = names.filter({ $0.lowercased().hasSuffix(".dng") }).sorted().first else { throw XCTSkip("no DNGs in originals/") }
        return dir.appendingPathComponent(n)
    }

    func tempDir() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("rawcore-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: d) }
        return d
    }

    func maxDiff(_ a: CIImage, _ b: CIImage, _ r: Renderer) throws -> Float {
        let w = Int(min(a.extent.width, b.extent.width)), h = Int(min(a.extent.height, b.extent.height))
        let la = try r.linearImage(a, size: (w, h)), lb = try r.linearImage(b, size: (w, h))
        return zip(la.pixels, lb.pixels).map { abs($0 - $1) }.max() ?? 0
    }

    /// One filter per decode: file facts are read once and cached (was 7-9 opens for an analysis + render).
    func testOneFilterPerDecode() throws {
        let url = try original()
        let dev = Developer(plugins: .none)   // no EDR analysis decode, no highlightRecovery base decode
        let scale = try dev.decoder.scaleFactor(url: url, longEdge: 256)   // reads the file facts: 1 filter
        XCTAssertEqual(dev.decoder.filtersCreated, 1)
        _ = try dev.develop(url: url, settings: .explicit, auto: true, scaleFactor: scale)
        XCTAssertEqual(dev.decoder.filtersCreated, 1 + 2 + 1, "2 analysis decodes (scene-linear 512, Apple 1024) + 1 render, no extra inspect")
        _ = try dev.develop(url: url, settings: .explicit, auto: false, scaleFactor: scale)
        XCTAssertEqual(dev.decoder.filtersCreated, 5, "a second render of a known file opens only its own filter")
    }

    /// Stored analysis: JSON + mask round trip, used by develop as is (same pixels), re-made when it no longer fits.
    func testStoredAnalysisRoundTripAndReuse() throws {
        let url = try original()
        let dev = Developer()
        let an = try dev.analyze(url: url)
        let dir = try tempDir()
        try an.write(to: dir, renderer: dev.renderer)
        let back = try Developer.Analysis.read(from: dir)
        XCTAssertEqual(back.context, an.context)
        XCTAssertEqual(back.defaults, an.defaults)
        XCTAssertEqual(back.decoderVersion, an.decoderVersion)
        XCTAssertEqual(back.sourceFile, url.lastPathComponent)
        if let m = an.personMask {
            let stored = try XCTUnwrap(back.personMask, "mask written and read back")
            XCTAssertEqual(dev.renderer.areaMean(stored), dev.renderer.areaMean(m), accuracy: 0.01)
        }

        let scale = try dev.decoder.scaleFactor(url: url, longEdge: 256)
        var st = RenderSettings.explicit; st.stock = "warm400"
        let fresh = try dev.develop(url: url, settings: st, auto: true, scaleFactor: scale, analysis: an)
        let opens = dev.decoder.filtersCreated
        let stored = try dev.develop(url: url, settings: st, auto: true, scaleFactor: scale, analysis: back)
        XCTAssertTrue(stored.recipe.decisions.contains { $0.hasPrefix("stored analysis used") }, "\(stored.recipe.decisions)")
        XCTAssertLessThanOrEqual(dev.decoder.filtersCreated - opens, 2, "no analysis decodes when the stored one fits")
        XCTAssertLessThan(try maxDiff(stored.image, fresh.image, dev.renderer), 2e-3)

        var old = back; old.decoderVersion = "6"
        XCTAssertNotNil(old.staleReason(url: url, decoderVersion: try XCTUnwrap(an.decoderVersion), plugins: []))
        let redone = try dev.develop(url: url, settings: st, auto: true, scaleFactor: scale, analysis: old)
        XCTAssertTrue(redone.recipe.decisions.contains { $0.hasPrefix("stored analysis not used (decoder version 6") }, "\(redone.recipe.decisions)")
        var noSchema = back; noSchema.schema = nil
        XCTAssertNotNil(noSchema.staleReason(url: url, decoderVersion: try XCTUnwrap(an.decoderVersion), plugins: []))
    }

    /// The HEIC's histograms stored at analysis time replace the HEIC file: same cameraMatch decisions without it.
    func testStoredHEICHistogramsReplaceTheFile() throws {
        let docs = Self.root.appendingPathComponent("docs")
        let dirs = ((try? FileManager.default.contentsOfDirectory(atPath: docs.path)) ?? []).sorted().map { docs.appendingPathComponent($0) }
            .filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent("apple.heic").path)
                      && FileManager.default.fileExists(atPath: $0.appendingPathComponent("capture.dng").path) }
        guard let d = dirs.first else { throw XCTSkip("no device pairs in docs/") }
        let dng = d.appendingPathComponent("capture.dng"), heic = d.appendingPathComponent("apple.heic").path
        let dev = Developer()
        let scale = try dev.decoder.scaleFactor(url: dng, longEdge: 512)
        let plain = try dev.analyze(url: dng)
        var withFile = RenderSettings.explicit; withFile.cameraReference = heic
        let a = try dev.develop(url: dng, settings: withFile, auto: true, scaleFactor: scale, analysis: plain)

        let stored = try dev.analyze(url: dng, cameraReference: heic)
        XCTAssertEqual(stored.context.cameraReferenceHistogram?.count, stored.context.lumaHistogram?.count)
        XCTAssertEqual(stored.context.cameraReferenceHistogramFine?.count, CameraMatchPlugin.fineBins)
        let b = try dev.develop(url: dng, settings: .explicit, auto: true, scaleFactor: scale, analysis: stored)   // no HEIC path
        XCTAssertTrue(b.recipe.plugins.contains("cameraMatch"))
        XCTAssertTrue(b.recipe.decisions.contains { $0.contains("(stored analysis,") }, "\(b.recipe.decisions)")
        XCTAssertEqual(b.recipe.effective.exposure, a.recipe.effective.exposure, accuracy: 1e-4)
        XCTAssertEqual(b.recipe.effective.boostShadowAmount, a.recipe.effective.boostShadowAmount, accuracy: 1e-4)
        XCTAssertLessThan(try maxDiff(b.image, a.image, dev.renderer), 2e-3)
    }

    /// A base finished with another stock equals a full develop with that stock (no second decode needed).
    func testFinishBaseWithAnotherStock() throws {
        let url = try original()
        let dev = Developer()
        let an = try dev.analyze(url: url)
        let scale = try dev.decoder.scaleFactor(url: url, longEdge: 256)
        var warm = RenderSettings.explicit; warm.stock = "warm400"
        var night = RenderSettings.explicit; night.stock = "night800"
        var base = try dev.developBase(url: url, settings: warm, auto: true, scaleFactor: scale, analysis: an)
        let opens = dev.decoder.filtersCreated
        let first = try dev.finish(base)
        base.settings.stock = "night800"
        let relooked = try dev.finish(base)
        XCTAssertEqual(dev.decoder.filtersCreated, opens, "finishing never decodes")
        XCTAssertEqual(relooked.recipe.settings.stock, "night800")
        let full = try dev.develop(url: url, settings: night, auto: true, scaleFactor: scale, analysis: an)
        XCTAssertLessThan(try maxDiff(relooked.image, full.image, dev.renderer), 2e-3)
        XCTAssertGreaterThan(try maxDiff(relooked.image, first.image, dev.renderer), 0.01, "the stock really changed")
    }

    /// filmDevelop: no stock = no-op, `plugins = []` leaves the core untouched, a roll stock lowers sharpness and logs it,
    /// and finishing a base with another develop profile says so.
    func testFilmDevelopPlugin() throws {
        let url = try original()
        let dev = Developer()
        let an = try dev.analyze(url: url)
        let scale = try dev.decoder.scaleFactor(url: url, longEdge: 256)
        var plain = RenderSettings.explicit
        let none = try dev.developBase(url: url, settings: plain, auto: true, scaleFactor: scale, analysis: an)
        XCTAssertFalse(none.recipe.plugins.contains("filmDevelop"))
        XCTAssertFalse(none.recipe.decisions.contains { $0.contains("[filmDevelop]") })

        plain.stock = "rr-sao-mai-200"
        let on = try dev.developBase(url: url, settings: plain, auto: true, scaleFactor: scale, analysis: an)
        XCTAssertEqual(on.developedFor, "rr-sao-mai-200: iso<400")
        let d = on.recipe.defaults.sharpnessAmount
        if on.recipe.support.sharpness, d > 0.55 {
            XCTAssertLessThan(on.recipe.effective.sharpnessAmount, on.recipe.defaults.sharpnessAmount)
            XCTAssertTrue(on.recipe.decisions.contains { $0.hasPrefix("[filmDevelop] develop iso<400: sharpness") })
        }
        var off = plain; off.plugins = []
        let core = try dev.developBase(url: url, settings: off, auto: true, scaleFactor: scale, analysis: an)
        XCTAssertEqual(core.recipe.effective.sharpnessAmount, core.recipe.defaults.sharpnessAmount, "plugins = [] leaves Apple's sharpness")
        XCTAssertNil(core.developedFor)

        var b = on
        b.settings.stock = "rr-sao-hom-400"
        let out = try dev.finish(b)
        XCTAssertTrue(out.recipe.decisions.contains { $0.contains("base developed for rr-sao-mai-200: iso<400, finished as rr-sao-hom-400: iso400-1599") })
        let same = try dev.finish(on)
        XCTAssertFalse(same.recipe.decisions.contains { $0.contains("base developed for") })
    }

    /// Writes a .cube + manifest pair into a temp folder (the contract's own fixture, sha computed from the bytes).
    func libraryFixture(name: String = "testLook", route: String = "display", input: (String, String, String?) = ("srgb", "srgb", nil),
                        output: (String, String) = ("srgb", "srgb"), license: String = "MIT", sha: String? = nil,
                        lut: CubeLUT = BuiltInLook.warmNegative.lut()) throws -> URL {
        let dir = try tempDir()
        let cube = Data(lut.cubeText().utf8)
        try cube.write(to: dir.appendingPathComponent("\(name).cube"))
        let logCurve = input.2.map { "\"logCurve\": \"\($0)\"," } ?? ""
        let json = """
        {"schema": 1, "name": "\(name)", "file": "\(name).cube", "sha256": "\(sha ?? SHA256.hex(cube))",
         "input": {"primaries": "\(input.0)", "white": "D65", "transfer": "\(input.1)", \(logCurve) "domain": [0, 1]},
         "output": {"primaries": "\(output.0)", "white": "D65", "transfer": "\(output.1)", "referred": "display"},
         "toneBaked": true, "exposureAnchor": "unknown", "route": "\(route)",
         "source": {"author": "test", "url": "https://example.invalid", "version": "1"},
         "license": {"id": "\(license)", "redistributionInApp": "permitted"},
         "history": [{"date": "2026-11-10", "change": "fixture"}]}
        """
        try Data(json.utf8).write(to: dir.appendingPathComponent("\(name).manifest.json"))
        return dir
    }

    /// LUT library contract: a declared file loads on its route; wrong sha, empty fields, unsupported routes are
    /// rejected with the reason; licence and trademark problems block a release but not loading.
    func testLookContractAcceptsDeclaredAndRejectsBad() throws {
        XCTAssertEqual(SHA256.hex(Data("abc".utf8)), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(SHA256.hex(Data()), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")

        let ok = LookLibrary(directory: try libraryFixture())
        XCTAssertEqual(ok.entries.count, 1, "\(ok.checks)")
        XCTAssertEqual(ok.entries.first?.route, .display(.sRGB))
        XCTAssertEqual(ok.stocks.first?.lookColorSpace, .sRGB)
        XCTAssertTrue(ok.checks[0].releaseBlockers.isEmpty, "\(ok.checks[0].releaseBlockers)")

        func problems(_ dir: URL) -> [String] { LookLibrary(directory: dir).checks.first?.problems ?? ["no check"] }
        XCTAssertTrue(problems(try libraryFixture(sha: String(repeating: "0", count: 64))).contains { $0.hasPrefix("sha256 mismatch") })
        XCTAssertTrue(problems(try libraryFixture(route: "creative", input: ("ap1", "acescct", nil), output: ("ap1", "acescct"))).contains { $0.contains("not supported") })
        XCTAssertTrue(problems(try libraryFixture(route: "sceneToDisplay", input: ("srgb", "linear", nil))).contains { $0.contains("log-encoded input only") })
        XCTAssertTrue(problems(try libraryFixture(route: "sceneToDisplay", input: ("rec709", "log", "cineon"))).contains { $0.contains("cineon") })
        XCTAssertTrue(problems(try libraryFixture(input: ("displayP3", "srgb", nil))).contains { $0.contains("same supported primaries") })
        XCTAssertEqual(LookLibrary(directory: try libraryFixture(route: "sceneToDisplay", input: ("rec2020", "log", "appleLog"))).entries.first?.route,
                       .log(.appleLog, primaries: .rec2020))

        let gpl = LookLibrary(directory: try libraryFixture(name: "portra_test", license: "GPL-3.0"))
        XCTAssertEqual(gpl.entries.count, 1, "licence/trademark do not block loading")
        XCTAssertTrue(gpl.checks[0].releaseBlockers.contains { $0.contains("GPL-3.0") })
        XCTAssertTrue(gpl.checks[0].releaseBlockers.contains { $0.contains("portra") })

        // Bundled Looks/: only files that pass become stocks; the rest are reported, never loaded.
        for c in LookLibrary.bundled.checks where !c.isUsable { XCTAssertFalse(FilmStock.bundled.contains { $0.name == c.name }, c.name) }
    }

    /// Log curves put mid grey where their specs do; the composite cube is monotone on grey.
    func testLogCurvesAndComposite() throws {
        XCTAssertEqual(LogCurve.appleLog.encode(0.18), 0.488, accuracy: 0.005)
        XCTAssertEqual(LogCurve.sLog3.encode(0.18), 0.410, accuracy: 0.005)
        XCTAssertEqual(LogCurve.logC3.encode(0.18), 0.391, accuracy: 0.005)
        XCTAssertEqual(LogCurve.vLog.encode(0.18), 0.423, accuracy: 0.005)
        let lut = BuiltInLook.warmNegative.lut()
        let c = LogLook.composite(lut, curve: .appleLog, size: 17)
        var last: Float = -1
        for i in 0..<17 {
            let v = Float(i) / 16, o = c.apply(SIMD3(repeating: v))
            let y = 0.2 * o.x + 0.7 * o.y + 0.1 * o.z
            XCTAssertGreaterThanOrEqual(y, last - 1e-4, "grey ramp monotone at \(v)")
            last = y
        }
    }

    /// A LOG stock goes through the logLook plugin; unplugged, the core applies it to the display base and says so.
    func testLogLookPluginAndFallback() throws {
        let url = try original()
        let dev = Developer()
        let scale = try dev.decoder.scaleFactor(url: url, longEdge: 256)
        let an = try dev.analyze(url: url)
        let lib = LookLibrary(directory: try libraryFixture(name: "testLogLook", route: "sceneToDisplay", input: ("rec2020", "log", "appleLog")))
        FilmStock.register(lib.stocks, library: lib)
        var st = RenderSettings.explicit; st.stock = "testLogLook"
        let withPlugin = try dev.develop(url: url, settings: st, auto: true, scaleFactor: scale, analysis: an)
        XCTAssertTrue(withPlugin.recipe.plugins.contains("logLook"))
        XCTAssertTrue(withPlugin.recipe.decisions.contains { $0.hasPrefix("[logLook] testLogLook") }, "\(withPlugin.recipe.decisions)")
        XCTAssertTrue(withPlugin.recipe.decisions.contains { $0.hasPrefix("look testLogLook:") && $0.contains("sha") }, "recipe records the manifest")
        var off = st; off.plugins = ["highlightRecovery", "cameraMatch", "vignette"]
        let fallback = try dev.develop(url: url, settings: off, auto: true, scaleFactor: scale, analysis: an)
        XCTAssertFalse(fallback.recipe.plugins.contains("logLook"))
        XCTAssertTrue(fallback.recipe.decisions.contains { $0.contains("no plugin applied it") })
        XCTAssertGreaterThan(try maxDiff(withPlugin.image, fallback.image, dev.renderer), 0.02)
        var classic = RenderSettings.explicit; classic.stock = "warm400"
        let warm = try dev.develop(url: url, settings: classic, auto: true, scaleFactor: scale, analysis: an)
        XCTAssertFalse(warm.recipe.plugins.contains("logLook"), "display looks never go through logLook")
    }

    /// MoodRoll's .mrlut format round-trips within half precision; .cube text round-trips exactly to 6 decimals.
    func testMrlutAndCubeWriterRoundTrip() throws {
        XCTAssertEqual(LUTBinaryFormat.floatToHalf(0), 0)
        XCTAssertEqual(LUTBinaryFormat.floatToHalf(1), 0x3C00)
        XCTAssertEqual(LUTBinaryFormat.floatToHalf(0.5), 0x3800)
        for v: Float in [0, 1e-6, 0.000123, 0.25, 0.333333, 0.999, 1] {
            XCTAssertEqual(LUTBinaryFormat.halfToFloat(LUTBinaryFormat.floatToHalf(v)), v, accuracy: max(v * 0.0005, 3e-8))
        }
        let lut = BuiltInLook.warmNegative.lut()
        let packed = try LUTBinaryFormat.encode(lut)
        XCTAssertEqual(packed.count, 8 + 33 * 33 * 33 * 6)
        let back = try LUTBinaryFormat.decode(packed)
        XCTAssertLessThan(zip(lut.rgba, back.rgba).map { abs($0 - $1) }.max() ?? 1, 0.00025)
        let text = try CubeLUT.parse(lut.cubeText())
        XCTAssertLessThan(zip(lut.rgba, text.rgba).map { abs($0 - $1) }.max() ?? 1, 1e-6)
        XCTAssertThrowsError(try LUTBinaryFormat.decode(Data([1, 2, 3])))
    }
}
#endif
