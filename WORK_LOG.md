# Work log

Newest first. Each entry: what changed, why, evidence, what is NOT verified yet.

## 2026-11-08 — Local highlight recovery (fix for the milky veil)
**Evidence from run 42333880670 (sweep, IMG_1901)**: clarity applied *after* the tone map pushed bright pixels past white
again (clipped 52.3 % at k 0.7 → 58.3 % with clarity 0.3), so it undid the recovery; every global variant kept a grey,
milky veil over the whole frame (bright Y 0.969 Apple → 0.91–0.94).
**What**
- Clarity now runs in the EDR domain *before* `CIToneMapHeadroom`, so compression keeps it below white.
- `highlightRecoveryLocal` (default on): the recovered render is blended over the plain SDR decode only where that
  decode is near white (linear Y 0.80 → 0.97, mask blurred 0.4 % of the long edge). Pixels Apple rendered correctly
  stay Apple's. Costs one extra decode when the rule fires.
- Defaults: headroomFraction 1.0, highlightClarity 0.4 (the partial headroom was only a workaround for the veil).
- Sweep: global k1.0 c0 (old) vs local k1.0 c0 / c0.4 / c0.7 / local k0.7 c0.4.

**Evidence (run 42365269279, 25/25 tests, Gate 2 PASS on all 11 decodable files)** — IMG_1901, 1024 px:

| variant | ΔE unclipped | clipped | mean Y | black p1 | bright LC | ring (ref mask) |
|---|---|---|---|---|---|---|
| Apple | 0 | 60.4 % | 0.733 | 0.0579 | 0.206 | 0.242 |
| global k1.0 (2026-11-07) | 2.67 | 39.5 % | 0.683 | 0.0505 | 0.209 | 0.212 |
| local k1.0 c0 | 0.30 | 42.9 % | 0.702 | 0.0576 | 0.208 | 0.241 |
| **local k1.0 c0.4 (new auto)** | 0.41 | 45.5 % | 0.702 | 0.0576 | 0.214 | 0.241 |
| local k1.0 c0.7 | 0.53 | 46.6 % | 0.700 | 0.0576 | 0.221 | 0.242 |

Visual: stage, people, trees and banner keep Apple's contrast (no veil); sky and pavement are recovered; clarity adds
texture to the pavement. ΔE on unclipped pixels drops 2.67 → 0.41. USER_mooncake: clipped 6.7 % → 2.2 %, ΔE unclipped
0.05 (was 1.71). USER_mug: ΔE unclipped 0.07.
**Known trade-off**: clarity overshoot pushes a few pixels past the source headroom, so clipping rises 42.9 % → 45.5 %
with c0.4. Recovered areas of a scene that is mostly near white still read pale: the RAW has only 1.99× headroom there.
Cost: one extra decode when the rule fires (~+0.5 s at 1024 px on the CI VM).

## 2026-11-08 — IMG_1901: whites look flat after highlight recovery
**Problem (user, visual)**: with the full EDR headroom (1.99×) tone-mapped back, IMG_1901's whites turn grey and flat.
Cause: `CIToneMapHeadroom` compresses everything from mid-highs up into SDR, so bright areas lose both level and
micro-contrast.
**What**
- `Threshold.headroomFraction` (0.7): map back only part of the headroom; the top may clip again instead of pulling all
  bright tones down.
- `highlightClarity` (0.3): `CIUnsharpMask` with radius 1.2 % of the long edge, blended through a luminance mask
  (linear Y 0.30 → 0.75), applied after the tone map. Restores local contrast where compression removed it.
- Metrics: bright region = reference Y ≥ 0.6. `brightMeanY` (flat grey whites read lower) and `brightLocalContrast`
  (std of the log2 high-pass inside that region), for candidate and reference.
- Bench sweep on files where auto tone-maps highlights: k ∈ {1.0, 0.7, 0.5} × clarity ∈ {0, 0.3, 0.5}, previews written.
  Tuning aid only: values are chosen on tuning files (IOS01, USR01, USR02), holdouts are not involved.
**Not verified**: until the next CI run.

## 2026-11-07 — Re-run with fixed halo metric (run 42331461310)
**Evidence (25/25 tests)**: Gate 1 PASS and **Gate 2 PASS on all 11 decodable files** (8 tuning, 3 holdout).
With the ring measured on the reference mask, highlight recovery makes the ring *darker*, not brighter:
IMG_1901 0.242 → 0.212, mooncake 0.595 → 0.540, mug 0.230 → 0.221. Black p1 not raised anywhere
(IMG_1901 0.058 → 0.051). Local contrast unchanged (±0.002).

| id | display clipped Apple → auto | ΔE unclipped | note |
|---|---|---|---|
| IOS01 | 60.4 % → 39.5 % | 2.67 | the remaining 39 % is sensor clipping (cannot be recovered); whites look flatter |
| USR01 | 6.7 % → 2.1 % | 1.71 | ceiling lights and wall gradient recovered |
| USR02 | 22.7 % → 20.4 % | 0.69 | only 1.31× headroom in the RAW |

**Why the 3 Canon DNGs fail**: all were written by **dnglab 0.3.0** from EOS RP CR3 (DNG 1.4, CFA, lossless JPEG,
16-bit). CIRAWFilter returns no image for them. Other DNG writers (Apple, Google HDR+, Panasonic via digiKam) decode.
Treated as a compatibility finding of the decoder, not worked around; provenance updated in corpus.json.

**Coverage vs the 36 target cases** (RAW_TEST_CORPUS.md): decodable public files cover 1 condition each for café
(night, warm light, ISO 3200), Tokyo night (skyline through glass, ISO 10 000), beach (haze, derived DNG), mountain
(layered haze); sky 2 (clouds; bright daytime sky); restaurant 0 real (2 tavern proxies). ≈ 7 / 36 conditions, and
none of the new ones are iPhone Bayer DNGs. Gap unchanged: app-captured iPhone DNGs per category.

**Observations, not acted on**: CAFE01 display clipping 2.98 % sits just under the 3 % trigger (lamps; recoverable,
headroom 3.2×). Night scenes keep Apple's dark rendering (mean Y 0.03–0.09); no rule changes them, which keeps the mood.
Faces on the IMG_1901 stage are still not detected at 1024 px (people label 0.52).

## 2026-11-07 — Results of run 42330787659 + halo metric fix
**Evidence (run 42330787659, 24/24 tests)**
- All 9 public RAWs downloaded on the GitHub runner (SHA-256 now pinned in corpus.json). 11/14 files decode:
  native NEF (Nikon D200, Z 50), ARW (Sony A7C II), RW2 (GH5S) and the Balcary DNG (G9 II) all open in CIRAWFilter.
  **The three Canon EOS RP DNGs (SKY02, SKY03, MTN02) fail**: "CIRAWFilter produced no image". CI now dumps their DNG
  tags to find out why (compression / linear DNG?). Not fixed.
- `CIToneMapHeadroom` exists on macOS 15.8 with inputs `inputSourceHeadroom`, `inputTargetHeadroom` (verified by `raw-bench info`).
- Gate 1 PASS on all 11 decodable files.
- Highlight recovery fired on 3 tuning files:
  IMG_1901 clipped 61.3 % → 39.4 % (rest is sensor clipping), ΔE unclipped 2.73;
  USER_mooncake 6.7 % → 2.1 %, ΔE unclipped 1.72; USER_mug 22.3 % → 19.9 % (headroom only 1.31×), ΔE unclipped 0.69.
  Visual check: mooncake ceiling lights and wall gradient come back with no visible halo; IMG_1901 sky/pavement detail
  returns but whites look flatter/greyer.
- Gate 2 reported FAIL on IMG_1901 and mooncake for "halo ring brighter". **This was a metric bug**: the candidate ring was
  measured around the candidate's own (smaller) clipped area, so it landed on the recovered highlight itself. Fixed:
  `candidateRingOnReferenceMask` measures the candidate on the reference's ring; Gate 2 uses it; regression test added.
  This is a measurement fix, not a threshold change; next run re-evaluates the same files.
- Rules on the new corpus: CAFE01 (ISO 3200) and TOKYO01 (ISO 10000) → NR +0.1 / sharpness −0.1; CAFE01 and NIGHT01 have
  DR > 9 stops but local tone map is unsupported for them too. NIGHT02 face 2.3 % → detail −0.1.

## 2026-11-07 — Public RAW corpus + highlight recovery + context fixes
**Basis**: user's `RAW_TEST_CORPUS.md` (2026-11-05): 3 seed files (= our originals), candidate Play Raw files per
category, 36 target cases, "split by scene", licence/provenance rules.

**What**
- `corpus/corpus.json`: 14 entries (5 originals + 9 public CC-BY-SA RAWs: café ARW, Tokyo NEF, Balcary DNG (derived),
  mountains RW2, Dolomites + 2 Rome DNGs, 2 tavern NEFs (restaurant *proxy*)), with category, condition, split
  (tuning/holdout by scene), provenance, author, licence. Direct links taken from the threads (first posts).
  CC-BY-NC Branscombe and FiveK excluded. `scripts/fetch_corpus.py` downloads them in CI (cached, never committed)
  and prints SHA-256 for later pinning. `originals/README.md` adds the CC-BY-SA attribution that was missing.
- Context features (`SceneContext`): `displayClippedFraction` (Apple render, 1024 px), `edrHeadroom` (p99.9 max-RGB of an
  EDR decode), `logP999`, `largestFaceArea`, `exposureTime`; DR is now p1→p99.9. Vision runs at 1024 px instead of 512.
- `DecisionEngine`: the "clipped → −0.3 EV" rule is removed. It used *sensor* clipping (which exposure cannot recover)
  and darkened the whole picture. New rule: display clipped > 3 %, recoverable (display − sensor) > 1.5 %, EDR headroom
  ≥ 1.15 → decode with EDR 1 and tone-map headroom → SDR with Core Image `CIToneMapHeadroom`. Unsupported local tone
  map and tiny faces are logged instead of silently doing nothing. Thresholds collected in `DecisionEngine.Threshold`.
- `Developer` (RawCore): one analyse → decode → tone map → look pipeline for CLI and app; analysis runs once per file.
- Metrics: `deltaE00MeanUnclipped` (ΔE only where Apple did not clip). Gate 2 uses it (AGENTS.md): highlight recovery is
  meant to change clipped pixels, not the rest.
- `raw-bench bench <dir>... --manifest`: gates table per file (Gate 1, Gate 2 with reasons), category/split columns,
  unsupported RAWs reported as rows. `raw-bench analyze` prints the context + decisions. `--full` dropped from CI (perf
  numbers from 2026-11-05 still stand; CI time is spent on the larger corpus).

**Why**: the context report (2026-11-07 artifact) showed LTM unsupported, DR threshold never reached, clipping measured
on the wrong image, faces missed at 512 px.

**Not verified yet**: everything above until the CI run below; whether `CIToneMapHeadroom` exists with
`inputSourceHeadroom/inputTargetHeadroom` on macOS 15.8 (logged by `raw-bench info`, fallback = not applied + logged);
whether all 9 downloads succeed from GitHub runners; decode support for the NEF/ARW/RW2 bodies.

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
