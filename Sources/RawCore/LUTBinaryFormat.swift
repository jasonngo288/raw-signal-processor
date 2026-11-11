import Foundation

/// Compact LUT file (`.mrlut`), reused from MoodRoll (`Core/ImagePipeline/LUT/LUTBinaryFormat.swift`) so both apps
/// read the same files. Layout (little endian): "MRLT", u8 version (1), u8 dimension, u16 reserved, then dimension³ × 3
/// IEEE half floats (R, G, B; red fastest, blue slowest, the `.cube` order). A 33³ cube is ≈ 215 KB instead of
/// ≈ 970 KB of `.cube` text and loads without parsing; half precision error < 0.00025 (≪ 1/255).
/// The values are written as the `CubeLUT` holds them (0…1 input domain, outputs clamped by `CubeLUT.generate`).
public enum LUTBinaryFormat {
    public static let fileExtension = "mrlut"
    static let magic: [UInt8] = [0x4D, 0x52, 0x4C, 0x54]   // "MRLT"
    static let headerSize = 8

    public static func encode(_ lut: CubeLUT) throws -> Data {
        guard (2...255).contains(lut.size) else { throw RawCoreError.invalidLUT(".mrlut stores dimensions 2...255, got \(lut.size)") }
        let entries = lut.size * lut.size * lut.size
        var out = Data(capacity: headerSize + entries * 6)
        out.append(contentsOf: magic)
        out.append(contentsOf: [1, UInt8(lut.size), 0, 0])
        for i in 0..<entries {
            for c in 0..<3 {
                let h = floatToHalf(lut.rgba[i * 4 + c])
                out.append(UInt8(h & 0xFF)); out.append(UInt8(h >> 8))
            }
        }
        return out
    }

    public static func decode(_ data: Data, title: String? = nil) throws -> CubeLUT {
        let bytes = [UInt8](data)
        guard bytes.count >= headerSize, Array(bytes.prefix(4)) == magic, bytes[4] == 1 else {
            throw RawCoreError.invalidLUT(".mrlut: bad header")
        }
        let n = Int(bytes[5]), entries = n * n * n
        guard n > 1, bytes.count == headerSize + entries * 6 else { throw RawCoreError.invalidLUT(".mrlut: length does not match dimension \(n)") }
        var rgba = [Float](repeating: 1, count: entries * 4)
        for i in 0..<entries {
            for c in 0..<3 {
                let o = headerSize + (i * 3 + c) * 2
                rgba[i * 4 + c] = halfToFloat(UInt16(bytes[o]) | (UInt16(bytes[o + 1]) << 8))
            }
        }
        return try CubeLUT(size: n, rgba: rgba, title: title)
    }

    public static func decode(contentsOf url: URL) throws -> CubeLUT {
        try decode(Data(contentsOf: url, options: .mappedIfSafe), title: url.deletingPathExtension().lastPathComponent)
    }

    /// IEEE 754 binary16 → binary32 without the `Float16` type (unavailable on Intel simulators).
    static func halfToFloat(_ h: UInt16) -> Float {
        let sign = UInt32(h >> 15) << 31
        let exp = UInt32((h >> 10) & 0x1F)
        let man = UInt32(h & 0x3FF)
        if exp == 0 {
            if man == 0 { return Float(bitPattern: sign) }
            return (sign == 0 ? 1 : -1) * Float(man) * Float(sign: .plus, exponent: -24, significand: 1)
        }
        if exp == 31 { return Float(bitPattern: sign | 0x7F80_0000 | (man << 13)) }
        return Float(bitPattern: sign | ((exp + 112) << 23) | (man << 13))
    }

    /// binary32 → binary16, round to nearest even; LUT values are finite, so NaN maps to 0 and overflow to ±max.
    static func floatToHalf(_ f: Float) -> UInt16 {
        guard f.isFinite else { return f.isNaN ? 0 : (f < 0 ? 0xFBFF : 0x7BFF) }
        let bits = f.bitPattern
        let sign = UInt16((bits >> 16) & 0x8000)
        let a = abs(f)
        if a >= 65504 { return sign | 0x7BFF }
        if a < Float(sign: .plus, exponent: -24, significand: 1) / 2 { return sign }   // below half the smallest subnormal
        if a < Float(sign: .plus, exponent: -14, significand: 1) {                       // subnormal half
            let m = (a / Float(sign: .plus, exponent: -24, significand: 1)).rounded(.toNearestOrEven)
            return sign | UInt16(m)
        }
        let e = Int(a.exponent)                     // −14 ... 15
        let mant = a.significand - 1                // 0 ..< 1
        var m = (mant * 1024).rounded(.toNearestOrEven)
        var exp = e + 15
        if m >= 1024 { m = 0; exp += 1 }
        if exp >= 31 { return sign | 0x7BFF }
        return sign | UInt16(exp << 10) | UInt16(m)
    }
}

public extension CubeLUT {
    /// `.cube` text (TITLE, LUT_3D_SIZE, 0…1 domain, 6 decimals), the writer of MoodRoll's `CubeLUTWriter`.
    func cubeText(comments: [String] = []) -> String {
        var lines: [String] = []
        if let title { lines.append("TITLE \"\(title)\"") }
        comments.forEach { lines.append("# \($0)") }
        lines.append("LUT_3D_SIZE \(size)")
        lines.reserveCapacity(lines.count + size * size * size)
        for i in 0..<(size * size * size) {
            lines.append(String(format: "%.6f %.6f %.6f", rgba[i * 4], rgba[i * 4 + 1], rgba[i * 4 + 2]))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// `.cube` or `.mrlut` by extension.
    static func load(any url: URL) throws -> CubeLUT {
        url.pathExtension.lowercased() == LUTBinaryFormat.fileExtension ? try LUTBinaryFormat.decode(contentsOf: url) : try load(url)
    }
}
