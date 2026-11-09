import Foundation

/// Gate 3 tooling (roadmap 10): measure a ColorChecker Classic (24 patches) in a scene-linear decode, solve a 3×3 CCM
/// for the model, and compare models. Pure Swift.
///
/// Workflow: shoot the chart with each iPhone (same light, chart filling ~1/3 of the frame, RAW), then
/// `raw-bench chart capture.dng --corners …` → calibration entry + patch file; `raw-bench gate3 a.json b.json`.
public enum ColorChecker {
    /// ColorChecker Classic, X-Rite values for charts made after Nov 2014, CIELAB D50 (2° observer).
    /// Row-major from the top-left (dark skin) to the bottom-right (black), as the chart is read with the
    /// neutral row at the bottom. Check them against your chart's own data sheet; `--reference` overrides them.
    public static let referenceLabD50: [SIMD3<Double>] = [
        SIMD3(37.54, 14.37, 14.92), SIMD3(64.66, 19.27, 17.50), SIMD3(49.32, -3.82, -22.54),
        SIMD3(43.46, -12.74, 22.72), SIMD3(54.94, 9.61, -24.79), SIMD3(70.48, -32.26, -0.37),
        SIMD3(62.73, 35.83, 56.50), SIMD3(39.43, 10.75, -45.17), SIMD3(50.57, 48.64, 16.67),
        SIMD3(30.10, 22.54, -20.87), SIMD3(71.77, -24.13, 58.19), SIMD3(71.51, 18.24, 67.37),
        SIMD3(28.37, 15.42, -49.80), SIMD3(54.38, -39.72, 32.27), SIMD3(42.43, 51.05, 28.62),
        SIMD3(81.80, 2.67, 80.41), SIMD3(50.63, 51.28, -14.12), SIMD3(49.57, -29.71, -28.32),
        SIMD3(95.19, -1.03, 2.93), SIMD3(81.29, -0.57, 0.44), SIMD3(66.89, -0.75, -0.06),
        SIMD3(50.76, -0.13, 0.14), SIMD3(35.63, -0.46, -0.48), SIMD3(20.64, 0.07, -0.46),
    ]
    public static let names = ["dark skin", "light skin", "blue sky", "foliage", "blue flower", "bluish green",
                               "orange", "purplish blue", "moderate red", "purple", "yellow green", "orange yellow",
                               "blue", "green", "red", "yellow", "magenta", "cyan",
                               "white 9.5", "neutral 8", "neutral 6.5", "neutral 5", "neutral 3.5", "black 2"]
    /// Reads a chart's own data sheet: 24 CIELAB D50 triplets in chart order (dark skin … black).
    /// Each line that holds at least three numbers contributes its **last three** (so "1 dark skin 37.54 14.37 14.92",
    /// "37.54,14.37,14.92" and "A1;37,54;14,37;14,92" after comma decimals are all accepted); lines with fewer are ignored
    /// (headers, comments starting with #). Returns nil unless exactly 24 triplets with L in 0...100 are found.
    public static func parseReference(_ text: String) -> [SIMD3<Double>]? {
        var out: [SIMD3<Double>] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            var line = String(raw).trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") || line.isEmpty { continue }
            // Semicolon-separated sheets often use decimal commas.
            if line.contains(";") { line = line.replacingOccurrences(of: ",", with: ".").replacingOccurrences(of: ";", with: " ") }
            let nums = line.split(whereSeparator: { " \t,".contains($0) }).compactMap { Double($0) }
            guard nums.count >= 3 else { continue }
            out.append(SIMD3(nums[nums.count - 3], nums[nums.count - 2], nums[nums.count - 1]))
        }
        guard out.count == 24, out.allSatisfy({ (0...100).contains($0.x) && abs($0.y) < 150 && abs($0.z) < 150 }) else { return nil }
        return out
    }

    /// Patches used to normalise exposure (neutral 8, 6.5, 5: well exposed, never clipped).
    public static let exposureNeutrals = [19, 20, 21]

    // MARK: colour conversions

    static let d50 = SIMD3<Double>(0.96422, 1.0, 0.82521)
    static let d65 = SIMD3<Double>(ColorMath.whiteD65.x, ColorMath.whiteD65.y, ColorMath.whiteD65.z)
    /// Bradford D50 → D65.
    static let bradfordD50toD65: [Double] = [0.9555766, -0.0230393, 0.0631636, -0.0282895, 1.0099416, 0.0210077, 0.0122982, -0.0204830, 1.3299098]

    static func mul(_ m: [Double], _ v: SIMD3<Double>) -> SIMD3<Double> {
        SIMD3(m[0] * v.x + m[1] * v.y + m[2] * v.z, m[3] * v.x + m[4] * v.y + m[5] * v.z, m[6] * v.x + m[7] * v.y + m[8] * v.z)
    }

    public static func inverse3(_ m: [Double]) -> [Double]? {
        let a = m[0], b = m[1], c = m[2], d = m[3], e = m[4], f = m[5], g = m[6], h = m[7], i = m[8]
        let det = a * (e * i - f * h) - b * (d * i - f * g) + c * (d * h - e * g)
        guard abs(det) > 1e-12 else { return nil }
        return [(e * i - f * h) / det, (c * h - b * i) / det, (b * f - c * e) / det,
                (f * g - d * i) / det, (a * i - c * g) / det, (c * d - a * f) / det,
                (d * h - e * g) / det, (b * g - a * h) / det, (a * e - b * d) / det]
    }

    static func xyz(fromLab l: SIMD3<Double>, white: SIMD3<Double>) -> SIMD3<Double> {
        let fy = (l.x + 16) / 116, fx = fy + l.y / 500, fz = fy - l.z / 200
        func inv(_ t: Double) -> Double { let t3 = t * t * t; return t3 > 216.0 / 24389.0 ? t3 : (116 * t - 16) / (24389.0 / 27.0) }
        return SIMD3(inv(fx), inv(fy), inv(fz)) * white
    }

    /// Reference patch in linear Display P3 (D65), Y of white = 1 scale.
    public static func referenceLinearP3(_ labD50: SIMD3<Double>) -> SIMD3<Double> {
        let xyz65 = mul(bradfordD50toD65, xyz(fromLab: labD50, white: d50))
        return mul(inverse3(ColorMath.p3ToXYZ)!, xyz65)
    }

    public static func labD65(_ p3: SIMD3<Double>) -> SIMD3<Double> {
        let l = ColorMath.lab(r: p3.x, g: p3.y, b: p3.z); return SIMD3(l.l, l.a, l.b)
    }

    public static func deltaE(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double {
        ColorMath.deltaE2000(a.x, a.y, a.z, b.x, b.y, b.z)
    }

    // MARK: sampling

    /// Chart corners in normalised image coordinates (0...1, origin top-left): centres of the corner patches
    /// dark skin (top-left), bluish green (top-right), black (bottom-right), white (bottom-left).
    public struct Corners: Codable, Equatable, Sendable {
        public var topLeft: SIMD2<Double>, topRight: SIMD2<Double>, bottomRight: SIMD2<Double>, bottomLeft: SIMD2<Double>
        public init(topLeft: SIMD2<Double>, topRight: SIMD2<Double>, bottomRight: SIMD2<Double>, bottomLeft: SIMD2<Double>) {
            self.topLeft = topLeft; self.topRight = topRight; self.bottomRight = bottomRight; self.bottomLeft = bottomLeft
        }
        /// "x1,y1,x2,y2,x3,y3,x4,y4" in the order above.
        public init?(_ s: String) {
            let v = s.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            guard v.count == 8, v.allSatisfy({ (0...1).contains($0) }) else { return nil }
            self.init(topLeft: SIMD2(v[0], v[1]), topRight: SIMD2(v[2], v[3]), bottomRight: SIMD2(v[4], v[5]), bottomLeft: SIMD2(v[6], v[7]))
        }
        /// Centre of patch (row 0...3, column 0...5), bilinear between the corner patch centres (handles perspective mildly).
        public func centre(row: Int, col: Int) -> SIMD2<Double> {
            let u = Double(col) / 5, v = Double(row) / 3
            let top = topLeft + (topRight - topLeft) * u, bottom = bottomLeft + (bottomRight - bottomLeft) * u
            return top + (bottom - top) * v
        }
        /// Patch pitch in normalised units (distance between neighbouring patch centres).
        public var pitch: SIMD2<Double> {
            let w = (simd_len(topRight - topLeft) + simd_len(bottomRight - bottomLeft)) / 2 / 5
            let h = (simd_len(bottomLeft - topLeft) + simd_len(bottomRight - topRight)) / 2 / 3
            return SIMD2(w, h)
        }
    }

    static func simd_len(_ v: SIMD2<Double>) -> Double { (v * v).sum().squareRoot() }

    /// Median RGB of the central 40 % of each patch. Row 0 of `img` is the top of the image.
    public static func sample(_ img: LinearImage, corners: Corners, fraction: Double = 0.4) -> [SIMD3<Double>] {
        let p = corners.pitch
        let hw = max(1, Int(p.x * Double(img.width) * fraction / 2)), hh = max(1, Int(p.y * Double(img.height) * fraction / 2))
        var out: [SIMD3<Double>] = []
        for r in 0..<4 {
            for c in 0..<6 {
                let ctr = corners.centre(row: r, col: c)
                let cx = Int(ctr.x * Double(img.width)), cy = Int(ctr.y * Double(img.height))
                var ch: [[Float]] = [[], [], []]
                for y in max(0, cy - hh)...min(img.height - 1, cy + hh) {
                    for x in max(0, cx - hw)...min(img.width - 1, cx + hw) {
                        let i = (y * img.width + x) * 3
                        for k in 0..<3 { ch[k].append(img.pixels[i + k]) }
                    }
                }
                func med(_ a: [Float]) -> Double { let s = a.sorted(); return s.isEmpty ? 0 : Double(s[s.count / 2]) }
                out.append(SIMD3(med(ch[0]), med(ch[1]), med(ch[2])))
            }
        }
        return out
    }

    // MARK: fit

    public struct Fit: Codable, Equatable, Sendable {
        /// Row-major 3×3, applied to scene-linear RGB (CIRAWFilter linearSpaceFilter). Rows sum to 1: neutral stays neutral.
        public var ccm: [Double]
        /// Scale that brought the measured neutrals to the reference (reported; not baked into the CCM).
        public var exposureScale: Double
        public var deltaEBefore: [Double]
        public var deltaEAfter: [Double]
        public var meanBefore: Double { deltaEBefore.reduce(0, +) / Double(max(deltaEBefore.count, 1)) }
        public var meanAfter: Double { deltaEAfter.reduce(0, +) / Double(max(deltaEAfter.count, 1)) }
        public var maxAfter: Double { deltaEAfter.max() ?? 0 }
    }

    /// Weighted least squares M·measured ≈ reference over the patches, with M·(1,1,1) = (1,1,1) (white preserved),
    /// after scaling the measurement so the mid neutrals match. Patches that are clipped (any channel ≥ 0.98 before
    /// scaling) are left out.
    public static func fit(measured: [SIMD3<Double>], reference: [SIMD3<Double>] = referenceLabD50.map(referenceLinearP3)) -> Fit? {
        guard measured.count == 24, reference.count == 24 else { return nil }
        let nm = exposureNeutrals.map { measured[$0].y }.reduce(0, +), nr = exposureNeutrals.map { reference[$0].y }.reduce(0, +)
        guard nm > 1e-6 else { return nil }
        let k = nr / nm
        let use = (0..<24).filter { measured[$0].max() < 0.98 }
        let m = measured.map { $0 * k }
        // Constraint rows sum to 1: write each row as (a, b, 1 - a - b) → r = a(x - z) + b(y - z) + z: 2 unknowns per row.
        var ccm = [Double](repeating: 0, count: 9)
        for row in 0..<3 {
            var s11 = 0.0, s12 = 0.0, s22 = 0.0, t1 = 0.0, t2 = 0.0
            for i in use {
                let p = m[i], target = reference[i][row] - p.z
                let u = p.x - p.z, v = p.y - p.z
                s11 += u * u; s12 += u * v; s22 += v * v; t1 += u * target; t2 += v * target
            }
            let det = s11 * s22 - s12 * s12
            guard abs(det) > 1e-12 else { return nil }
            let a = (t1 * s22 - t2 * s12) / det, b = (s11 * t2 - s12 * t1) / det
            ccm[row * 3] = a; ccm[row * 3 + 1] = b; ccm[row * 3 + 2] = 1 - a - b
        }
        let refLab = reference.map(labD65)
        let before = (0..<24).map { deltaE(labD65(m[$0]), refLab[$0]) }
        let after = (0..<24).map { deltaE(labD65(mul(ccm, m[$0])), refLab[$0]) }
        return Fit(ccm: ccm, exposureScale: k, deltaEBefore: before, deltaEAfter: after)
    }

    /// Per-patch ΔE00 between two models' charts (each already corrected and exposure-normalised): Gate 3.
    public static func compare(_ a: [SIMD3<Double>], _ b: [SIMD3<Double>], referenceLab: [SIMD3<Double>] = referenceLabD50) -> [Double] {
        func norm(_ p: [SIMD3<Double>]) -> [SIMD3<Double>] {
            let n = exposureNeutrals.map { p[$0].y }.reduce(0, +)
            let r = exposureNeutrals.map { referenceLinearP3(referenceLab[$0]).y }.reduce(0, +)
            return p.map { $0 * (n > 0 ? r / n : 1) }
        }
        let na = norm(a), nb = norm(b)
        return (0..<min(na.count, nb.count)).map { deltaE(labD65(na[$0]), labD65(nb[$0])) }
    }
}

/// What `raw-bench chart` writes: enough to recompute Gate 3 later without the DNG.
public struct ChartMeasurement: Codable, Equatable, Sendable {
    public var model: String
    public var rawKind: String?
    public var file: String
    public var corners: ColorChecker.Corners
    /// Patches measured in the scene-linear decode, before and after the fitted CCM (re-decoded, not just multiplied).
    public var measured: [SIMD3<Double>]
    public var corrected: [SIMD3<Double>]?
    public var fit: ColorChecker.Fit
    /// ΔE00 vs the reference after re-decoding with the CCM (checks that linearSpaceFilter acts where we measured).
    public var verifiedDeltaE: [Double]?
    /// CIELAB D50 reference used for the fit when it was not the built-in X-Rite table (`--reference`); nil = built-in.
    public var referenceLab: [SIMD3<Double>]?
    public var referenceSource: String?

    public init(model: String, rawKind: String?, file: String, corners: ColorChecker.Corners, measured: [SIMD3<Double>],
                corrected: [SIMD3<Double>]?, fit: ColorChecker.Fit, verifiedDeltaE: [Double]?,
                referenceLab: [SIMD3<Double>]? = nil, referenceSource: String? = nil) {
        self.model = model; self.rawKind = rawKind; self.file = file; self.corners = corners; self.measured = measured
        self.corrected = corrected; self.fit = fit; self.verifiedDeltaE = verifiedDeltaE
        self.referenceLab = referenceLab; self.referenceSource = referenceSource
    }
}
