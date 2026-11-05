# Metrics

All metrics are computed on **display-linear Display P3** values rendered by Core Image at a fixed
analysis size (long edge 1024 px by default, `--long-edge`), channels clamped to 0…1 for "what an SDR
display shows". Candidate and reference come from the **same RAW file** and are cropped to a common size,
so the comparison is pixel-aligned.

| metric | definition | why |
|---|---|---|
| ΔE00 mean / median / p95 | CIEDE2000 per pixel (kL=kC=kH=1) vs `appleDefault`, Lab D65 | colour/tone distance to Apple's decode |
| blackP1 / blackP5 | 1st / 5th percentile of luminance Y | haze / lifted blacks (our old pipeline: 0.012–0.033 vs Apple 0.0003) |
| meanY / medianY | mean / median Y | overall brightness |
| clippedFraction | share of pixels with any channel ≥ 0.98 | blown highlights |
| localContrast | std-dev of log2(Y) minus its Gaussian blur (σ = 2 px) | perceived sharpness / micro contrast |
| highlightRingMeanY | mean Y in the ring 5…40 px (square) around clipped pixels; nil if none | glow / halo from tone mapping |
| meanChroma | mean CIELAB C* | saturation |

CIEDE2000 is verified against the 34 Sharma–Wu–Dalal reference pairs (`Tests/RawCoreTests/Fixtures`).

Reading the numbers: a variant is acceptable only if ΔE is explained by an intended change (e.g. a look),
black p1 is not raised, halo ring is not brighter and local contrast is not lower than `appleDefault`.
