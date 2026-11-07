#if canImport(CoreImage)
import CoreImage
import Foundation
import ImageIO

/// Core Image rendering: look application, export (HEIC 10-bit / PNG 16-bit / JPEG) and
/// read-back to `LinearImage` for metrics. One shared CIContext, linear extended Display P3 working space.
public final class Renderer: @unchecked Sendable {
    public let context: CIContext
    public static let linearP3 = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!
    public static let displayP3 = CGColorSpace(name: CGColorSpace.displayP3)!

    public init() {
        context = CIContext(options: [
            .workingColorSpace: Renderer.linearP3,
            .workingFormat: CIFormat.RGBAh,
            .cacheIntermediates: false,
        ])
    }

    /// Apply a look LUT (display-referred, encoded Display P3 domain) at the given intensity.
    public func applyLook(_ lut: CubeLUT, to image: CIImage, intensity: Float) throws -> CIImage {
        guard intensity > 0 else { return image }
        let data = lut.rgba.withUnsafeBufferPointer { Data(buffer: $0) }
        guard let cube = CIFilter(name: "CIColorCubeWithColorSpace", parameters: [
            kCIInputImageKey: image.clampedToExtent(),
            "inputCubeDimension": lut.size,
            "inputCubeData": data,
            "inputColorSpace": Renderer.displayP3,
        ])?.outputImage?.cropped(to: image.extent) else { throw RawCoreError.renderFailed("CIColorCubeWithColorSpace failed") }
        guard intensity < 1 else { return cube }
        guard let mixed = CIFilter(name: "CIDissolveTransition", parameters: [
            kCIInputImageKey: image, kCIInputTargetImageKey: cube, kCIInputTimeKey: intensity,
        ])?.outputImage else { throw RawCoreError.renderFailed("CIDissolveTransition failed") }
        return mixed.cropped(to: image.extent)
    }

    /// Map an EDR image whose highlights reach `sourceHeadroom` (× SDR white) into SDR, keeping mid-tones.
    /// Uses Core Image's CIToneMapHeadroom where available (macOS 15 / iOS 18); otherwise the image
    /// is returned unchanged and the reason is reported for the recipe.
    public func toneMapHeadroom(_ image: CIImage, sourceHeadroom: Float) -> (CIImage, String) {
        guard let f = CIFilter(name: "CIToneMapHeadroom") else { return (image, "CIToneMapHeadroom unavailable on this OS: not applied") }
        let keys = f.inputKeys
        guard keys.contains("inputSourceHeadroom"), keys.contains("inputTargetHeadroom") else {
            return (image, "CIToneMapHeadroom has unexpected inputs \(keys): not applied")
        }
        f.setValue(image, forKey: kCIInputImageKey)
        f.setValue(sourceHeadroom, forKey: "inputSourceHeadroom")
        f.setValue(Float(1), forKey: "inputTargetHeadroom")
        guard let out = f.outputImage else { return (image, "CIToneMapHeadroom produced no image: not applied") }
        return (out.cropped(to: image.extent), String(format: "CIToneMapHeadroom %.2f -> 1.00", sourceHeadroom))
    }

    /// Local contrast for highlights: CIUnsharpMask with a large radius, blended in through a luminance mask
    /// that ramps from linear Y 0.30 (0) to 0.75 (1). Radius scales with the image so previews match full res.
    public func highlightClarity(_ image: CIImage, amount: Float) -> CIImage {
        guard amount > 0 else { return image }
        let ext = image.extent
        let radius = max(ext.width, ext.height) * 0.012
        let w = ColorMath.p3LuminanceWeights
        let lumaVec = CIVector(x: CGFloat(w.r), y: CGFloat(w.g), z: CGFloat(w.b), w: 0)
        guard let usm = CIFilter(name: "CIUnsharpMask", parameters: [
            kCIInputImageKey: image.clampedToExtent(), kCIInputRadiusKey: radius, kCIInputIntensityKey: amount,
        ])?.outputImage?.cropped(to: ext) else { return image }
        let gain: CGFloat = 1 / 0.45, bias: CGFloat = -0.30 / 0.45
        let mask = image
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: lumaVec.x * gain, y: lumaVec.y * gain, z: lumaVec.z * gain, w: 0),
                "inputGVector": CIVector(x: lumaVec.x * gain, y: lumaVec.y * gain, z: lumaVec.z * gain, w: 0),
                "inputBVector": CIVector(x: lumaVec.x * gain, y: lumaVec.y * gain, z: lumaVec.z * gain, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                "inputBiasVector": CIVector(x: bias, y: bias, z: bias, w: 0),
            ])
            .applyingFilter("CIColorClamp")
        return usm.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: image, kCIInputMaskImageKey: mask,
        ]).cropped(to: ext)
    }

    /// Blend `recovered` over `base` through a soft mask built from base luminance (linear 0.80 → 0.97),
    /// blurred by 0.4 % of the long edge so the transition has no visible seam.
    public func blendRecoveredHighlights(recovered: CIImage, base: CIImage) -> CIImage {
        let ext = base.extent
        let w = ColorMath.p3LuminanceWeights
        let lo: CGFloat = 0.80, hi: CGFloat = 0.97
        let gain = 1 / (hi - lo), bias = -lo / (hi - lo)
        let row = CIVector(x: CGFloat(w.r) * gain, y: CGFloat(w.g) * gain, z: CGFloat(w.b) * gain, w: 0)
        let mask = base
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": row, "inputGVector": row, "inputBVector": row,
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                "inputBiasVector": CIVector(x: bias, y: bias, z: bias, w: 0),
            ])
            .applyingFilter("CIColorClamp")
            .clampedToExtent()
            .applyingGaussianBlur(sigma: Double(max(ext.width, ext.height) * 0.004))
            .cropped(to: ext)
        return recovered.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: base, kCIInputMaskImageKey: mask,
        ]).cropped(to: ext)
    }

    public func resolveLook(_ name: String?) throws -> CubeLUT? {
        guard let name, !name.isEmpty else { return nil }
        if let builtIn = BuiltInLook(rawValue: name) { return builtIn.lut() }
        return try CubeLUT.load(URL(fileURLWithPath: name))
    }

    public enum Format: String, CaseIterable, Sendable { case heic10, png16, jpeg }

    public func export(_ image: CIImage, format: Format, quality: Double = 0.92) throws -> Data {
        let opts: [CIImageRepresentationOption: Any] = [
            CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): quality,
        ]
        let data: Data?
        switch format {
        case .heic10: data = try context.heif10Representation(of: image, colorSpace: Renderer.displayP3, options: opts)
        case .png16: data = context.pngRepresentation(of: image, format: .RGBA16, colorSpace: Renderer.displayP3, options: [:])
        case .jpeg: data = context.jpegRepresentation(of: image, colorSpace: Renderer.displayP3, options: opts)
        }
        guard let data else { throw RawCoreError.renderFailed("export \(format.rawValue) failed") }
        return data
    }

    /// Render to linear Display P3 floats. `size` crops from the extent origin (to align two renders).
    public func linearImage(_ image: CIImage, size: (Int, Int)? = nil) throws -> LinearImage {
        let ext = image.extent.integral
        let w = size?.0 ?? Int(ext.width), h = size?.1 ?? Int(ext.height)
        guard w > 0, h > 0, w <= Int(ext.width), h <= Int(ext.height) else {
            throw RawCoreError.renderFailed("bad render size \(w)x\(h) for extent \(ext)")
        }
        var rgba = [Float](repeating: 0, count: w * h * 4)
        rgba.withUnsafeMutableBytes { buf in
            context.render(image, toBitmap: buf.baseAddress!, rowBytes: w * 16,
                           bounds: CGRect(x: ext.minX, y: ext.minY, width: CGFloat(w), height: CGFloat(h)),
                           format: .RGBAf, colorSpace: Renderer.linearP3)
        }
        var rgb = [Float](repeating: 0, count: w * h * 3)
        for i in 0..<(w * h) {
            rgb[i * 3] = rgba[i * 4]; rgb[i * 3 + 1] = rgba[i * 4 + 1]; rgb[i * 3 + 2] = rgba[i * 4 + 2]
        }
        return LinearImage(width: w, height: h, pixels: rgb)
    }

    public func cgImage(_ image: CIImage) -> CGImage? {
        context.createCGImage(image, from: image.extent.integral, format: .RGBA8, colorSpace: Renderer.displayP3)
    }
}
#endif
