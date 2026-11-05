import Foundation

/// A 3D LUT in display-referred, transfer-encoded Display P3 (the domain .cube files are authored in).
/// Layout matches CIColorCube: red varies fastest, then green, then blue; RGBA float.
public struct CubeLUT: Equatable, Sendable {
    public let size: Int
    public var rgba: [Float]
    public var title: String?

    public init(size: Int, rgba: [Float], title: String? = nil) throws {
        guard (2...128).contains(size) else { throw RawCoreError.invalidLUT("size \(size) out of range 2...128") }
        guard rgba.count == size * size * size * 4 else {
            throw RawCoreError.invalidLUT("expected \(size * size * size * 4) floats, got \(rgba.count)")
        }
        self.size = size; self.rgba = rgba; self.title = title
    }

    public static func identity(size: Int = 33) -> CubeLUT {
        generate(size: size) { $0 }
    }

    /// Build a LUT from a function on encoded RGB in 0...1.
    public static func generate(size: Int, title: String? = nil, _ f: (SIMD3<Float>) -> SIMD3<Float>) -> CubeLUT {
        var data = [Float](repeating: 0, count: size * size * size * 4)
        let s = Float(size - 1)
        var o = 0
        for b in 0..<size {
            for g in 0..<size {
                for r in 0..<size {
                    let v = f(SIMD3(Float(r) / s, Float(g) / s, Float(b) / s))
                    data[o] = min(max(v.x, 0), 1); data[o + 1] = min(max(v.y, 0), 1); data[o + 2] = min(max(v.z, 0), 1)
                    data[o + 3] = 1
                    o += 4
                }
            }
        }
        // swiftlint:disable:next force_try
        return try! CubeLUT(size: size, rgba: data, title: title)
    }

    /// Parse an Adobe/Resolve .cube file (3D only; DOMAIN_MIN/MAX supported by normalisation).
    public static func parse(_ text: String) throws -> CubeLUT {
        var size = 0
        var title: String?
        var dmin = SIMD3<Float>(0, 0, 0), dmax = SIMD3<Float>(1, 1, 1)
        var values: [Float] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            switch parts[0] {
            case "TITLE":
                title = line.dropFirst(5).trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            case "LUT_3D_SIZE":
                guard parts.count == 2, let n = Int(parts[1]) else { throw RawCoreError.invalidLUT("bad LUT_3D_SIZE: \(line)") }
                size = n
            case "LUT_1D_SIZE":
                throw RawCoreError.invalidLUT("1D LUTs are not supported")
            case "DOMAIN_MIN", "DOMAIN_MAX":
                guard parts.count == 4, let a = Float(parts[1]), let b = Float(parts[2]), let c = Float(parts[3]) else {
                    throw RawCoreError.invalidLUT("bad \(parts[0]): \(line)")
                }
                if parts[0] == "DOMAIN_MIN" { dmin = SIMD3(a, b, c) } else { dmax = SIMD3(a, b, c) }
            default:
                guard parts.count == 3, let a = Float(parts[0]), let b = Float(parts[1]), let c = Float(parts[2]) else {
                    throw RawCoreError.invalidLUT("unexpected line: \(line)")
                }
                let v = (SIMD3(a, b, c) - dmin) / (dmax - dmin)
                values.append(contentsOf: [v.x, v.y, v.z, 1])
            }
        }
        guard size > 0 else { throw RawCoreError.invalidLUT("missing LUT_3D_SIZE") }
        return try CubeLUT(size: size, rgba: values, title: title)
    }

    public static func load(_ url: URL) throws -> CubeLUT {
        try parse(String(contentsOf: url, encoding: .utf8))
    }

    /// Trilinear lookup (CPU reference for tests and previews).
    public func apply(_ c: SIMD3<Float>) -> SIMD3<Float> {
        let s = Float(size - 1)
        let p = SIMD3(min(max(c.x, 0), 1), min(max(c.y, 0), 1), min(max(c.z, 0), 1)) * s
        let i0 = SIMD3<Int>(Int(p.x), Int(p.y), Int(p.z))
        let i1 = SIMD3<Int>(min(i0.x + 1, size - 1), min(i0.y + 1, size - 1), min(i0.z + 1, size - 1))
        let f = p - SIMD3<Float>(Float(i0.x), Float(i0.y), Float(i0.z))
        func at(_ r: Int, _ g: Int, _ b: Int) -> SIMD3<Float> {
            let o = ((b * size + g) * size + r) * 4
            return SIMD3(rgba[o], rgba[o + 1], rgba[o + 2])
        }
        func lerp(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ t: Float) -> SIMD3<Float> { a + (b - a) * t }
        let c00 = lerp(at(i0.x, i0.y, i0.z), at(i1.x, i0.y, i0.z), f.x)
        let c10 = lerp(at(i0.x, i1.y, i0.z), at(i1.x, i1.y, i0.z), f.x)
        let c01 = lerp(at(i0.x, i0.y, i1.z), at(i1.x, i0.y, i1.z), f.x)
        let c11 = lerp(at(i0.x, i1.y, i1.z), at(i1.x, i1.y, i1.z), f.x)
        return lerp(lerp(c00, c10, f.y), lerp(c01, c11, f.y), f.z)
    }
}

/// Parametric film looks generated in code (no third-party LUT assets). Applied on top of the
/// Apple-quality base render, so the look never has to repair tone or colour.
public enum BuiltInLook: String, CaseIterable, Sendable {
    case neutral
    /// Warm, soft-shouldered colour negative feel: lifted toe, gentle highlight roll-off,
    /// slight warm/teal split, saturation reduced in highlights.
    case warmNegative
    /// Cooler, punchier slide-film feel: deeper toe, more mid contrast, richer saturation.
    case coolSlide

    public func lut(size: Int = 33) -> CubeLUT {
        switch self {
        case .neutral:
            return .identity(size: size)
        case .warmNegative:
            return CubeLUT.generate(size: size, title: rawValue) { c in
                BuiltInLook.film(c, toe: 0.035, contrast: 0.92, shoulder: 0.9, warm: SIMD3(1.03, 1.0, 0.95),
                                 shadowTint: SIMD3(0.985, 1.0, 1.02), saturation: 0.92, highlightDesat: 0.35)
            }
        case .coolSlide:
            return CubeLUT.generate(size: size, title: rawValue) { c in
                BuiltInLook.film(c, toe: 0.0, contrast: 1.12, shoulder: 0.95, warm: SIMD3(0.98, 1.0, 1.03),
                                 shadowTint: SIMD3(1.0, 1.0, 1.0), saturation: 1.12, highlightDesat: 0.15)
            }
        }
    }

    static func film(_ c: SIMD3<Float>, toe: Float, contrast: Float, shoulder: Float, warm: SIMD3<Float>,
                     shadowTint: SIMD3<Float>, saturation: Float, highlightDesat: Float) -> SIMD3<Float> {
        // Tone: S-curve anchored at 0 and 1 (power on each half), applied to luma so hue stays stable.
        // The toe lift is added as a neutral offset afterwards; multiplying colour by a large
        // luma ratio in deep shadows turns noise into saturated blotches (bug seen on USER_mooncake).
        let w = SIMD3<Float>(0.2126, 0.7152, 0.0722)
        let y = max((c * w).sum(), 0)
        func curve(_ v: Float) -> Float {
            let k = 1 / max(contrast, 0.1)
            let s = v < 0.5 ? 0.5 * pow(2 * v, 1 / k) : 1 - 0.5 * pow(2 * (1 - v), 1 / k)
            return s > shoulder ? shoulder + (1 - shoulder) * tanh((s - shoulder) / max(1 - shoulder, 1e-3)) : s
        }
        let yc = curve(y)
        let ratio = y > 1e-4 ? min(yc / y, 2) : 1
        let base = c * ratio + SIMD3(repeating: max(yc - y * ratio, 0))  // any shortfall added as neutral grey
        var out = SIMD3(repeating: toe) + base * (1 - toe)
        let yt = toe + (1 - toe) * yc
        // Split tone: tint shadows, warm highlights.
        let tint = shadowTint + (warm - shadowTint) * yt
        out *= tint
        // Saturation, reduced toward white.
        let yo = (out * w).sum()
        let sat = saturation * (1 - highlightDesat * yt * yt)
        out = SIMD3(repeating: yo) + (out - SIMD3(repeating: yo)) * sat
        return out
    }
}
