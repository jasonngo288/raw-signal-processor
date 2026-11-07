#if canImport(CoreImage)
import CoreImage
import Foundation

/// Core Image implementation of `FilmFinish`, built only from built-in filters (no custom kernels).
/// Order: halation (light, so it is added before the print darkens corners) → vignette → grain (last, on top).
public enum FilmFinisher {
    static let luma = ColorMath.p3LuminanceWeights

    public static func apply(_ image: CIImage, _ f: FilmFinish) -> CIImage {
        guard !f.isNone else { return image }
        let ext = image.extent
        let short = Double(min(ext.width, ext.height))
        var out = image
        if f.halationAmount > 0 { out = halation(out, f, short: short) }
        if f.vignette > 0 { out = vignette(out, f.vignette) }
        if f.grainAmount > 0 { out = grain(out, f, short: short) }
        return out.cropped(to: ext)
    }

    /// Every channel = gain * Y + bias, then clamped to 0...1.
    static func lumaRamp(_ img: CIImage, gain: CGFloat, bias: CGFloat, min: CGFloat = 0) -> CIImage {
        let row = CIVector(x: CGFloat(luma.r) * gain, y: CGFloat(luma.g) * gain, z: CGFloat(luma.b) * gain, w: 0)
        return img.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": row, "inputGVector": row, "inputBVector": row,
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputBiasVector": CIVector(x: bias, y: bias, z: bias, w: 0),
        ]).applyingFilter("CIColorClamp", parameters: [
            "inputMinComponents": CIVector(x: min, y: min, z: min, w: 0),
            "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1),
        ])
    }

    static func halation(_ img: CIImage, _ f: FilmFinish, short: Double) -> CIImage {
        let ext = img.extent
        let t = CGFloat(f.halationThreshold)
        let mask = lumaRamp(img, gain: 1 / (1 - t), bias: -t / (1 - t))
        let bright = mask.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: img])
        let glow = bright.clampedToExtent().applyingGaussianBlur(sigma: short * Double(f.halationRadius) / 100).cropped(to: ext)
        let a = CGFloat(f.halationAmount)
        // Red-orange: the red-sensitive layer is closest to the base, so scattered light shows up red.
        let tinted = glow.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: a, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: a * 0.35, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: a * 0.10, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
        ])
        return tinted.applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: img]).cropped(to: ext)
    }

    static func vignette(_ img: CIImage, _ amount: Float) -> CIImage {
        let ext = img.extent
        let radius = 0.35 * hypot(ext.width, ext.height)  // corners sit at ~1.4x radius
        return img.applyingFilter("CIVignetteEffect", parameters: [
            kCIInputCenterKey: CIVector(x: ext.midX, y: ext.midY),
            kCIInputRadiusKey: radius,
            kCIInputIntensityKey: amount,
            "inputFalloff": 0.6,
        ]).cropped(to: ext)
    }

    /// Multiplicative luminance grain: out = img * (1 + a * w * (n - 0.5)), n = smoothed uniform noise,
    /// w = 1 - 0.8 Y (clamped to 0.2...1) so grain fades toward white. Cell size and smoothing are both
    /// tied to the short edge, so grain statistics do not depend on resolution.
    static func grain(_ img: CIImage, _ f: FilmFinish, short: Double) -> CIImage {
        let ext = img.extent
        let cell = max(0.35, short * Double(f.grainSize) / 100)
        guard let random = CIFilter(name: "CIRandomGenerator")?.outputImage else { return img }
        let seedOffset = CGFloat(f.grainSeed % 4096) * 613
        let noise = random
            .transformed(by: CGAffineTransform(translationX: seedOffset, y: -seedOffset))
            .transformed(by: CGAffineTransform(scaleX: cell, y: cell))
            .transformed(by: CGAffineTransform(translationX: ext.minX, y: ext.minY))
            .applyingFilter("CIColorMatrix", parameters: [   // monochrome: red channel everywhere
                "inputRVector": CIVector(x: 1, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 1, y: 0, z: 0, w: 0),
                "inputBVector": CIVector(x: 1, y: 0, z: 0, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0), "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            ])
            .applyingGaussianBlur(sigma: 0.5 * cell)
            .cropped(to: ext)
        // Smoothing shrinks the spread of uniform noise; stretch it back around 0.5 by a fixed factor
        // (the factor is resolution independent because sigma is a fixed fraction of the cell).
        let k: CGFloat = 2.5
        let n = noise.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: k, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: k, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: k, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputBiasVector": CIVector(x: 0.5 - 0.5 * k, y: 0.5 - 0.5 * k, z: 0.5 - 0.5 * k, w: 0),
        ]).applyingFilter("CIColorClamp")
        let w = lumaRamp(img, gain: -0.8, bias: 1, min: 0.2)
        let a = CGFloat(f.grainAmount) * 0.25
        // G = a*w*n + (1 - 0.5*a*w): built from non-negative pieces only.
        let wn = n.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: w])
        let scale = { (img: CIImage, s: CGFloat, b: CGFloat) in
            img.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: s, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: s, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: s, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                "inputBiasVector": CIVector(x: b, y: b, z: b, w: 0),
            ])
        }
        let g = scale(wn, a, 0).applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: scale(w, -0.5 * a, 1)])
        return g.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: img]).cropped(to: ext)
    }
}
#endif
