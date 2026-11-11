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
| 1 | AVFoundation Bayer RAW, wide camera | ✅ (device) | `Sources/CaptureKit/CaptureService.swift`, demo app `App/` | Runs on device (iPhone 14 Pro, iOS 26.5.2; iPhone 15 Pro, iOS 26.6). Demo app (2026-11-09): capture → preview (camera HEIC) → Develop → result → change the look (re-finish the stored base, no new decode) → new photo; analysis runs in the background right after the press; every press is a folder in Files. Exposure facts come from the photo's own EXIF; a failed RAW is an error, not a silent fallback. |
| 2 | HEIC from the same press as reference | ✅ (device, `raw-bench pairs`, cameraMatch) | same (`processedFormat: hevc` in one `AVCapturePhotoSettings`) | 4 device pairs (`docs/2026-…`, `raw-bench pairs`; CI scans `docs/`). Gate 2 still uses Apple's CIRAWFilter decode as reference (originals + corpus have no HEIC); the device path with cameraMatch has no gate yet (audit 2026-11-09). |
| 3 | Analysis on a small render, in background | ✅ | `Developer.analyze`, `analyzeInBackground`, `Analysis.write/read` | Scene-linear stats at 512 px; one Apple render at 1024 px for clipping, the histogram and **Vision** (2026-11-09: was a separate 512 px decode) (faces/people missed at 512, WORK_LOG 2026-11-07). Can run at capture time and be stored next to the DNG (JSON + person-mask PNG + the camera HEIC's histograms); develop reuses it unless `staleReason` (schema, file, decoder version, plugins) says otherwise. |
| 4 | Vision: scene, faces, person mask, saliency | ✅ | `VisionAnalyzer.enrich` | Each request independent; failure leaves only its fields nil. |
| 5 | CIAreaHistogram | ✅ | `Renderer.lumaHistogram` | 64 bins of display-encoded luminance (log-like). Pure-Swift percentiles kept for the rules. |
| 6 | ImageContext: scene, faces, mask, saliency, histogram, CCT, ISO | ✅ | `SceneContext` (+ `Developer.Analysis.personMask`, stored as `person-mask.png`) | CCT/tint = the camera's white-balance estimate (CIRAWFilter neutral defaults), not a separate estimator. |
| 7 | DecisionEngine bounded + logged | ✅ | `DecisionEngine` | Every reason is in `recipe.decisions`. Labels are used by the look-intensity rule (landscape); saliency and CCT are measured but no rule uses them yet. Dark-scene threshold −5.35 set from tuning files only (audit 2026-11-09). |
| 8 | decoderVersion pinned, parameters explicit | ✅ | `DecoderPolicy`, `RawDecoder.decode`, `Developer.analyze` | Fixed preference list (8 → 8.dng → 7 …); analysis decodes use the same pinned version; explicit modes fail if no policy version exists. The `appleDefault` bench reference stays on the OS default on purpose. RAW 9 not added until benched. |
| 9 | NR, sharpening, LTM, lens correction from DecisionEngine | ✅ | `DecisionEngine` | LTM and lens correction are reported as unsupported for all current test files on macOS 15.8; on device (iOS 26) LTM is supported for ProRAW (15 Pro recipe), lens correction still not. |
| 10 | linearSpaceFilter: per-model CCM + exposure | 🟡 tooling ✅, data ⏳ | `Calibration.swift`, `ColorChecker.swift`, `raw-bench chart` / `gate3` | Mechanism + exact lookup done. Chart tool: samples the 24 patches in a scene-linear decode, fits a white-preserving 3×3 CCM (clipped patches left out), **re-decodes with it to verify**, writes the calibration entry. `gate3` compares models. Needs one ColorChecker shot per model. Open: ProRAW and Bayer of the same model share a key (separate key needed when both are calibrated). |
| 11 | Core Image on GPU, float16 | ✅ | `Renderer` (`RGBAh`, extended linear P3) | |
| 12 | Skin / subject protection, CIBlendWithMask + person mask | ✅ | `Renderer.protectSkin`, DecisionEngine rule | Holds back 50 % of the look on people; skipped for black-and-white looks (judged from the LUT). Tested (`testSkinProtectionReducesLookOnPeople`). The Vision mask also covers held objects. Saliency not used yet. |
| 13 | Look via CIColorCubeWithColorSpace, blended by context | ✅ | `Renderer.applyLook`, `DecisionEngine.lookIntensityOffset` | Skin protection on people + scene-dependent intensity (dark −0.10, ISO ≥ 1600 −0.05, people −0.05, landscape +0.05; bounded −0.15…+0.10, logged). The stock itself never changes per photo (one roll = one stock); `lookIntensityOffset = 0` locks it. |
| 14 | Grain / halation as Metal CIKernel | 🔁 | `FilmFinisher` | Built-in filter chain (CIRandomGenerator, blur, compositing), verified resolution-independent. Swap to a Metal kernel only if on-device profiling shows a need. |
| 15 | heif10Representation, P3, recipe JSON | ✅ | `Renderer.export(recipe:)`, bench `save()` | Recipe embedded in EXIF UserComment by `Renderer.export`; the sidecar .recipe.json is written by the caller (bench/CLI). |

## Order of the remaining work
1. ~~Device run + bench against the paired HEIC~~ done 2026-11-08/09 on iPhone 14 Pro + 15 Pro (4 pairs, all indoor; need ~30 incl. daylight, night, ProRAW).
2. Lab: ColorChecker under D65 / A per model → `raw-bench chart` → `calibration/models.json` → `raw-bench gate3` (ΔE00 < 2 across models). Tooling done 2026-11-09; shots pending.
3. ~~Context-driven look intensity~~ done 2026-11-08 (saliency still unused).
4. On-device performance (iPhone 12 floor, target < 1.5 s full-res develop, PLANNING phase 4) → decide on Metal kernels for grain/halation. Risk: analysis alone took 2.17 s (14 Pro) / 2.77 s (15 Pro) in the device recipes.
5. Develop is two stages (2026-11-09): `developBase` (decisions, decode, afterDecode plugins) and `finish` (look, skin, finish); a base can be finished with another stock without decoding. One `CIRAWFilter` per decode (file facts cached).
6. Film-look set 2026 (replaces MoodRoll's looks): 11 generated `LookSpec` looks + the LOG cube, acceptance tests (`FilmLooksTests`), `raw-bench looks` + `tools/look-review` for the user's feedback rounds, then a device check in the demo app.
7. Decide what the device path is (audit 2026-11-09): cameraMatch is on whenever a HEIC exists, so device output follows the camera HEIC (exposure up to −1 EV, shadow boost down to 0), and no gate covers it. Either add a device-pair gate or switch it off by default.

---

## ⭐ EXTRAS — not in the roadmap, kept as PLUGINS (review after the roadmap is done)

> These were added during the spike because measurements showed a benefit. They are **plugins**: unplug any time
> with `RenderSettings.plugins = []` / `["id"]`, `Developer(plugins: .none)`, or `raw-bench --plugins none`.
> With no plugins the pipeline is exactly the roadmap core above. Each render lists the plugins that ran in
> `recipe.plugins` (plugins that changed something) and `recipe.pluginsEnabled`. Decide after the roadmap: keep (move into the core), keep as an option, or delete.

| Plugin id | What it does | Evidence so far | Cost |
|---|---|---|---|
| `highlightRecovery` | Where Apple's tone curve clips data the RAW still holds: EDR decode → highlight clarity → `CIToneMapHeadroom` → blended back only near white. Skips itself (logged) where `CIToneMapHeadroom` does not exist (iOS 17). | IMG_1901 clipped 60 % → 45 %, ΔE on unclipped pixels 0.41; mooncake 6.7 % → 2.2 % (run 42365269279) | +1 analysis decode, +1 full decode when it fires |
| `cameraMatch` | With `settings.cameraReference` (the same-press camera HEIC): exposure offset in the CIRAWFilter decode from mid-tone quantiles, then a monotone luminance curve (ToneMatch, quantile matching) as a LUT before the look. Lowers Apple's shadow boost in the decode when our deep shadows sit > 0.5 EV above the HEIC's after the exposure match (never raises it). Does nothing without a reference. | First device pairs (iPhone 14 Pro): before, +0.63 / +0.31 EV brighter and 2.1 / 6.6 % clipped vs the HEIC's 0.1 %; Python prototype of the curve stage alone: mid EV → 0.00, ΔE76 9.9 → 3.7 (shot 1), clipping not recoverable after the decode (shot 2) → exposure stage. CI numbers: `raw-bench pairs` | 1 HEIC read at 512 px (×2), 1 LUT |
| `filmDevelop` | Decode profile of a stock (`FilmStock.develop`, set for the RR roll stocks from ISO class and character): scales Apple's per-file sharpness (x0.55 / 0.45 / 0.35 by stock ISO, x0.70 vivid, x0.45 portrait, floor 0.30, extra -0.10 with a face), caps luma NR at Apple's default (+0.05 at ISO >= 1600), highlight clarity x0.4, ProRAW detail 0.5 -> 0.2. Contrast, boost and local tone map are not touched. No stock, or a stock without `develop` = no-op. Runs in `auto` after DecisionEngine and highlightRecovery; every change is logged; `Developer.Base.developedFor` makes a re-finish with another profile say so. | Plan `.orchestration/smartphone-look/SMARTPHONE_LOOK_PLAN_2026-11-11.md`; numbers: WORK_LOG 2026-11-11 (filmDevelop) | none (decode parameters only) |
| `vignette` | Corner darkening from the stock's `FilmFinish.vignette` | visual only | 1 filter |
| `logLook` | Stocks whose LUT is made for log footage (`FilmStock.lookInput = .log`, e.g. the user's Cinematic Ice Blue): decodes the file scene-linear (Apple's tone off), Rec.2020 → log curve (Apple Log by default) → LUT → Display P3, one 65³ composite cube; unplugged, the LUT is applied to the display base and the recipe says so | visual only (2026-11-09): keeps highlights, muted log-grade look instead of the warm, harsh display-base result | +1 full scene-linear decode per finish of a log stock |

Capture option (CaptureKit, not a DevelopPlugin; off by default, Bayer stays the roadmap path):

| Option | What it does | Evidence so far | Cost |
|---|---|---|---|
| `RawPreference.proRAWWhenSupported` | Ask for Apple ProRAW where `isAppleProRAWSupported` (Pro models): Apple's multi-frame fusion (Smart HDR / Deep Fusion) merged into a linear DNG, decoded by the same CIRAWFilter pipeline. Falls back to Bayer elsewhere. Decided from capabilities, never model names (`RawTierPolicy`). | 1 ProRAW pair (iPhone 15 Pro, `docs/2026-11-08T15-48-31Z`): decodes through the pipeline; with cameraMatch ΔE00 2.09 vs its HEIC, black p1 0.0015 (HEIC 0.0013). ProRAW and Bayer of a model still share one calibration key. | ~25 MB per 12 MP DNG, slower capture |

Other extras that are tooling, not pipeline: `sceneLinear` mode, `raw-bench`, public corpus, metrics/gates.
