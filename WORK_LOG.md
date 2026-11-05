# Work log

Newest first. Each entry: what changed, why, evidence, what is NOT verified yet.

## 2026-11-05 — Fix: film looks made saturated blotches in deep shadows
**What**: `BuiltInLook.film` scaled colour by curve(y)/y. The old curve pivoted at 0.5 and did not pass
through 0, so the ratio reached ~40× in near-black pixels and noise became pure blue/red patches
(visible on `USER_mooncake` with warmNegative: blue door edge, red hair). Now the curve is anchored at 0 and 1,
the ratio is capped at 2× (any shortfall is added as neutral grey) and the film toe is a neutral offset.
Regression test `testLooksDoNotBlowUpShadowChroma`.
**Evidence (run 41985839152, 21/21 tests)**: USER_mooncake warmNegative ΔE00 p95 19.92 → 3.59, blotches gone in the preview;
Gate 1 holds on all 5 files (ΔE00 ≤ 1.1e-6). Contact sheets were reviewed visually (not committed).
**Seen visually on run 41985177812 contact sheets** (also): Apple's default decode of `IMG_1901` is heavily
blown (60 % clipped) while `sceneLinear` shows the sky/pavement detail is in the RAW → highlight recovery is the
biggest real opportunity; the current auto rule (max −0.3 EV) is far too weak. Not changed yet.

## 2026-11-05 — More test RAWs + previews readable from CI logs
**What**: added `originals/USER_mug.dng` and `originals/USER_mooncake.dng` (RAWs the user sent in earlier chats; user asked to reuse them).
CI now resizes the bench JPEGs (900 px) and prints them as a base64 tarball between `PREVIEWS_BEGIN/END` in the log,
because artifact blob storage is blocked from the dev container. Contact sheets are built from that outside the repo.
**Why**: user asked for visual results.
**Evidence / not verified**: see the next entry once CI has run.

## 2026-11-05 — First green CI + first measurements (run 41972847558)
**Fixes to get green**: `CIRAWFilter` has no `maximumExtendedDynamicRangeAmount` (use documented 0…2 range);
RawBench must not use `ImageMetrics`' internal memberwise init.

**Environment**: macos-15 runner, macOS 15.8.2 (24H232), Xcode 16.4. Decoder versions offered: up to `8` / `8.dng`
(RAW 9 from WWDC26 is not on this OS). 20/20 tests pass.

**Gate 1 — PASSED**: writing Apple's defaults back explicitly (pinned decoder) reproduces Apple's decode:
ΔE00 mean 5e-7 / 3e-7 / 4e-7 (BVQX5524 / HDR01 / IMG_1901). We fully control the decoder.

**Apple per-file defaults (decoder 8, macOS 15.8)**
| file | baselineExp | shadowBias | boost / boostShadow | LTM | sharpness | contrast | lumNR / colorNR | moire | temp / tint |
|---|---|---|---|---|---|---|---|---|---|
| BVQX5524 (iPhone 8) | −1.79 | 16 | 1 / 0.9 | 0 | 0.94 | 0.24 | 0 / 0.4 | 0.7 | 4927 / 7.1 |
| HDR01 (Pixel) | 0.01 | 5 | 1 / 0.9 | 0 | 0.5 | 0 | 0.1 / 0.5 | 0 | 3768 / 26.3 |
| IMG_1901 (13 Pro Max) | 0.50 | 16 | 1 / 0.9 | 0 | 0.89 | 0.26 | 0 / 0.5 | 0.7 | 4882 / 4.9 |

Defaults differ per model (sharpness, contrast, NR, shadowBias) → must be stored per model + decoder version.

**Variants vs appleDefault (1024 px)** — full table in CI job summary.
- `sceneLinear`: ΔE 11–14 (expected; Apple's tone intent removed). Analysis only.
- `auto`: no rule fired on BVQX5524/HDR01 (= Apple). IMG_1901 (60 % clipped) → −0.3 EV: clipped 60.4→57.9 %, black p1 0.058→0.042, halo ring 0.242→0.199, local contrast 0.310→0.339 (all in the right direction), ΔE 2.46.
- `warmNegative` @0.8: ΔE 2.4–4.0, clipping → 0 % (soft shoulder), but **black p1 raised** (0.007→0.016 on BVQX) — the intended film toe; keep as a look choice, review visually.
- `coolSlide` @0.8: ΔE 2.1–3.7, deeper blacks, local contrast +10–30 %.

**Performance (CI VM, not iPhone)**: full-res 12 MP develop + HEIC10 export 0.6–1.7 s; `auto` adds ~0.8–1.6 s (scene-linear thumb + Vision).

**Not verified / next**
- DecisionEngine DR rule never fires: scene-linear p1…p99 range on these files is only 3.5–5.5 stops, threshold 9 is wrong → recalibrate on more RAWs.
- Vision ran on CI (labels/faces present); IMG_1901 labels "people 0.52" but faces 0.
- No visual review yet (JPEG previews are in the CI artifact; artifact download is blocked from the dev container).
- Gate 2/3 need more RAWs and ColorChecker shots from several iPhone models.

## 2026-11-05 — Spike: CIRAWFilter engine + raw-bench + CI (branch `spike/ciraw`)
**What**
- `RawCore` (pure Swift): `ColorMath` (P3↔Lab D65, CIEDE2000), `LinearImage`, `ImageMetrics` /
  `ComparisonMetrics` (docs/METRICS.md), `RenderSettings` / `DecodeParameters` / `DecodeRecipe`,
  `CubeLUT` (.cube parser, trilinear CPU apply) + `BuiltInLook` (neutral, warmNegative, coolSlide),
  `SceneContext` + `DecisionEngine` (bounded, logged rules: DR→LTM, clipping→exposure, ISO→NR/sharpness, faces→detail).
- `RawCore` (Apple frameworks): `RawDecoder` (CIRAWFilter, modes appleDefault / explicit / sceneLinear,
  version pinning, CCM via linearSpaceFilter), `Renderer` (look via CIColorCubeWithColorSpace + dissolve,
  HEIC10/PNG16/JPEG export, float read-back), `VisionAnalyzer` (faces + classification).
- `raw-bench` CLI: `info`, `render`, `compare`, `bench` (variants appleDefault, explicit, sceneLinear,
  auto, auto+warmNegative, auto+coolSlide → summary.md/json, JPEG previews, recipes, `--full` HEIC10).
- Tests: Sharma 34-pair CIEDE2000, metric sanity (flat, clipping ring, halo, sharpness ordering),
  LUT parse/apply, settings validation, scene-linear overrides, DecisionEngine bounds, decoder tests on originals/ (Gate 1).
- CI: `.github/workflows/ci.yml` on macos-15.
- Docs: AGENTS.md, README.md, docs/PLANNING.md, docs/METRICS.md.

**Why** — previous custom pipelines were measurably worse than Apple's decode (haze, softness, halo). Decision: build on CIRAWFilter.

**Test data** — `originals/` (from the user): `BVQX5524.DNG` (iPhone 8, iOS 16.4.1, ISO 32, BaselineExposure −1.79),
`HDR01_payload_N000.dng` (Google Pixel "sailfish" HDR+ DNG, BGGR, ISO 439), `IMG_1901.DNG` (iPhone 13 Pro Max, iOS 18.5, ISO 50).

**Evidence** — written in a Linux container without a Swift toolchain; compiled and measured in CI (entry above).
