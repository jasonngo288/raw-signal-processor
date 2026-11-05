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
