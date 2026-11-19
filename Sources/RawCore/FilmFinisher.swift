#if canImport(CoreImage)
import CoreImage
import Foundation

/// Core Image implementation of `FilmFinish`, built only from built-in filters (no custom kernels).
/// Order: halation (light) → grain (last, on top). Vignette lives in VignettePlugin.
public enum FilmFinisher {
    static let luma = ColorMath.p3LuminanceWeights

    /// Halation, then grain (the only grain site of the legacy, no-crop path). Grain cell is fixed in output px.
    public static func apply(_ image: CIImage, _ f: FilmFinish) -> CIImage {
        let profile = f.resolvedGrain
        guard profile != nil || f.halationAmount > 0 else { return image }
        let ext = image.extent
        let short = Double(min(ext.width, ext.height))
        var out = image
        if f.halationAmount > 0 { out = halation(out, f, short: short) }
        // Vignette is the `vignette` plugin (Plugins.swift), not part of the core finish.
        if let profile { out = grain(out, profile: profile, seed: f.grainSeed) }
        return out.cropped(to: ext)
    }

    /// Halation only, sized on this image's short edge. `applyGrain(applyHalation(x))` == `apply(x)` (same extent).
    public static func applyHalation(_ image: CIImage, _ f: FilmFinish) -> CIImage {
        guard f.halationAmount > 0 else { return image }
        let ext = image.extent
        return halation(image, f, short: Double(min(ext.width, ext.height))).cropped(to: ext)
    }

    /// Grain only, from the finish's profile (pipeline v2 stage 4: called once on the cropped master).
    public static func applyGrain(_ image: CIImage, _ f: FilmFinish) -> CIImage {
        guard let profile = f.resolvedGrain else { return image }
        return applyGrain(image, profile: profile, seed: f.grainSeed)
    }

    /// THE grain implementation (stage 4, order B). Everything that grains (v2, legacy finish, film samples, legacy engine
    /// once wired) calls this; nothing else adds grain. Call it once per output, on the full-resolution master.
    public static func applyGrain(_ image: CIImage, profile: GrainProfile, seed: UInt32) -> CIImage {
        guard profile.sigma50 > 0 else { return image }
        return grain(image, profile: profile, seed: seed).cropped(to: image.extent)
    }

    /// Whole-pixel rect of a normalized top-left `OutputCrop` inside `ext` (Core Image origin is bottom-left).
    public static func pixelRect(_ c: OutputCrop, in ext: CGRect) -> CGRect {
        let r = CGRect(x: ext.minX + CGFloat(c.x) * ext.width, y: ext.minY + CGFloat(1 - c.y - c.height) * ext.height,
                       width: CGFloat(c.width) * ext.width, height: CGFloat(c.height) * ext.height).integral
        let clipped = r.intersection(ext)
        return clipped.isNull || clipped.isEmpty ? ext : clipped
    }

    /// Crop to `rect` and move it to origin 0,0 (integer translation: no resampling).
    public static func crop(_ image: CIImage, to rect: CGRect) -> CIImage {
        image.cropped(to: rect).transformed(by: CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
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

    // MARK: light leak (plugin `lightLeak`; the maths is pure Swift in `LightLeakPlanner`)

    /// Long edge of the bitmap the leak is evaluated on; it is smooth, so it is scaled up with a B-spline.
    static let leakLongEdge = 256

    /// The leak layer (linear light, alpha 1), `extent` size, from the planned leak. Values are the light to add.
    public static func lightLeakLayer(_ spec: LightLeakSpec, _ leak: LightLeakPlan.Leak, extent ext: CGRect) -> CIImage? {
        let long = Double(max(ext.width, ext.height))
        let lw = max(2, Int((Double(ext.width) / long * Double(leakLongEdge)).rounded()))
        let lh = max(2, Int((Double(ext.height) / long * Double(leakLongEdge)).rounded()))
        var px = [Float](repeating: 0, count: lw * lh * 4)
        let aspect = Float(ext.width / ext.height)
        for j in 0..<lh {
            for i in 0..<lw {
                let a = LightLeakPlanner.addition(spec: spec, leak: leak, x: (Float(i) + 0.5) / Float(lw), y: (Float(j) + 0.5) / Float(lh), aspectWH: aspect)
                let o = (j * lw + i) * 4
                px[o] = a.x; px[o + 1] = a.y; px[o + 2] = a.z; px[o + 3] = 1
            }
        }
        let data = px.withUnsafeBufferPointer { Data(buffer: $0) }
        let small = CIImage(bitmapData: data, bytesPerRow: lw * 16, size: CGSize(width: lw, height: lh), format: .RGBAf, colorSpace: nil)
        let sx = ext.width / CGFloat(lw), sy = ext.height / CGFloat(lh)
        guard let up = CIFilter(name: "CIBicubicScaleTransform", parameters: [
            kCIInputImageKey: small.clampedToExtent(), kCIInputScaleKey: sy, "inputAspectRatio": sx / sy, "inputB": 1.0, "inputC": 0.0,
        ])?.outputImage else { return nil }
        return up.transformed(by: CGAffineTransform(translationX: ext.minX, y: ext.minY)).cropped(to: ext)
    }

    /// Screens the leak over `image` in linear light (the working space), ceiling `spec.encodedCap` encoded: a pixel
    /// above the ceiling is left as it was, never pulled down; below it the result cannot pass it (no new clip).
    /// `personMask` (any size, red channel) scales the leak by `spec.personFactor` inside it.
    public static func lightLeak(_ image: CIImage, spec: LightLeakSpec, leak: LightLeakPlan.Leak, personMask: CIImage? = nil) -> CIImage {
        let ext = image.extent
        guard var layer = lightLeakLayer(spec, leak, extent: ext) else { return image }
        if let m = personMask, m.extent.width > 0, m.extent.height > 0, spec.personFactor < 1 {
            let e = m.extent
            let scaled = m.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
                .transformed(by: CGAffineTransform(scaleX: ext.width / e.width, y: ext.height / e.height))
                .transformed(by: CGAffineTransform(translationX: ext.minX, y: ext.minY))
                .clampedToExtent()
                .applyingGaussianBlur(sigma: Double(min(ext.width, ext.height)) * 0.004)
                .cropped(to: ext)
            let k = CGFloat(1 - spec.personFactor)
            let factor = scaled.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: -k, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: -k, y: 0, z: 0, w: 0),
                "inputBVector": CIVector(x: -k, y: 0, z: 0, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputBiasVector": CIVector(x: 1, y: 1, z: 1, w: 1),
            ])
            layer = layer.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: factor]).cropped(to: ext)
        }
        let screened = layer.applyingFilter("CIScreenBlendMode", parameters: [kCIInputBackgroundImageKey: image])
        let cap = CGFloat(ColorMath.decodeTransfer(Double(spec.encodedCap)))
        let ceiling = image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputBiasVector": CIVector(x: cap, y: cap, z: cap, w: 0),
        ])
        return screened.applyingFilter("CIMinimumCompositing", parameters: [kCIInputBackgroundImageKey: ceiling])
            .applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: image])
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

    /// Effective std of the unit noise field `A - B` (alpha forced to 1, Gaussian blur 0.5 cell), calibrated on the real
    /// renderer so that RMS at L = 0.5 on a flat wedge equals `sigma50`: the measured field std is 0.170 at cellPx 2.0 and
    /// 0.182 at 4.5 (0.178 is the middle), which leaves the result within +-4 % over cellPx 2...4.5 (all 14 stocks).
    /// Not valid below 1.75 px. Re-check with `raw-bench grain-proof` whenever the noise recipe changes.
    static let grainUnitSD = 0.178

    /// Density grain in the display-encoded domain (order B). enc = encode(img); out = decode(enc + n), with
    /// n = sigma50/255 * s(L)/s(0.5) * (D0 + chroma-part) and L the encoded luma of the pixel (not of the noise).
    /// D0 = A - B: two independent smoothed fields; their difference has zero mean whatever the generator's distribution,
    /// so grain never shifts exposure. The cell (`cellPx`) and the blur are in output px, so the grain does not depend on
    /// the image size. Chroma: three independent channel fields made zero-sum (R+G+B = 0), amplitude per channel
    /// `chroma` x the luma amplitude, same cell and curve.
    static func grain(_ img: CIImage, profile p: GrainProfile, seed: UInt32) -> CIImage {
        let ext = img.extent
        let cell = max(0.35, p.cellPx)
        // CIRandomGenerator gives four independent uniform channels, alpha included. Core Image's colour filters divide the
        // colour by that random alpha: rare extreme values (black dots, a 10^3 x std) and R, G, B that share one divisor
        // (correlated, so the chroma part came out 15 % low). Fix: force alpha to 1 before any colour filter touches it.
        guard let random = CIFilter(name: "CIRandomGenerator")?.outputImage else { return img }
        let pad = ext.insetBy(dx: -8 * cell - 8, dy: -8 * cell - 8)   // blur margin: blur is applied before the crop to `ext`
        /// `chroma` routes random channel i to output channel i; luma routes random R to all channels.
        func field(_ offset: CGFloat, sign: CGFloat, chroma: Bool) -> CIImage {
            let rv = CIVector(x: sign, y: 0, z: 0, w: 0)
            let gv = chroma ? CIVector(x: 0, y: sign, z: 0, w: 0) : rv
            let bv = chroma ? CIVector(x: 0, y: 0, z: sign, w: 0) : rv
            return random
                .transformed(by: CGAffineTransform(translationX: offset, y: -offset))
                .transformed(by: CGAffineTransform(scaleX: cell, y: cell))
                .transformed(by: CGAffineTransform(translationX: ext.minX, y: ext.minY))
                .settingAlphaOne(in: pad)
                .applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": rv, "inputGVector": gv, "inputBVector": bv,
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0), "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                ])
                .clampedToExtent()
                .applyingGaussianBlur(sigma: 0.5 * cell)
                .cropped(to: ext)
        }
        func difference(_ offset: CGFloat, chroma: Bool) -> CIImage {
            field(offset, sign: 1, chroma: chroma).applyingFilter("CIAdditionCompositing", parameters: [
                kCIInputBackgroundImageKey: field(offset + 100_003, sign: -1, chroma: chroma),
            ]).settingAlphaOne(in: ext)  // addition sums alpha too (see halation)
        }
        func matrix(_ img: CIImage, _ r: [CGFloat], _ g: [CGFloat], _ b: [CGFloat]) -> CIImage {
            img.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: r[0], y: r[1], z: r[2], w: 0), "inputGVector": CIVector(x: g[0], y: g[1], z: g[2], w: 0),
                "inputBVector": CIVector(x: b[0], y: b[1], z: b[2], w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            ])
        }
        let base = CGFloat(p.sigma50 / 255 / grainUnitSD)   // encoded-domain amplitude per unit noise
        let seedOffset = CGFloat(seed % 4096) * 613

        // Encoded working copy (negative light is cut; values above 1 stay).
        let enc = img.applyingFilter("CIColorClamp", parameters: [
            "inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 0), "inputMaxComponents": CIVector(x: 64, y: 64, z: 64, w: 1),
        ]).applyingFilter("CILinearToSRGBToneCurve")

        // Noise: luma part on all channels, plus the zero-sum chroma part.
        var noise = matrix(difference(seedOffset, chroma: false), [base, 0, 0], [base, 0, 0], [base, 0, 0])
        if p.chroma > 0 {
            let c = base * CGFloat(p.chroma) * 1.5.squareRoot()   // zero-sum of 3 equal fields has std sqrt(2/3) of one
            let x = difference(seedOffset + 200_003, chroma: true)
            let cm = matrix(x, [c * 2 / 3, -c / 3, -c / 3], [-c / 3, c * 2 / 3, -c / 3], [-c / 3, -c / 3, c * 2 / 3])
            noise = noise.applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: cm]).settingAlphaOne(in: ext)
        }
        // Weight map: s(L)/s(0.5) of the encoded luma, through a 1-D curve laid on the diagonal of a colour cube.
        let luma = lumaRamp(enc, gain: 1, bias: 0)
        let weight = luma.applyingFilter("CIColorCube", parameters: [
            "inputCubeDimension": Self.weightCubeSize, "inputCubeData": weightCube(p),
        ])
        let grained = noise.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: weight]).settingAlphaOne(in: ext)
        let sum = grained.applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: enc]).settingAlphaOne(in: ext)
        return sum.applyingFilter("CIColorClamp", parameters: [
            "inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 0), "inputMaxComponents": CIVector(x: 64, y: 64, z: 64, w: 1),
        ]).applyingFilter("CISRGBToneCurveToLinear").cropped(to: ext)
    }

    static let weightCubeSize = 65

    /// RGBAf cube whose output is s(r)/s(0.5) in every channel (r = the encoded luma sits on the grey diagonal).
    static func weightCube(_ p: GrainProfile) -> Data {
        let n = weightCubeSize
        var px = [Float](repeating: 0, count: n * n * n * 4)
        for b in 0..<n { for g in 0..<n { for r in 0..<n {
            let w = Float(p.weight(at: Double(r) / Double(n - 1)))
            let o = ((b * n + g) * n + r) * 4
            px[o] = w; px[o + 1] = w; px[o + 2] = w; px[o + 3] = 1
        } } }
        return px.withUnsafeBufferPointer { Data(buffer: $0) }
    }
}
#endif
