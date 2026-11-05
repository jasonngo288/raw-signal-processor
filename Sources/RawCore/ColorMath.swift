import Foundation

/// Colour math on linear Display P3 (D65). Pure Swift so it is testable without Core Image.
public enum ColorMath {
    /// Linear Display P3 -> CIE XYZ (D65).
    public static let p3ToXYZ: [Double] = [
        0.4865709486482162, 0.26566769316909306, 0.1982172852343625,
        0.2289745640697488, 0.6917385218365064, 0.079286914093745,
        0.0, 0.04511338185890264, 1.043944368900976,
    ]
    /// D65 white point (Y = 1).
    public static let whiteD65: (x: Double, y: Double, z: Double) = (0.95047, 1.0, 1.08883)
    /// Luminance weights of linear Display P3 (second row of p3ToXYZ).
    public static let p3LuminanceWeights: (r: Float, g: Float, b: Float) = (0.2289746, 0.6917385, 0.0792869)

    /// sRGB / Display P3 transfer function (both use the sRGB curve).
    @inlinable public static func decodeTransfer(_ v: Double) -> Double {
        v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }

    @inlinable public static func encodeTransfer(_ v: Double) -> Double {
        let c = min(max(v, 0), 1)
        return c <= 0.0031308 ? 12.92 * c : 1.055 * pow(c, 1 / 2.4) - 0.055
    }

    @inlinable public static func luminance(r: Float, g: Float, b: Float) -> Float {
        p3LuminanceWeights.r * r + p3LuminanceWeights.g * g + p3LuminanceWeights.b * b
    }

    /// Linear Display P3 -> CIELAB (D65 reference white).
    public static func lab(r: Double, g: Double, b: Double) -> (l: Double, a: Double, b: Double) {
        let m = p3ToXYZ
        let x = m[0] * r + m[1] * g + m[2] * b
        let y = m[3] * r + m[4] * g + m[5] * b
        let z = m[6] * r + m[7] * g + m[8] * b
        func f(_ t: Double) -> Double {
            let e = 216.0 / 24389.0, k = 24389.0 / 27.0
            return t > e ? cbrt(t) : (k * t + 16) / 116
        }
        let fx = f(x / whiteD65.x), fy = f(y / whiteD65.y), fz = f(z / whiteD65.z)
        return (116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz))
    }

    /// CIEDE2000 (Sharma, Wu, Dalal 2005), kL = kC = kH = 1.
    public static func deltaE2000(
        _ l1: Double, _ a1: Double, _ b1: Double,
        _ l2: Double, _ a2: Double, _ b2: Double
    ) -> Double {
        let deg = Double.pi / 180
        let c1 = hypot(a1, b1), c2 = hypot(a2, b2)
        let cBar7 = pow((c1 + c2) / 2, 7)
        let g = 0.5 * (1 - sqrt(cBar7 / (cBar7 + 6_103_515_625)))  // 25^7
        let a1p = (1 + g) * a1, a2p = (1 + g) * a2
        let c1p = hypot(a1p, b1), c2p = hypot(a2p, b2)
        func hue(_ b: Double, _ ap: Double) -> Double {
            if ap == 0 && b == 0 { return 0 }
            let h = atan2(b, ap)
            return h < 0 ? h + 2 * .pi : h
        }
        let h1p = hue(b1, a1p), h2p = hue(b2, a2p)
        let dLp = l2 - l1, dCp = c2p - c1p
        var dhp = 0.0
        if c1p * c2p != 0 {
            dhp = h2p - h1p
            if dhp > .pi { dhp -= 2 * .pi } else if dhp < -.pi { dhp += 2 * .pi }
        }
        let dHp = 2 * sqrt(c1p * c2p) * sin(dhp / 2)
        let lBarP = (l1 + l2) / 2, cBarP = (c1p + c2p) / 2
        var hBarP: Double
        if c1p * c2p == 0 {
            hBarP = h1p + h2p
        } else if abs(h1p - h2p) <= .pi {
            hBarP = (h1p + h2p) / 2
        } else if h1p + h2p < 2 * .pi {
            hBarP = (h1p + h2p + 2 * .pi) / 2
        } else {
            hBarP = (h1p + h2p - 2 * .pi) / 2
        }
        let t = 1 - 0.17 * cos(hBarP - 30 * deg) + 0.24 * cos(2 * hBarP)
            + 0.32 * cos(3 * hBarP + 6 * deg) - 0.20 * cos(4 * hBarP - 63 * deg)
        let dTheta = 30 * exp(-pow((hBarP / deg - 275) / 25, 2))
        let cBarP7 = pow(cBarP, 7)
        let rc = 2 * sqrt(cBarP7 / (cBarP7 + 6_103_515_625))
        let l50 = (lBarP - 50) * (lBarP - 50)
        let sl = 1 + 0.015 * l50 / sqrt(20 + l50), sc = 1 + 0.045 * cBarP, sh = 1 + 0.015 * cBarP * t
        let rt = -sin(2 * dTheta * deg) * rc
        let x = dLp / sl, y = dCp / sc, z = dHp / sh
        return sqrt(x * x + y * y + z * z + rt * y * z)
    }
}
