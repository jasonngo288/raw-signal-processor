#if canImport(CoreImage)
import CoreImage
import Foundation
import ImageIO

/// Thin, explicit wrapper over CIRAWFilter. Every render returns a `DecodeRecipe` with the decoder
/// version and the effective value of every parameter, so nothing depends on hidden defaults.
public struct RawDecoder {
    public struct Output {
        public var image: CIImage
        public var recipe: DecodeRecipe
    }

    /// What a file says about itself (versions, size, metadata, Apple's per-version defaults). Read once per file and
    /// reused, so a develop opens a `CIRAWFilter` only for the decodes it renders (a fresh filter per decode).
    public struct FileInfo: @unchecked Sendable {
        public var supported: [String]
        public var defaultVersion: String
        public var nativeSize: CGSize
        public var properties: [AnyHashable: Any]
        var perVersion: [String: (defaults: DecodeParameters, support: DecoderSupport)]
    }

    final class InfoCache: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String: FileInfo] = [:]
        private(set) var filtersCreated = 0
        func get(_ k: String) -> FileInfo? { lock.lock(); defer { lock.unlock() }; return items[k] }
        func set(_ k: String, _ v: FileInfo) {
            lock.lock(); defer { lock.unlock() }
            if items.count >= 64 { items.removeAll() }   // a roll is ≤ 36 files; keep memory bounded
            items[k] = v
        }
        func countFilter() { lock.lock(); filtersCreated += 1; lock.unlock() }
    }

    let cache = InfoCache()

    public init() {}

    /// Number of `CIRAWFilter`s this decoder has created (tests and benches count opens with it).
    public var filtersCreated: Int { cache.filtersCreated }

    /// Cache key: path + size + modification date, so a replaced file is never served stale facts.
    static func key(_ url: URL) -> String {
        let a = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (a?[.size] as? NSNumber)?.int64Value ?? -1
        let date = (a?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\(url.standardizedFileURL.path)|\(size)|\(date)"
    }

    func makeFilter(_ url: URL) throws -> CIRAWFilter {
        guard let filter = CIRAWFilter(imageURL: url) else { throw RawCoreError.unsupportedRaw(url.path) }
        cache.countFilter()
        return filter
    }

    /// File facts, from the cache or from one filter (which also yields the defaults of the OS default version).
    public func info(url: URL) throws -> FileInfo {
        let k = Self.key(url)
        if let i = cache.get(k) { return i }
        let f = try makeFilter(url)
        let v = f.decoderVersion.rawValue
        let i = FileInfo(supported: f.supportedDecoderVersions.map(\.rawValue), defaultVersion: v, nativeSize: f.nativeSize,
                         properties: f.properties, perVersion: [v: (Self.read(f), Self.support(f))])
        cache.set(k, i)
        return i
    }

    /// A fresh filter on `version` (nil = OS default) with Apple's defaults for it, recorded in the cache.
    func filter(url: URL, version: String?) throws -> (filter: CIRAWFilter, defaults: DecodeParameters, support: DecoderSupport, version: String, supported: [String]) {
        var i = try info(url: url)
        if let v = version, !i.supported.contains(v) { throw RawCoreError.unsupportedDecoderVersion(requested: v, supported: i.supported) }
        let f = try makeFilter(url)
        if let v = version { f.decoderVersion = CIRAWDecoderVersion(rawValue: v) }
        let used = f.decoderVersion.rawValue
        if let known = i.perVersion[used] { return (f, known.defaults, known.support, used, i.supported) }
        let d = Self.read(f), s = Self.support(f)   // read before anything is written to this filter
        i.perVersion[used] = (d, s)
        cache.set(Self.key(url), i)
        return (f, d, s, used, i.supported)
    }

    /// Open the file and return the filter plus what Apple would use by default.
    public func inspect(url: URL, decoderVersion: String? = nil) throws -> (filter: CIRAWFilter, defaults: DecodeParameters,
                                                                             support: DecoderSupport, version: String, supported: [String]) {
        try filter(url: url, version: decoderVersion)
    }

    /// The decoder version a non-`appleDefault` render of this file will use (requested, else DecoderPolicy).
    public func pinnedVersion(url: URL, requested: String?) throws -> String {
        let supported = try info(url: url).supported
        if let r = requested { return r }
        guard let v = DecoderPolicy.pick(supported: supported) else {
            throw RawCoreError.unsupportedDecoderVersion(requested: "policy \(DecoderPolicy.preferred)", supported: supported)
        }
        return v
    }

    public func decode(url: URL, settings: RenderSettings, scaleFactor: Float = 1, decisions: [String] = []) throws -> Output {
        try settings.validate()
        let versionSource: String
        let requested: String?
        if settings.mode == .appleDefault {
            requested = settings.decoderVersion
            versionSource = settings.decoderVersion != nil ? "requested" : "Apple default"
        } else {
            // Pin the version: requested, else the fixed DecoderPolicy list, never "whatever this OS defaults to".
            requested = try pinnedVersion(url: url, requested: settings.decoderVersion)
            versionSource = settings.decoderVersion != nil ? "requested" : "policy"
        }
        let (filter, defaults, support, version, supported) = try self.filter(url: url, version: requested)
        if settings.mode != .appleDefault {
            Self.write(defaults.applying(settings), to: filter, support: support)
            if settings.ccm != nil || settings.linearExposureEV != nil {
                let base = settings.ccm ?? [1, 0, 0, 0, 1, 0, 0, 0, 1]
                let gain = Float(pow(2.0, Double(settings.linearExposureEV ?? 0)))
                filter.linearSpaceFilter = Self.matrixFilter(base.map { $0 * gain })
            }
        }
        filter.scaleFactor = min(max(scaleFactor, 0.01), 1)
        guard let image = filter.outputImage else { throw RawCoreError.renderFailed("CIRAWFilter produced no image for \(url.lastPathComponent)") }

        let props = filter.properties
        let exif = props[kCGImagePropertyExifDictionary as String] as? [String: Any]
        let tiff = props[kCGImagePropertyTIFFDictionary as String] as? [String: Any]
        let camera = [tiff?[kCGImagePropertyTIFFMake as String] as? String, tiff?[kCGImagePropertyTIFFModel as String] as? String]
            .compactMap { $0 }.joined(separator: " ")
        let iso = (exif?[kCGImagePropertyExifISOSpeedRatings as String] as? [Double])?.first
        let exposureTime = exif?[kCGImagePropertyExifExposureTime as String] as? Double

        var recipe = DecodeRecipe(
            file: url.lastPathComponent, settings: settings, decoderVersion: version, supportedDecoderVersions: supported,
            defaults: defaults, effective: Self.read(filter), support: support,
            nativeSize: [Int(filter.nativeSize.width), Int(filter.nativeSize.height)], scaleFactor: filter.scaleFactor,
            camera: camera.isEmpty ? nil : camera, iso: iso, exposureTime: exposureTime, decisions: decisions)
        recipe.decoderVersionSource = versionSource
        return Output(image: image, recipe: recipe)
    }

    /// Scale factor that makes the long edge of the (oriented) output close to `longEdge` pixels.
    public func scaleFactor(url: URL, longEdge: Int) throws -> Float {
        let s = try info(url: url).nativeSize
        return min(1, Float(longEdge) / Float(max(s.width, s.height)))
    }

    static func read(_ f: CIRAWFilter) -> DecodeParameters {
        DecodeParameters(
            exposure: f.exposure, baselineExposure: f.baselineExposure, shadowBias: f.shadowBias,
            boostAmount: f.boostAmount, boostShadowAmount: f.boostShadowAmount, localToneMapAmount: f.localToneMapAmount,
            sharpnessAmount: f.sharpnessAmount, contrastAmount: f.contrastAmount, detailAmount: f.detailAmount,
            luminanceNoiseReductionAmount: f.luminanceNoiseReductionAmount, colorNoiseReductionAmount: f.colorNoiseReductionAmount,
            moireReductionAmount: f.moireReductionAmount, extendedDynamicRangeAmount: f.extendedDynamicRangeAmount,
            lensCorrection: f.isLensCorrectionEnabled, gamutMapping: f.isGamutMappingEnabled,
            neutralTemperature: f.neutralTemperature, neutralTint: f.neutralTint)
    }

    static func support(_ f: CIRAWFilter) -> DecoderSupport {
        DecoderSupport(
            localToneMap: f.isLocalToneMapSupported, sharpness: f.isSharpnessSupported, contrast: f.isContrastSupported,
            detail: f.isDetailSupported, luminanceNoiseReduction: f.isLuminanceNoiseReductionSupported,
            colorNoiseReduction: f.isColorNoiseReductionSupported, moireReduction: f.isMoireReductionSupported,
            lensCorrection: f.isLensCorrectionSupported, maxExtendedDynamicRange: 2)  // documented range 0...2 (1 = default EDR)
    }

    /// Write every parameter. Unsupported ones are left alone (the recipe's `effective` re-reads the filter).
    static func write(_ p: DecodeParameters, to f: CIRAWFilter, support s: DecoderSupport) {
        f.exposure = p.exposure
        f.baselineExposure = p.baselineExposure
        f.shadowBias = p.shadowBias
        f.boostAmount = p.boostAmount
        f.boostShadowAmount = p.boostShadowAmount
        if s.localToneMap { f.localToneMapAmount = p.localToneMapAmount }
        if s.sharpness { f.sharpnessAmount = p.sharpnessAmount }
        if s.contrast { f.contrastAmount = p.contrastAmount }
        if s.detail { f.detailAmount = p.detailAmount }
        if s.luminanceNoiseReduction { f.luminanceNoiseReductionAmount = p.luminanceNoiseReductionAmount }
        if s.colorNoiseReduction { f.colorNoiseReductionAmount = p.colorNoiseReductionAmount }
        if s.moireReduction { f.moireReductionAmount = p.moireReductionAmount }
        f.extendedDynamicRangeAmount = p.extendedDynamicRangeAmount
        if s.lensCorrection { f.isLensCorrectionEnabled = p.lensCorrection }
        f.isGamutMappingEnabled = p.gamutMapping
        // Only touch white balance if it changed: a temperature/tint round trip is not exact.
        if p.neutralTemperature != f.neutralTemperature { f.neutralTemperature = p.neutralTemperature }
        if p.neutralTint != f.neutralTint { f.neutralTint = p.neutralTint }
    }

    static func matrixFilter(_ m: [Float]) -> CIFilter? {
        let f = CIFilter(name: "CIColorMatrix")
        f?.setValue(CIVector(x: CGFloat(m[0]), y: CGFloat(m[1]), z: CGFloat(m[2]), w: 0), forKey: "inputRVector")
        f?.setValue(CIVector(x: CGFloat(m[3]), y: CGFloat(m[4]), z: CGFloat(m[5]), w: 0), forKey: "inputGVector")
        f?.setValue(CIVector(x: CGFloat(m[6]), y: CGFloat(m[7]), z: CGFloat(m[8]), w: 0), forKey: "inputBVector")
        f?.setValue(CIVector(x: 0, y: 0, z: 0, w: 1), forKey: "inputAVector")
        f?.setValue(CIVector(x: 0, y: 0, z: 0, w: 0), forKey: "inputBiasVector")
        return f
    }
}
#endif
