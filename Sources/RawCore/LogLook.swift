import Foundation

/// Looks authored for log footage (".cube (LOG)"): they expect scene-referred light encoded with a camera log curve,
/// not Apple's display-referred render. Pure Swift: the curves and the composite LUT the `logLook` plugin applies.
public enum LogCurve: String, Codable, Sendable, CaseIterable {
    /// Apple Log (iPhone 15 Pro and later; Apple Log Profile white paper), Rec.2020 primaries.
    case appleLog
    /// Sony S-Log3 (S-Gamut3 approximated by Rec.2020 here).
    case sLog3
    /// ARRI LogC3 (EI 800).
    case logC3
    /// Panasonic V-Log.
    case vLog

    /// Linear scene light (0.18 = mid grey) → log code value 0…1.
    public func encode(_ x: Double) -> Double {
        switch self {
        case .appleLog:
            let r0 = -0.05641088, rt = 0.01, c = 47.28711236, b = 0.00964052, g = 0.08550479, beta = 0.69336945
            if x < r0 { return 0 }
            if x < rt { return c * (x - r0) * (x - r0) }
            return g * log2(x + b) + beta
        case .sLog3:
            if x >= 0.01125 { return (420 + log10((x + 0.01) / 0.19) * 261.5) / 1023 }
            return (x * (171.2102946929 - 95) / 0.01125 + 95) / 1023
        case .logC3:
            if x > 0.010591 { return 0.247190 * log10(5.555556 * x + 0.052272) + 0.385537 }
            return 5.367655 * x + 0.092809
        case .vLog:
            if x >= 0.01 { return 0.241514 * log10(x + 0.00873) + 0.598206 }
            return 5.6 * x + 0.125
        }
    }
}

/// How a look LUT wants its input.
public enum LookInput: Codable, Equatable, Sendable {
    /// Encoded Display P3 of the base render (every built-in look, preset and plain .cube).
    case display
    /// Scene-linear light, Rec.2020 primaries, encoded with `LogCurve`; output Rec.709 display-encoded.
    case log(LogCurve)
}

public enum LogLook {
    /// Scene-linear values are scaled by 1/headroom before the cube (whose input is encoded P3, 0…1), so light up to
    /// `headroom` × diffuse white reaches the log curve instead of clipping at 1.
    public static let headroom: Double = 4
    public static let compositeSize = 65

    static let p3ToRec2020: [Double] = [0.753833, 0.198597, 0.047570, 0.045744, 0.941777, 0.012479, -0.001210, 0.017602, 0.983609]
    static let rec709ToP3: [Double] = [0.822462, 0.177538, 0.0, 0.033194, 0.966806, 0.0, 0.017083, 0.072397, 0.910520]

    static func srgbDecode(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
    static func srgbEncode(_ v: Double) -> Double { v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1 / 2.4) - 0.055 }
    static func mul(_ m: [Double], _ v: SIMD3<Double>) -> SIMD3<Double> {
        SIMD3(m[0] * v.x + m[1] * v.y + m[2] * v.z, m[3] * v.x + m[4] * v.y + m[5] * v.z, m[6] * v.x + m[7] * v.y + m[8] * v.z)
    }

    /// One cube doing it all: input = encoded P3 of (scene-linear / headroom); → linear × headroom → Rec.2020 →
    /// log curve → the user's LUT → Rec.709 output re-expressed as encoded Display P3 (what CIColorCube writes back).
    static let p3ToRec709: [Double] = [1.224940, -0.224940, 0.0, -0.042057, 1.042057, 0.0, -0.019638, -0.078636, 1.098274]

    public static func composite(_ lut: CubeLUT, curve: LogCurve, primaries: LogLookPrimaries = .rec2020, size: Int = compositeSize) -> CubeLUT {
        let toInput = primaries == .rec2020 ? p3ToRec2020 : p3ToRec709
        return CubeLUT.generate(size: size, title: (lut.title ?? "log look") + " via \(curve.rawValue)") { c in
            let lin = SIMD3(srgbDecode(Double(c.x)), srgbDecode(Double(c.y)), srgbDecode(Double(c.z))) * headroom
            let r2020 = mul(toInput, lin)
            let logv = SIMD3(Float(curve.encode(r2020.x)), Float(curve.encode(r2020.y)), Float(curve.encode(r2020.z)))
            let out709 = lut.apply(logv.clamped(lowerBound: SIMD3(repeating: 0), upperBound: SIMD3(repeating: 1)))
            let lin709 = SIMD3(srgbDecode(Double(out709.x)), srgbDecode(Double(out709.y)), srgbDecode(Double(out709.z)))
            let p3 = mul(rec709ToP3, lin709)
            return SIMD3(Float(srgbEncode(max(0, p3.x))), Float(srgbEncode(max(0, p3.y))), Float(srgbEncode(max(0, p3.z))))
        }
    }
}
