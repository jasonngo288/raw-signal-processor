# Metrics

All metrics are computed on **display-linear Display P3** values rendered by Core Image at a fixed
analysis size (long edge 1024 px by default, `--long-edge`), channels clamped to 0…1 for "what an SDR
display shows". Candidate and reference come from the **same RAW file** and are cropped to a common size,
so the comparison is pixel-aligned.

| metric | definition | why |
|---|---|---|
| ΔE00 mean / median / p95 | CIEDE2000 per pixel (kL=kC=kH=1) vs `appleDefault`, Lab D65 | colour/tone distance to Apple's decode |
| ΔE00 unclipped | mean ΔE00 over pixels where the reference has every channel < 0.98 | how much we changed what Apple rendered correctly (highlight recovery is expected to change clipped pixels) |
| blackP1 / blackP5 | 1st / 5th percentile of luminance Y | haze / lifted blacks (our old pipeline: 0.012–0.033 vs Apple 0.0003) |
| meanY / medianY | mean / median Y | overall brightness |
| clippedFraction | share of pixels with any channel ≥ 0.98 | blown highlights |
| localContrast | std-dev of log2(Y) minus its Gaussian blur (σ = 2 px) | perceived sharpness / micro contrast |
| highlightRingMeanY | mean Y in the ring 5…40 px (square) around clipped pixels; nil if none | glow / halo from tone mapping |
| meanChroma | mean CIELAB C* | saturation |

CIEDE2000 is verified against the 34 Sharma–Wu–Dalal reference pairs (`Tests/RawCoreTests/Fixtures`).

Reading the numbers: a variant is acceptable only if ΔE is explained by an intended change (e.g. a look),
black p1 is not raised, halo ring is not brighter and local contrast is not lower than `appleDefault`.

## Native-pixel sharpness (reported, not a gate yet)

Every metric above runs at a 1024 px long edge. On a 12 MP file that is a ~4x downscale, which erases the
sharpening Apple applies at native scale (`sharpnessAmount` ≈ 0.89 on iPhone Bayer): halos, overshoot and
waxy noise reduction are invisible there. The metrics below run on **native-resolution crops** (`scaleFactor` 1):
a 1024² centre crop plus 4 tiles of 1024² centred on the quarter points (25 %/75 % of width and height, clamped into
the image; they may overlap the centre on small files). Candidate and `appleDefault` crops are cut from the same
pixels. Switch: `raw-bench bench <dir> --out <dir> --native [--native-stock NAME|none]` (rows in `summary.md` and
`summary.json` under `native`) and `raw-bench compare <raw> --mode … --native`. Cost: one extra full-resolution develop
per variant (≈ 6 variants), so it is off by default. Values are the mean over the 5 crops. Code: `SharpnessMetrics` /
`SharpnessComparison` / `SharpnessSummary` (`ImageMetrics.swift`, pure Swift), `Sources/RawBench/Native.swift`.

All three work on log2 Y of display luminance. Edge sites and the flat-pixel mask are taken from the `appleDefault`
crop, so the candidate is measured on exactly the pixels Apple was.

| metric | definition | pass (plan `SMARTPHONE_LOOK_PLAN_2026-11-11.md` §3) |
|---|---|---|
| edge overshoot % | strongest 1 % of the gradient (log2 Y blurred σ 1; ≥ 0.05, thinned to local maxima along the normal). Per edge: profile ±6 px along the gradient normal (bilinear); step = mean(t = +4…+6) − mean(t = −6…−4), edges with step < 0.25 EV skipped; overshoot = ((max over t ≥ 0 − high plateau) + (low plateau − min over t ≤ 0)) / 2 / step. Reported: median over edges, in %. "vs Apple %" = candidate / Apple − 1 | **−20 % or more vs Apple** for film stocks on iPhone files (plan said −30 %; the 2026-11-11 grid reached −36 % only on IMG_1901 / mooncake at × 0.55 and −22 % on mug). Non-iPhone files whose default is already low (Pixel 0.5) barely move: their overshoot is not CIRAWFilter sharpening |
| HF energy ratio | variance of the DoG band σ 0.7–2 px divided by that of σ 2–6 px (the "fine / coarse" value), candidate over `appleDefault` | **0.6–0.85**; < 0.5 = mush; ≈ 1 = Apple's detail |
| flat texture | std-dev of the log2 Y high-pass (σ 2 px) over flat pixels: gradient (log2 Y blurred σ 2) < 0.02 EV/px, 0.02 < Y < 0.9; ratio to Apple on the same pixels (needs ≥ 1000 flat pixels) | **after grain 0.9–1.3× Apple** (waxy below, noisy above). Before grain it is reported only: any sharpening cut lowers it (2026-11-11 grid: 0.83 at Apple's sharpness × 0.55 on IMG_1901; 0.87–0.96 even with Apple's own sharpness, because the look's tone softens it), so ≥ 0.9 before grain is not reachable |

"Before grain" is the stock variant with `finish.grainAmount = 0` (halation and vignette kept); "after grain" is the
stock as shipped. Base renders (`explicit`, `auto`, `auto core`) have no grain.

Sanity: `explicit` is `appleDefault` with its defaults written back, so its overshoot change must be ≈ 0 %, HF ratio ≈ 1
and flat ratio ≈ 1. If not, the metric (or crop alignment) is broken before the render is.

Limits: the median of the overshoot ignores edges that touch other edges within 6 px; log2 Y near black amplifies
noise (the flat mask drops Y < 0.02); one file is one scene, so judge on the set, and keep tuning and holdout files
separate as for the gates. Unit tests: `SharpnessMetricsTests` (synthetic step, blur, noise).
