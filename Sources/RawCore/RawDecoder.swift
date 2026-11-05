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

    public init() {}

    /// Open the file and return the filter plus what Apple would use by default.
    public func inspect(url: URL, decoderVersion: String? = nil) throws -> (filter: CIRAWFilter, defaults: DecodeParameters,
                                                                             support: DecoderSupport, version: String, supported: [String]) {
        guard let filter = CIRAWFilter(imageURL: url) else { throw RawCoreError.unsupportedRaw(url.path) }
        let supported = filter.supportedDecoderVersions.map(\.rawValue)
        if let v = decoderVersion {
            guard supported.contains(v) else { throw RawCoreError.unsupportedDecoderVersion(requested: v, supported: supported) }
            filter.decoderVersion = CIRAWDecoderVersion(rawValue: v)
        }
        return (filter, Self.read(filter), Self.support(filter), filter.decoderVersion.rawValue, supported)
    }

    public func decode(url: URL, settings: RenderSettings, scaleFactor: Float = 1, decisions: [String] = []) throws -> Output {
        try settings.validate()
        let (filter, defaults, support, version, supported) = try inspect(url: url, decoderVersion: settings.decoderVersion)
        var effective = defaults
        if settings.mode != .appleDefault {
            // Pin the version even when it equals the default, so the recipe is the whole truth.
            filter.decoderVersion = CIRAWDecoderVersion(rawValue: version)
            effective = defaults.applying(settings)
            Self.write(effective, to: filter, support: support)
            if let m = settings.ccm { filter.linearSpaceFilter = Self.matrixFilter(m) }
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

        let recipe = DecodeRecipe(
            file: url.lastPathComponent, settings: settings, decoderVersion: version, supportedDecoderVersions: supported,
            defaults: defaults, effective: Self.read(filter), support: support,
            nativeSize: [Int(filter.nativeSize.width), Int(filter.nativeSize.height)], scaleFactor: filter.scaleFactor,
            camera: camera.isEmpty ? nil : camera, iso: iso, exposureTime: exposureTime, decisions: decisions)
        _ = effective
        return Output(image: image, recipe: recipe)
    }

    /// Scale factor that makes the long edge of the (oriented) output close to `longEdge` pixels.
    public func scaleFactor(url: URL, longEdge: Int) throws -> Float {
        guard let filter = CIRAWFilter(imageURL: url) else { throw RawCoreError.unsupportedRaw(url.path) }
        let s = filter.nativeSize
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
