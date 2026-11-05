import Foundation

/// A small linear-light Display P3 RGB raster used for analysis and metrics.
/// Values are display-linear (0...1 is the SDR range; > 1 is headroom).
public struct LinearImage: Equatable, Sendable {
    public let width: Int
    public let height: Int
    /// Interleaved RGB, row-major, count = width * height * 3.
    public var pixels: [Float]

    public init(width: Int, height: Int, pixels: [Float]) {
        precondition(width > 0 && height > 0 && pixels.count == width * height * 3, "Invalid LinearImage layout")
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    public init(width: Int, height: Int, fill: (Float, Float, Float)) {
        var p = [Float](repeating: 0, count: width * height * 3)
        for i in 0..<(width * height) {
            p[i * 3] = fill.0; p[i * 3 + 1] = fill.1; p[i * 3 + 2] = fill.2
        }
        self.init(width: width, height: height, pixels: p)
    }

    @inlinable public var pixelCount: Int { width * height }

    /// Linear luminance per pixel, after clamping each channel to [0, 1] (what an SDR display shows).
    public func displayLuminance() -> [Float] {
        var out = [Float](repeating: 0, count: pixelCount)
        for i in 0..<pixelCount {
            let r = min(max(pixels[i * 3], 0), 1), g = min(max(pixels[i * 3 + 1], 0), 1), b = min(max(pixels[i * 3 + 2], 0), 1)
            out[i] = ColorMath.luminance(r: r, g: g, b: b)
        }
        return out
    }

    /// Box downsample by an integer factor (area average, edge-correct).
    public func downsampled(by factor: Int) -> LinearImage {
        guard factor > 1 else { return self }
        let w = max(1, width / factor), h = max(1, height / factor)
        var out = [Float](repeating: 0, count: w * h * 3)
        for y in 0..<h {
            for x in 0..<w {
                var s: (Float, Float, Float) = (0, 0, 0)
                var n: Float = 0
                for yy in (y * factor)..<min(height, (y + 1) * factor) {
                    for xx in (x * factor)..<min(width, (x + 1) * factor) {
                        let i = (yy * width + xx) * 3
                        s.0 += pixels[i]; s.1 += pixels[i + 1]; s.2 += pixels[i + 2]; n += 1
                    }
                }
                let o = (y * w + x) * 3
                out[o] = s.0 / n; out[o + 1] = s.1 / n; out[o + 2] = s.2 / n
            }
        }
        return LinearImage(width: w, height: h, pixels: out)
    }
}

/// Separable Gaussian blur of a single-channel plane (edge clamped). Pure Swift, fine for ~1 MP.
public func gaussianBlur(_ plane: [Float], width: Int, height: Int, sigma: Double) -> [Float] {
    guard sigma > 0 else { return plane }
    let radius = max(1, Int((3 * sigma).rounded(.up)))
    var kernel = [Float](repeating: 0, count: 2 * radius + 1)
    var total: Float = 0
    for d in -radius...radius {
        let v = Float(exp(-0.5 * Double(d * d) / (sigma * sigma)))
        kernel[d + radius] = v
        total += v
    }
    for i in kernel.indices { kernel[i] /= total }
    var tmp = [Float](repeating: 0, count: plane.count)
    var out = [Float](repeating: 0, count: plane.count)
    for y in 0..<height {
        let row = y * width
        for x in 0..<width {
            var s: Float = 0
            for d in -radius...radius {
                let xx = min(max(x + d, 0), width - 1)
                s += kernel[d + radius] * plane[row + xx]
            }
            tmp[row + x] = s
        }
    }
    for y in 0..<height {
        for x in 0..<width {
            var s: Float = 0
            for d in -radius...radius {
                let yy = min(max(y + d, 0), height - 1)
                s += kernel[d + radius] * tmp[yy * width + x]
            }
            out[y * width + x] = s
        }
    }
    return out
}
