import Foundation

extension LookSpec {
    /// Pure modifier: deepening contrast, density and saturation outside skin bands.
    /// Amount in 0...1 (0 = unchanged, > 0 deepens toward Agfa Ultra character).
    public func deepened(_ amount: Float = 0.7) -> LookSpec {
        guard amount > 0, monoWeights == nil else { return self }
        let a = min(max(amount, 0), 1)
        var copy = self
        if copy.black > 0.008 {
            copy.black = copy.black * (1 - a) + 0.008 * a
        }
        copy.contrast = copy.contrast * (1 - a) + (copy.contrast + 0.10) * a
        copy.pivot = copy.pivot * (1 - a) + 0.45 * a
        copy.density = min(copy.density + 0.06 * a, 0.12)
        copy.saturation = copy.saturation * (1 - a) + (copy.saturation + 0.075) * a
        copy.neutralDrift = copy.neutralDrift + 0.005 * a
        copy.bands = copy.bands.map { band in
            var b = band
            if b.centre < 30 || b.centre > 75 {
                b.lightness = b.lightness * (1 - a) + (b.lightness - 0.03) * a
            }
            return b
        }
        return copy
    }
}
