---
name: hdr-tone-mapping
description: HDR and tone-mapping know-how mapped onto this repo's pipeline (CIRAWFilter base, highlightRecovery, cameraMatch/ToneMatch, looks, halation). Use when designing, reviewing or debugging anything that changes tone, contrast, black level, highlights, saturation under contrast change, local contrast or glare — before touching Developer, Plugins, ToneMatch, Look, FilmFinisher, Presets2026 or DecisionEngine tone rules. Project-only.
---

# HDR & tone mapping for raw-signal-processor

Source: R. Mantiuk, "High dynamic range and tone mapping" (Advanced Graphics and Image Processing, University of
Cambridge), lecture slides 1–65. The user keeps the PDF locally (`~/Downloads/07_HDR_and_tone_mapping.pdf`); it is
**not** in the repo and must not be committed. Below is a summary in our own words plus how each idea maps onto
this codebase. Repo rules (AGENTS.md) always win over anything here.

## 1. Vocabulary (use these words in recipes, WORK_LOG and reviews)
- **Dynamic range** = max/min luminance (min taken where the signal is still above noise). Say it in **stops**
  (log2): our `SceneContext.dynamicRangeStops` is p99.9 − p1 of log2 luminance of the scene-linear render.
- **Scene-referred** (light in the scene, linear, unbounded) vs **display-referred** (what the screen emits,
  bounded). Tone mapping is the step between them. In this repo: `sceneLinear` mode and the linear working space are
  scene-referred; Apple's CIRAWFilter tone (baseline exposure, boost, shadow boost, local tone map) does the
  scene → display step; looks (`.cube`, `BuiltInLook`, `Preset26`) work display-referred in encoded Display P3.
- **Luminance vs luma.** Luminance = linear weighted sum (`ColorMath.p3LuminanceWeights` on linear values). Luma =
  the same weights on gamma-encoded values. Tone arithmetic is defined on luminance. `Renderer.lumaHistogram` is
  luma on purpose (log-like spacing, same measure on both sides of a comparison); never mix the two in one rule.

## 2. Three basic operations and what they do to an image
| operation | effect | in this repo |
|---|---|---|
| **multiply** `B·L` | brighter/darker; dynamic range unchanged | exposure, `linearExposureEV`, cameraMatch exposure offset, calibration exposure. Safe for contrast; only clipping changes. |
| **power** `(L/Lwhite)^c` | stretches/compresses dynamic range around white; brightness shift is a side effect | contrast/S-curve parts of looks and presets; ToneMatch curve slopes. Always say what the reference white is. |
| **add** `L + F` | lifts the black level ("fog", flare), mostly darks; reduces dynamic range | lifted toe in looks; Apple's shadow boost behaves like this. Gate 2 guards it: **black p1 must not rise > +0.002**. The ProRAW black-lift fix (cameraMatch lowers `boostShadowAmount`) was exactly an "addition" problem. |

Review question for any tone change: *which of the three is it really doing, and is that the intent?*

## 3. Display model (not implemented — only if we ever adapt to viewing conditions)
Gain–gamma–offset: emitted L = (Lpeak − Lblack)·V^γ + Lblack + Lrefl, with screen reflection Lrefl = k/π·E_amb
(k ≈ 0.5–1 %, E_amb in lux). Bright surroundings shrink the usable range (log10(Lpeak/(Lblack+Lrefl))), so a
display-adaptive operator compresses more and lifts darks. On iOS the system (EDR, True Tone, auto-brightness)
owns this; for us it is at most a future **plugin** (AGENTS rule 10), never a core change.

## 4. Global tone curves
- The ideal curve is slope 1 in log–log (change nothing). A display's limited range forces a compromise between
  **clipping** and **contrast compression**; a global curve can only trade one for the other.
- **Sigmoid / film curves** (toe, straight part, shoulder) are the classic camera answer and cheap. Map to
  `BuiltInLook.film(toe:contrast:shoulder:)` and the `Preset26` curves. A sigmoid's key is usually the scene's
  log-average luminance; ours is `SceneContext.logP50` (median of log2 luminance) — the dark-scene rule uses it.
- **Histogram equalization**: the cumulative histogram as the curve gives steep slopes where many pixels sit. On its
  own it over-stretches populated tones (noise, posterisation); the fix is a **ceiling on the slope** (Larson et al.
  1997: clip bins above the ceiling, redistribute, repeat). `ToneMatch.curve` is the same family (quantile matching
  to the camera HEIC) and keeps the ceiling idea: per-point gain bounded to ±1.5 stops and slope ≤ 1 at the top
  (the unbounded top once blew a wall hotspot into a hard white oval, CI 42491918370). Keep such bounds.

## 5. Colour under tone changes
- Operators that work on luminance must bring colour back: `C_out = (C_in / L_in)^s · L_out` per linear channel,
  s = saturation. s = 1 keeps ratios (hue) but compressed contrast pushes saturated colours **out of gamut**;
  s < 1 brings them back. Alternative: do it in CIE u′v′ (moves chroma toward the white point by s), which keeps
  luminance exact.
- In this repo `ToneMatch.lut` scales colour by the luminance ratio and pulls out-of-gamut colour toward luma instead
  of clipping — the same idea. Any new tone stage must say how it handles saturated reds/blues after compression.

## 6. Base–detail (local) tone mapping
- Image ≈ illumination × reflectance. Illumination varies slowly and carries most of the range; reflectance carries
  detail with < 100:1 range and is what the eye judges. Compress the base (illumination), keep the detail.
- How the base is found decides the artefacts: **Gaussian blur → halos** at strong edges; **bilateral**
  (Durand & Dorsey 2002) keeps edges better, still some bleeding; **WLS** (Farbman et al. 2008) smoother base with
  sharp edges, stronger effect with fewer artefacts. **Retinex** removes small log-gradients (illumination);
  **gradient-domain** compression (Fattal et al. 2002) attenuates large gradients and keeps/amplifies small ones.
- In this repo: Apple's `localToneMapAmount` is the local operator we steer (DecisionEngine raises it for DR > 9
  stops); `Renderer.highlightClarity` is a large-radius unsharp mask = Gaussian base/detail, which is why we measure
  the **halo ring** (Gate 2: ring must not get > +0.01 brighter) and **local contrast in bright areas**. A new local
  operator must be benched on those metrics, pixel-aligned vs `appleDefault`, never judged by ΔE alone.

## 7. Glare / bloom / halation
- The eye (and lenses, film) scatter light: a point spreads into a PSF; bright sources get a glow. Painting it in
  makes lights look brighter than the display can show (glare illusion). The exact PSF shape matters little for the
  brightness illusion; a **sum of Gaussians** is the practical approximation.
- Apply glare **only to very bright / clipped pixels** (`I + I_clipped * G − I_clipped`), not the whole frame:
  whole-frame convolution lowers contrast and sharpness everywhere.
- In this repo: `FilmFinisher.halation` already follows that — luminance threshold mask → Gaussian blur in linear
  light → red-weighted tint → added back. Keep the threshold; do blur in linear light (blurring HDR vs LDR pixels
  gives visibly different results, e.g. motion blur). Halation is a look/finish effect and runs after the base.

## 8. HDR → SDR in our pipeline (where each idea lives)
CIRAWFilter decode (scene-linear, CCM in `linearSpaceFilter`) → Apple tone (scene → display, LTM)
→ optional `highlightRecovery` plugin: EDR decode (values > 1 kept) → highlight clarity → `CIToneMapHeadroom`
headroom → 1 → blended back only near white (luminance 0.80 → 0.97 mask) → optional `cameraMatch` (exposure =
multiply; boostShadow = remove an "addition"; ToneMatch curve = bounded histogram matching) → look (display-referred)
→ skin protection → halation (selective glare) + grain → export.

## 9. Checklist for any tone-related change
1. Name the operation (multiply / power / add / curve / local / glare) and the domain (scene-linear, Apple's display
   output, encoded P3). Luminance or luma?
2. Does it change dynamic range, black level, clipping? Predict the sign of: black p1, clipped %, halo ring,
   bright-area local contrast, ΔE00 unclipped (docs/METRICS.md).
3. Is the slope bounded (no stretch of noise or posterised bands)? Is colour handled under compression (gamut)?
4. Core or plugin? Anything not in docs/ROADMAP.md is a `DevelopPlugin`, removable with `plugins = []`, listed in
   `recipe.plugins` and the ROADMAP extras table. Looks never repair tone (Goal 3).
5. Every automatic decision logs its reason in the recipe; `appleDefault` carries no overrides.
6. Evidence: `raw-bench bench originals` (+ corpus in CI), `raw-bench pairs docs` for device pairs, Gates 1/2 per
   file, tuning vs holdout reported separately — **never tune a threshold on holdout files**.
