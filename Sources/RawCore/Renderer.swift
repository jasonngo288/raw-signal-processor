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
    public static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    public func applyLook(_ lut: CubeLUT, to image: CIImage, intensity: Float, colorSpace: LookColorSpace = .displayP3) throws -> CIImage {
        guard intensity > 0 else { return image }
        let data = lut.rgba.withUnsafeBufferPointer { Data(buffer: $0) }
        guard let cube = CIFilter(name: "CIColorCubeWithColorSpace", parameters: [
            kCIInputImageKey: image.clampedToExtent(),
            "inputCubeDimension": lut.size,
            "inputCubeData": data,
            "inputColorSpace": colorSpace == .sRGB ? Renderer.sRGB : Renderer.displayP3,
        ])?.outputImage?.cropped(to: image.extent) else { throw RawCoreError.renderFailed("CIColorCubeWithColorSpace failed") }
        guard intensity < 1 else { return cube }
        guard let mixed = CIFilter(name: "CIDissolveTransition", parameters: [
            kCIInputImageKey: image, kCIInputTargetImageKey: cube, kCIInputTimeKey: intensity,
        ])?.outputImage else { throw RawCoreError.renderFailed("CIDissolveTransition failed") }
        return mixed.cropped(to: image.extent)
    }

    /// `amount` of the way from `base` to `target` (CIDissolveTransition); 0 = base, 1 = target.
    public func dissolve(from base: CIImage, to target: CIImage, amount: Float) -> CIImage {
        if amount >= 1 { return target.cropped(to: base.extent) }
        if amount <= 0 { return base }
        return (CIFilter(name: "CIDissolveTransition", parameters: [
            kCIInputImageKey: base, kCIInputTargetImageKey: target, kCIInputTimeKey: amount,
        ])?.outputImage ?? target).cropped(to: base.extent)
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

    /// Same as `toneMapHeadroom`, plus whether the tone map really ran.
    public func toneMapHeadroomChecked(_ image: CIImage, sourceHeadroom: Float) -> (CIImage, String, Bool) {
        let (out, how) = toneMapHeadroom(image, sourceHeadroom: sourceHeadroom)
        return (out, how, !how.contains("not applied"))
    }

    /// Roadmap "skin / subject protection": on people, hold back `strength` of the look.
    /// `mask` is the Vision person mask at any size; it is scaled to the image and softened.
    public func protectSkin(looked: CIImage, base: CIImage, mask: CIImage, strength: Float) -> CIImage {
        guard strength > 0 else { return looked }
        let ext = looked.extent
        let m = mask.extent
        guard m.width > 0, m.height > 0 else { return looked }
        let scaled = mask
            .transformed(by: CGAffineTransform(translationX: -m.minX, y: -m.minY))
            .transformed(by: CGAffineTransform(scaleX: ext.width / m.width, y: ext.height / m.height))
            .transformed(by: CGAffineTransform(translationX: ext.minX, y: ext.minY))
            .clampedToExtent()
            .applyingGaussianBlur(sigma: Double(min(ext.width, ext.height)) * 0.004)
            .cropped(to: ext)
        guard let held = CIFilter(name: "CIDissolveTransition", parameters: [
            kCIInputImageKey: looked, kCIInputTargetImageKey: base, kCIInputTimeKey: strength,
        ])?.outputImage else { return looked }
        return held.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: looked, kCIInputMaskImageKey: scaled,
        ]).cropped(to: ext)
    }

    static let linearGray = CGColorSpace(name: CGColorSpace.linearGray)!

    /// A grey mask image (row 0 = top) from 0...1 values: the stored `sky-mask.png` is the same 8-bit linear grey.
    public func maskImage(_ values: [Float], width: Int, height: Int) -> CIImage {
        let bytes = values.map { UInt8(min(max($0, 0), 1) * 255 + 0.5) }
        return CIImage(bitmapData: Data(bytes), bytesPerRow: width, size: CGSize(width: width, height: height),
                       format: .L8, colorSpace: Renderer.linearGray)
    }

    /// `foreground` where `mask` is 1, `background` where it is 0 (CIBlendWithMask). The mask is any size, scaled to
    /// the image and feathered by `feather` of the short edge.
    public func blend(_ foreground: CIImage, over background: CIImage, mask: CIImage, feather: Double = 0.003) -> CIImage {
        let ext = background.extent, m = mask.extent
        guard m.width > 0, m.height > 0 else { return background }
        let scaled = mask
            .transformed(by: CGAffineTransform(translationX: -m.minX, y: -m.minY))
            .transformed(by: CGAffineTransform(scaleX: ext.width / m.width, y: ext.height / m.height))
            .transformed(by: CGAffineTransform(translationX: ext.minX, y: ext.minY))
            .clampedToExtent()
            .applyingGaussianBlur(sigma: Double(min(ext.width, ext.height)) * feather)
            .cropped(to: ext)
        return foreground.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: background, kCIInputMaskImageKey: scaled,
        ]).cropped(to: ext)
    }

    /// Mean of channel 0 over the image (CIAreaAverage on the GPU).
    public func areaMean(_ image: CIImage) -> Double {
        let e = image.extent
        guard let avg = CIFilter(name: "CIAreaAverage", parameters: [kCIInputImageKey: image, kCIInputExtentKey: CIVector(cgRect: e)])?.outputImage else { return 0 }
        var px = [Float](repeating: 0, count: 4)
        px.withUnsafeMutableBytes { context.render(avg, toBitmap: $0.baseAddress!, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: nil) }
        return Double(px[0])
    }

    /// 64-bin histogram of display-encoded luminance (CIAreaHistogram on the GPU), normalised to sum 1.
    public func lumaHistogram(_ image: CIImage, bins: Int = 64) -> [Double]? {
        let w = ColorMath.p3LuminanceWeights
        let row = CIVector(x: CGFloat(w.r), y: CGFloat(w.g), z: CGFloat(w.b), w: 0)
        let encoded = image.matchedFromWorkingSpace(to: Renderer.displayP3) ?? image
        let luma = encoded.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": row, "inputGVector": row, "inputBVector": row, "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
        ]).applyingFilter("CIColorClamp")
        guard let h = CIFilter(name: "CIAreaHistogram", parameters: [
            kCIInputImageKey: luma, kCIInputExtentKey: CIVector(cgRect: image.extent), "inputCount": bins, "inputScale": 1,
        ])?.outputImage else { return nil }
        var px = [Float](repeating: 0, count: bins * 4)
        px.withUnsafeMutableBytes { context.render(h, toBitmap: $0.baseAddress!, rowBytes: bins * 16, bounds: CGRect(x: 0, y: 0, width: bins, height: 1), format: .RGBAf, colorSpace: nil) }
        let v = (0..<bins).map { Double(px[$0 * 4]) }
        let total = v.reduce(0, +)
        return total > 0 ? v.map { $0 / total } : nil
    }

    public func resolveLook(_ name: String?) throws -> CubeLUT? { try resolveLookDeclared(name)?.lut }

    /// A built-in look or a LUT file. A file with `<stem>.manifest.json` next to it is checked by `LookContract`
    /// (problems throw; a log route must be used as a library stock, not as a plain look); without one it is
    /// assumed display-referred Display P3 and the note says so.
    public func resolveLookDeclared(_ name: String?) throws -> (lut: CubeLUT, space: LookColorSpace, note: String?)? {
        guard let name, !name.isEmpty else { return nil }
        if let builtIn = BuiltInLook(rawValue: name) { return (builtIn.lut(), .displayP3, nil) }
        let url = URL(fileURLWithPath: name)
        let manifestURL = url.deletingPathExtension().appendingPathExtension("manifest.json")
        let stem = url.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "_33x33_spectral", with: "")
        let alt = url.deletingLastPathComponent().appendingPathComponent(stem + ".manifest.json")
        for m in [manifestURL, alt] where FileManager.default.fileExists(atPath: m.path) {
            let manifest = try JSONDecoder().decode(LookManifest.self, from: Data(contentsOf: m))
            let (check, lut) = LookContract.check(manifest, manifestFile: m.lastPathComponent, cubeData: try? Data(contentsOf: url))
            guard let lut, let route = check.route else {
                throw RawCoreError.invalidLUT("\(url.lastPathComponent) fails its manifest: " + check.problems.joined(separator: "; "))
            }
            guard case .display(let space) = route else {
                throw RawCoreError.invalidLUT("\(url.lastPathComponent) is a log (scene-referred) LUT: register it as a library stock so logLook applies it")
            }
            return (lut, space, "look \(manifest.name) (\(manifest.license.id), sha \(manifest.sha256.prefix(12))…, route display \(space.rawValue))")
        }
        return (try CubeLUT.load(any: url), .displayP3, "look \(url.lastPathComponent): no manifest, assumed display-referred Display P3")
    }

    public enum Format: String, CaseIterable, Sendable { case heic10, png16, jpeg }

    /// Export. With `recipe`, the recipe JSON is embedded in the file (EXIF UserComment) as well, so a HEIC/JPEG
    /// can always be traced back to how it was developed (the sidecar .recipe.json stays the readable copy).
    public func export(_ image: CIImage, format: Format, quality: Double = 0.92, recipe: DecodeRecipe? = nil) throws -> Data {
        let opts: [CIImageRepresentationOption: Any] = [
            CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): quality,
        ]
        var image = image
        if let recipe {
            var props = image.properties
            var exif = props[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
            exif[kCGImagePropertyExifUserComment as String] = "raw-signal-processor recipe " + recipe.compactJSON()
            props[kCGImagePropertyExifDictionary as String] = exif
            image = image.settingProperties(props)
        }
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
