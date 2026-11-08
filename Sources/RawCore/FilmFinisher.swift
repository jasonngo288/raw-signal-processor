#if canImport(CoreImage)
import CoreImage
import Foundation

/// Core Image implementation of `FilmFinish`, built only from built-in filters (no custom kernels).
/// Order: halation (light) → grain (last, on top). Vignette lives in VignettePlugin.
public enum FilmFinisher {
    static let luma = ColorMath.p3LuminanceWeights

    public static func apply(_ image: CIImage, _ f: FilmFinish) -> CIImage {
        guard f.grainAmount > 0 || f.halationAmount > 0 else { return image }
        let ext = image.extent
        let short = Double(min(ext.width, ext.height))
        var out = image
        if f.halationAmount > 0 { out = halation(out, f, short: short) }
        // Vignette is the `vignette` plugin (Plugins.swift), not part of the core finish.
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
        // CIAdditionCompositing also adds alpha (1 + 1 = 2); reset it, or later compositing goes wrong.
        return tinted.applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: img])
            .settingAlphaOne(in: ext).cropped(to: ext)
    }

    public static func vignette(_ img: CIImage, _ amount: Float) -> CIImage {
        let ext = img.extent
        let radius = 0.35 * hypot(ext.width, ext.height)  // corners sit at ~1.4x radius
        return img.applyingFilter("CIVignetteEffect", parameters: [
            kCIInputCenterKey: CIVector(x: ext.midX, y: ext.midY),
            kCIInputRadiusKey: radius,
            kCIInputIntensityKey: amount,
            "inputFalloff": 0.6,
        ]).cropped(to: ext)
    }

    /// Multiplicative luminance grain: out = img * (1 + a * w * k * (n1 - n2)).
    /// n1, n2 = two independent smoothed noise fields (different offsets of CIRandomGenerator); their difference
    /// has zero mean whatever the generator's value distribution, so grain never shifts exposure.
    /// w = 1 - 0.8 Y (clamped to 0.2...1): grain fades toward white. Cell size and smoothing are tied to the
    /// short edge, so grain statistics do not depend on resolution.
    static func grain(_ img: CIImage, _ f: FilmFinish, short: Double) -> CIImage {
        let ext = img.extent
        let cell = max(0.35, short * Double(f.grainSize) / 100)
        guard let random = CIFilter(name: "CIRandomGenerator")?.outputImage else { return img }
        func field(_ offset: CGFloat, sign: CGFloat) -> CIImage {
            random
                .transformed(by: CGAffineTransform(translationX: offset, y: -offset))
                .transformed(by: CGAffineTransform(scaleX: cell, y: cell))
                .transformed(by: CGAffineTransform(translationX: ext.minX, y: ext.minY))
                .applyingFilter("CIColorMatrix", parameters: [   // monochrome: red channel everywhere
                    "inputRVector": CIVector(x: sign, y: 0, z: 0, w: 0),
                    "inputGVector": CIVector(x: sign, y: 0, z: 0, w: 0),
                    "inputBVector": CIVector(x: sign, y: 0, z: 0, w: 0),
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0), "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                ])
                .applyingGaussianBlur(sigma: 0.5 * cell)
                .cropped(to: ext)
        }
        let seed = CGFloat(f.grainSeed % 4096) * 613
        let d = field(seed, sign: 1).applyingFilter("CIAdditionCompositing", parameters: [
            kCIInputBackgroundImageKey: field(seed + 100_003, sign: -1),
        ]).settingAlphaOne(in: ext)  // addition sums alpha too (see halation)
        let w = lumaRamp(img, gain: -0.8, bias: 1, min: 0.2)
        let wd = d.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: w])
        let gainScale = CGFloat(f.grainAmount) * 0.25 * 1.5
        let g = wd.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: gainScale, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: gainScale, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: gainScale, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputBiasVector": CIVector(x: 1, y: 1, z: 1, w: 0),
        ]).applyingFilter("CIColorClamp", parameters: [
            // Hard bound on the grain multiplier: without it rare extreme cells became black dots (run 42388087057).
            "inputMinComponents": CIVector(x: 1 - gainScale, y: 1 - gainScale, z: 1 - gainScale, w: 1),
            "inputMaxComponents": CIVector(x: 1 + gainScale, y: 1 + gainScale, z: 1 + gainScale, w: 1),
        ])
        return g.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: img]).cropped(to: ext)
    }
}
#endif
