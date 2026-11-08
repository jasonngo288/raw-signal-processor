# Roadmap (target architecture, decided by the user 2026-11-08)

```
AVFoundation: Bayer RAW (+ HEIC from the same shutter press, as reference)
   │
   ├─► Vision + CIAreaHistogram (small render, background)
   │      → ImageContext: scene, faces, person mask, saliency, log-histogram, CCT, ISO
   │      → DecisionEngine: bounded parameters, written into the recipe
   ▼
CIRAWFilter (decoderVersion pinned, every parameter explicit)
   │  NR, sharpening, local tone map, lens correction: from DecisionEngine
   │  linearSpaceFilter: per-model calibrated CCM + exposure (scene-linear)
   ▼
Core Image graph on GPU, float16
   │  skin / subject protection with CIBlendWithMask (Vision person mask)
   │  Look: CIColorCubeWithColorSpace (film LUT, blended by context)
   │  Grain / halation: small custom Metal CIKernel
   ▼
CIContext.heif10Representation → HEIC 10-bit P3 + recipe JSON
```

Status legend: ✅ done and tested in CI · 🟡 partial · ⏳ needs a device / lab data · 🔁 done differently (reason given).
"Where" points at the code. Evidence lives in WORK_LOG.md.

| # | Roadmap item | Status | Where | Notes / what is left |
|---|---|---|---|---|
| 1 | AVFoundation Bayer RAW, wide camera | 🟡 ⏳ | `Sources/CaptureKit/CaptureService.swift` | Compiles for iOS in CI; never run on a device yet. No app UI. Exposure facts come from the photo's own EXIF; a failed RAW is an error, not a silent fallback. |
| 2 | HEIC from the same press as reference | 🟡 ⏳ | same (`processedFormat: hevc` in one `AVCapturePhotoSettings`) | Bench still uses Apple's CIRAWFilter decode as reference until device captures exist. |
| 3 | Analysis on a small render, in background | ✅ | `Developer.analyze`, `analyzeInBackground` | Stats + histogram at 512 px; **Vision at 1024 px** (faces/people missed at 512, WORK_LOG 2026-11-07). |
| 4 | Vision: scene, faces, person mask, saliency | ✅ | `VisionAnalyzer.enrich` | Each request independent; failure leaves only its fields nil. |
| 5 | CIAreaHistogram | ✅ | `Renderer.lumaHistogram` | 64 bins of display-encoded luminance (log-like). Pure-Swift percentiles kept for the rules. |
| 6 | ImageContext: scene, faces, mask, saliency, histogram, CCT, ISO | ✅ | `SceneContext` (+ `Developer.Analysis.personMask`, the mask image itself is not serialised) | CCT/tint = the camera's white-balance estimate (CIRAWFilter neutral defaults), not a separate estimator. |
| 7 | DecisionEngine bounded + logged | ✅ | `DecisionEngine` | Every reason is in `recipe.decisions`. Labels, saliency, histogram and CCT are measured but no rule uses them yet. |
| 8 | decoderVersion pinned, parameters explicit | ✅ | `DecoderPolicy`, `RawDecoder.decode`, `Developer.analyze` | Fixed preference list (8 → 8.dng → 7 …); analysis decodes use the same pinned version; explicit modes fail if no policy version exists. The `appleDefault` bench reference stays on the OS default on purpose. RAW 9 not added until benched. |
| 9 | NR, sharpening, LTM, lens correction from DecisionEngine | ✅ | `DecisionEngine` | LTM and lens correction are reported as unsupported for all current test files on macOS 15.8. |
| 10 | linearSpaceFilter: per-model CCM + exposure | 🟡 ⏳ | `Calibration.swift`, `RawDecoder` | Mechanism + exact lookup (model identifier from DNG UniqueCameraModel, then camera name) + exposure inside the matrix done and tested; **no measured entries** (needs ColorChecker per model → Gate 3). |
| 11 | Core Image on GPU, float16 | ✅ | `Renderer` (`RGBAh`, extended linear P3) | |
| 12 | Skin / subject protection, CIBlendWithMask + person mask | ✅ | `Renderer.protectSkin`, DecisionEngine rule | Holds back 50 % of the look on people; skipped for black-and-white looks (judged from the LUT). Tested (`testSkinProtectionReducesLookOnPeople`). The Vision mask also covers held objects. Saliency not used yet. |
| 13 | Look via CIColorCubeWithColorSpace, blended by context | ✅ | `Renderer.applyLook`, `DecisionEngine.lookIntensityOffset` | Skin protection on people + scene-dependent intensity (dark −0.10, ISO ≥ 1600 −0.05, people −0.05, landscape +0.05; bounded −0.15…+0.10, logged). The stock itself never changes per photo (one roll = one stock); `lookIntensityOffset = 0` locks it. |
| 14 | Grain / halation as Metal CIKernel | 🔁 | `FilmFinisher` | Built-in filter chain (CIRandomGenerator, blur, compositing), verified resolution-independent. Swap to a Metal kernel only if on-device profiling shows a need. |
| 15 | heif10Representation, P3, recipe JSON | ✅ | `Renderer.export(recipe:)`, bench `save()` | Recipe embedded in EXIF UserComment by `Renderer.export`; the sidecar .recipe.json is written by the caller (bench/CLI). |

## Order of the remaining work
1. Device: run CaptureService on an iPhone (14 Pro / 15 Pro first), keep DNG + HEIC pairs; bench against the paired HEIC.
2. Lab: ColorChecker under D65 / A per model → fill `calibration/models.json` → Gate 3 (ΔE00 < 2 across models).
3. ~~Context-driven look intensity~~ done 2026-11-08 (saliency still unused).
4. On-device performance (iPhone 12 floor) → decide on Metal kernels for grain/halation.

---

## ⭐ EXTRAS — not in the roadmap, kept as PLUGINS (review after the roadmap is done)

> These were added during the spike because measurements showed a benefit. They are **plugins**: unplug any time
> with `RenderSettings.plugins = []` / `["id"]`, `Developer(plugins: .none)`, or `raw-bench --plugins none`.
> With no plugins the pipeline is exactly the roadmap core above. Each render lists the plugins that ran in
> `recipe.plugins` (plugins that changed something) and `recipe.pluginsEnabled`. Decide after the roadmap: keep (move into the core), keep as an option, or delete.

| Plugin id | What it does | Evidence so far | Cost |
|---|---|---|---|
| `highlightRecovery` | Where Apple's tone curve clips data the RAW still holds: EDR decode → highlight clarity → `CIToneMapHeadroom` → blended back only near white. Skips itself (logged) where `CIToneMapHeadroom` does not exist (iOS 17). | IMG_1901 clipped 60 % → 45 %, ΔE on unclipped pixels 0.41; mooncake 6.7 % → 2.2 % (run 42365269279) | +1 analysis decode, +1 full decode when it fires |
| `cameraMatch` | With `settings.cameraReference` (the same-press camera HEIC): exposure offset in the CIRAWFilter decode from mid-tone quantiles, then a monotone luminance curve (ToneMatch, quantile matching) as a LUT before the look. Does nothing without a reference. | First device pairs (iPhone 14 Pro): before, +0.63 / +0.31 EV brighter and 2.1 / 6.6 % clipped vs the HEIC's 0.1 %; Python prototype of the curve stage alone: mid EV → 0.00, ΔE76 9.9 → 3.7 (shot 1), clipping not recoverable after the decode (shot 2) → exposure stage. CI numbers: `raw-bench pairs` | 1 HEIC read at 512 px (×2), 1 LUT |
| `vignette` | Corner darkening from the stock's `FilmFinish.vignette` | visual only | 1 filter |

Capture option (CaptureKit, not a DevelopPlugin; off by default, Bayer stays the roadmap path):

| Option | What it does | Evidence so far | Cost |
|---|---|---|---|
| `RawPreference.proRAWWhenSupported` | Ask for Apple ProRAW where `isAppleProRAWSupported` (Pro models): Apple's multi-frame fusion (Smart HDR / Deep Fusion) merged into a linear DNG, decoded by the same CIRAWFilter pipeline. Falls back to Bayer elsewhere. Decided from capabilities, never model names (`RawTierPolicy`). | none yet: needs ProRAW captures from the user's 14 Pro (`rawKind` in capture.json) | ~25 MB per 12 MP DNG, slower capture |

Other extras that are tooling, not pipeline: `sceneLinear` mode, `raw-bench`, public corpus, metrics/gates.
