# Work log

Newest first. Each entry: what changed, why, evidence, what is NOT verified yet.

## 2026-11-08 — Demo iOS app to run the pipeline on a device (user: "how do I run it in Xcode")
**What**: `App/` — XcodeGen spec (`project.yml`) + SwiftUI app RawFilmDemo: camera preview, stock picker,
plugins toggle, "Shoot RAW" → CaptureService (Bayer RAW + HEIC, one press) → Developer (auto + stock) → per-shot folder in
Documents (capture.dng, apple.heic, capture.json, developed.heic, developed.recipe.json), visible in the Files app
(UIFileSharingEnabled). CI generates the project and builds it for iOS (no signing); the generated .xcodeproj is
committed so XcodeGen is optional for the user.
**Not verified**: until CI; never run on a device (needs the user's signing team and an iPhone).

## 2026-11-08 — Fixes from the second audit
Second audit (subagent) found the ROADMAP broadly honest (items 6/12 slightly overstated) and these problems; fixed:
- Calibration lookup used the marketing name and a substring fallback ("iPhone 13 Pro" could serve a Pro Max).
  Now exact match on model identifier (from DNG UniqueCameraModel), full UniqueCameraModel, then camera name.
- Analysis decodes used the OS default decoder while renders used the policy version: now the same pinned version;
  explicit modes throw if the file supports no policy version.
- highlightRecovery left a wrong recipe (EDR 1) when CIToneMapHeadroom is missing: the plugin now does not request
  EDR at all there (logged).
- Mono detection only knew the built-in name: now judged from the applied LUT (`CubeLUT.isMonochrome`).
- `recipe.plugins` listed enabled plugins: now only the ones that changed something; `recipe.pluginsEnabled` added.
  EDR analysis runs only when highlightRecovery is enabled. CLI rejects unknown plugin ids up front.
- CaptureService: exposure facts from the photo's EXIF (not live device values), per-photo errors kept, a failed
  RAW is an error, RAW format taken from the request, refuses to capture without a running session (avoids an
  ObjC exception), `.quality` so the HEIC reference is Apple's best.
- Bench: people check includes faces ≥ 1 %; crop recipes record the crop rectangle.
- New test `testSkinProtectionReducesLookOnPeople` (the protection path was only tested for its skip case).
**Evidence (run 42433089579, 44/44 tests, iOS build OK)**: Gate 1 + Gate 2 (auto) + Gate 2 (core) PASS on all 11
decodable files (8 tuning, 3 holdout); decoder chosen by policy everywhere. Skin protection test: ΔE on people vs base
3.01 → 1.86, rest 3.08 → 3.07. Bench (warm400, skin ΔE no-protection → protection): mooncake 3.34 → 2.50, NIGHT01
2.76 → 1.93, NIGHT02 (holdout) 3.46 → 2.78. mono400 is now fully neutral (visual + test). `recipe.plugins` lists only
plugins that changed something (e.g. [] for SKY01, ["highlightRecovery"] for IMG_1901). Numbers otherwise unchanged vs
run 42388988000, except CAFE01 where display clipping is now measured at 512 px (3.1 % > 3 %), so highlightRecovery
fires lightly (ΔE unclipped 0.07). CaptureKit still never ran on a device.

## 2026-11-08 — Roadmap = user's architecture; extras become plugins; gaps filled
**Why**: user set the architecture (docs/ROADMAP.md) as the roadmap, asked to fill what is missing, keep extras
highlighted for later, make extras pluggable, then re-audit and re-test. Audit (subagent, 2026-11-08) found:
no capture layer, no person mask / saliency / CIAreaHistogram / CCT, no skin protection, decoder version floating with
the OS, no per-model calibration path, recipes missing for some outputs, auto dropping caller overrides, stale
`largestFaceArea` on Vision failure, `?? 1` treating an unknown face as large, EDR exported if CIToneMapHeadroom absent.
**What**
- Plugins: `DevelopPlugin` + `PluginRegistry` (Plugins.swift). `highlightRecovery` (rule moved out of DecisionEngine
  into `HighlightRecoveryRule`) and `vignette` (moved out of FilmFinisher). `RenderSettings.plugins`, CLI `--plugins`,
  `recipe.plugins`. Bench runs `auto` and `auto core`; Gate 2 is reported for both.
- Analysis: Vision person segmentation + attention saliency; CIAreaHistogram (64 bins); CCT/tint; `analyzeInBackground`.
- DecisionEngine: colour NR at high ISO, lens correction when supported, skin protection when people ≥ 3 % or a face
  ≥ 1 %; explicit caller values (e.g. skinProtection 0) are respected; unknown face area no longer counts as large.
- Skin protection: `Renderer.protectSkin` (CIDissolveTransition + CIBlendWithMask with the scaled, softened mask).
- Decoder pinned by `DecoderPolicy` (fixed list) instead of the OS default; `recipe.decoderVersionSource`.
- Calibration: `ModelCalibration` / `CalibrationTable` (CCM + exposure offset folded into the linearSpaceFilter
  matrix), lookup by camera string, `recipe.calibration`; CLI `--calibration`. No measured entries yet.
- Export embeds the recipe JSON in EXIF UserComment; bench writes a sidecar recipe for every image (crops, full HEIC).
- highlightRecovery falls back to the SDR decode if CIToneMapHeadroom is unavailable (iOS 17).
- CaptureKit: AVFoundation wide camera, Bayer RAW + HEIC in one `AVCapturePhotoSettings`, metadata (model id, ISO,
  shutter, lens position, RAW FourCC, fallback). CI builds RawCore + CaptureKit for iOS.
- Highlight parameter sweep removed from the bench (tuning finished, saves CI time).
**Evidence (run 42431876319, 42/42 tests, iOS build of RawCore + CaptureKit OK)**: Gate 1, Gate 2 (auto) and
Gate 2 (core) PASS on all 11 decodable files. Decoder pinned by policy ("8" / "8.dng", same as before → numbers
unchanged). Vision person mask: mooncake 29 %, NIGHT02 27 %, NIGHT01 10 %, others ≈ 0. Skin protection (warm400):
ΔE on people vs auto base 3.34 → 2.50 (mooncake), 2.76 → 1.93 (NIGHT01), 3.46 → 2.78 (NIGHT02, holdout), rest unchanged.
Plugins unplugged ("auto core"): IMG_1901 back to Apple's 60.4 % clipping, ΔE unclipped 0.00 — the plugin is the
only thing changing it. TOKYO01 ΔE 0.04 → 0.27 from the new colour-NR rule (ISO 10 000).
**Bug found visually**: mono400 + skin protection kept colour on the person, the hand and the box they hold (the
person mask includes held objects). Fixed: `FilmStock.allowsSkinProtection` (false for mono400) and mono looks skip
protection with a logged reason; regression test `testMonoStockSkipsSkinProtection`.
**Not verified**: CaptureKit never ran on a device. The person mask also covers held objects; for colour stocks
that only means the box gets less look, but it is not "skin only".

## 2026-11-08 — Film engine: stocks with grain, halation, vignette (plan step 4)
**Direction**: user chose "Apple render as base, film on top" (docs/PLANNING.md, Decision 2026-11-08).
**What**
- `FilmFinish` (pure Swift, Codable, validated): grain amount/size/seed, halation amount/threshold/radius, vignette.
  All sizes are % of the short edge, so a preview, a 12 MP and a 48 MP render have the same grain at the same viewing size.
- `FilmFinisher` (Core Image built-ins only: CIRandomGenerator, CIGaussianBlur, CIColorMatrix, CIColorClamp,
  CIMultiply/AdditionCompositing, CIVignetteEffect). Grain is multiplicative, monochrome, seeded (reproducible from
  the recipe), weaker toward white. Halation: luminance above threshold → blur → red-orange tint → added.
- New looks `mono` (r = g = b) and `tungstenNight` (cools warm light, intentionally not neutral on daylight grey).
- `FilmStock`: `warm400`, `slide100`, `mono400`, `night800` (own names, no film brands) = look + intensity + finish.
  `RenderSettings.stock` / `.finish`; the recipe logs the finish actually used.
- Bench: stock variants replace the two bare looks; `--crops` writes centre 640 px crops at full resolution
  (Apple, warm400, night800) to judge grain at 100 %.
- Tests: grain determinism / seed / mean preservation / resolution independence / highlight fade, halation colour and
  locality, vignette, stock and finish validation.
**Run 42386875165**: 1 real failure: grain shifted mean Y 0.180 → 0.191 (+6 %); CIRandomGenerator values are not
symmetric around 0.5 in the linear working space. Fixed by using the difference of two independent noise fields
(zero mean by construction); amplitude raised (×1.5). Resolution independence already held: grain std 0.00267 at
600×400 vs 0.00267 for 1200×800 viewed at 600×400.
**Run 42387738885** (pipefail works: job red): mean 0.18 → 0.36. Real cause of both shifts: `CIAdditionCompositing`
sums alpha (1 + 1 = 2), and the following multiply compositing uses alpha. Fixed with `settingAlphaOne(in:)` after
every addition (grain and halation). Grain std is now 0.032 and still resolution independent (0.03178 vs 0.03177).
**Run 42388087057**: green; but 100 % crops showed grain as sparse BLACK DOTS (walls, night sky): rare noise cells
far outside the expected range drove the multiplier toward 0.
**Run 42388988000** (25+ tests green): multiplier clamped to 1 ± 0.375·amount; regression test
`testGrainHasNoOutlierDots` (multiplier 0.83…1.17 at amount 0.45, 0.625…1.375 at 1.0). Visual check of crops
(Tokyo, mooncake wall, tavern): dots gone, grain reads as fine even texture; night800 is strong on white walls by design.
Grain std 0.022 at 600×400 vs 0.022 for 1200×800 viewed at 600×400. Gates 1/2 still PASS on all 11 decodable files.
**Not verified / open**: the multiplier often sits at the clamp bound, i.e. the generator's distribution is wider than
assumed; a measured normalisation would give a softer distribution. Grain is monochrome only (no chroma grain).
On-device speed of the finish (3 blur passes at full res) is not measured.
**CI bug found**: `swift test | tee` hid the failing exit code, so that run showed green. Fixed with `set -o pipefail`.
Earlier runs were checked: all reported "0 failures" in their logs.

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

## 2026-11-08 — Demo app: generated Xcode project committed
- **What:** `App/RawFilmDemo.xcodeproj` and the filled `App/RawFilmDemo/Info.plist`, generated by XcodeGen 2.x from `App/project.yml` in CI run 42440396559 (extracted from the log), committed so the app opens in Xcode without installing XcodeGen. Regenerate with `cd App && xcodegen generate` after editing `project.yml`.
- **Evidence:** run 42440396559 green: `xcodebuild` for `generic/platform=iOS` (no signing) succeeded; 44/44 tests; gates unchanged.
- **Unverified:** never run on a device (no signing team in CI). Bundle id `com.example.rawfilm.demo` must be changed to a unique one when signing.

## 2026-11-08 — Demo app: frameworks instead of a local Swift package
- **Why:** on the user's Mac (Xcode 16) the app showed "Couldn't load project at <repo>" / "Missing package product 'RawCore' / 'CaptureKit'", even after removing/re-adding the local package and with no other window open. Cause not reproducible here.
- **What:** `App/project.yml` now builds `RawCore` and `CaptureKit` as iOS framework targets straight from `../Sources/...` (embedded in the app); no SwiftPM involved in the app project. Shared scheme `RawFilmDemo`. The SwiftPM package (CLI, tests) is unchanged.
- **Evidence:** CI run 42460834866 green: regenerated project builds for `generic/platform=iOS` (no signing); project committed from that run (no package references left in project.pbxproj).

## 2026-11-08 — CaptureKit: first run on a real iPhone, crash fixed
- **Evidence (user's device):** the demo app launched; pressing Shoot RAW crashed with `NSInvalidArgumentException: -[AVCapturePhotoSettings setPhotoQualityPrioritization:] Unsupported when capturing RAW`.
- **Fix:** `photoQualityPrioritization = .quality` is now set only on the HEIC-only fallback. With RAW + HEIC, the HEIC uses AVFoundation's default prioritisation. Note: the paired HEIC is therefore not guaranteed to be Apple's maximum-quality ("Deep Fusion") render, which matters when comparing against it.
- **Unverified:** the rest of the capture → develop path on device; awaiting the user's next run.

## 2026-11-08 — First device captures audited (output/, iPhone 14 Pro, iOS 26.5.2)
- **Data:** 2 shots pushed by the user (`output/2026-11-08T11-32-13Z`, `…11-33-23Z`): Bayer RAW `bgg4` 4032×3024 + same-press HEIC, ISO 200, no stock, plugins on (shot 1) / off (shot 2).
- **Works:** capture → develop end to end on device; recipe complete (decoder 8 by policy, no calibration entry for iPhone15,2 → DNG matrices); export is 10-bit HEIC P3 (Apple's is 8-bit); Vision person mask found the person (3.6 %, 24.2 %), faces 0 % because the subject faces away (correct).
- **Finding 1 (important):** our render is brighter than the camera HEIC: median +0.63 EV (shot 1) and +0.31 EV (shot 2) on mid-tones, +0.4 EV on highlights. Clipped pixels: 2.6 % (shot 1, highlightRecovery on) and 7.1 % (shot 2, plugins off) vs 0.35 % for the camera HEIC (ceiling light and upper wall blow out in shot 2). Cause: our reference for "≥ Apple" is the CIRAWFilter default decode, not the camera's own HEIC, which applies Smart HDR local tone mapping and a lower exposure. Next step proposed: use the same-press HEIC as a second reference (exposure/tone match), measured, before any change.
- **Finding 2:** shot 2 shows exactly what the highlightRecovery plugin is for; it was unplugged there.
- **Minor:** the recipe logs "skin protection 0.50" even when no look is applied (it has no effect then).

## 2026-11-08 — Drop 2026 presets `PRESET_26_*` (7 stocks)
- **What:** `Presets2026.swift`: 7 parametric presets from the brief (cpm35, portra-160, fuji-400h, kodachrome-64, grd-r, palm-springs, social-pop) as `FilmStock`s named `PRESET_26_*`. Spec params used as given; curve direction provisional (`curveLocked = false`). `FilmStock` now has a `source` (built-in look or preset) and `minSkinProtection` (spec `skinProtect`). App stock picker is a menu (11 stocks). Docs: docs/PRESETS_2026.md (mapping assumptions, open questions).
- **Evidence:** LUT properties checked with a Python port before CI (monotone grey, white ≤ 0.98, cast ≤ 2 %, no shadow blow-up). CI 42478109567: 48/49, the trademark test matched "portra" inside "PORTRAIT160" (substring); now checks whole words. CI 42478677794 green: 49/49 tests, Gates 1/2/2-core PASS on all 10 decodable files; all 7 presets rendered on every file (previews checked: directions visible at 60 %, grain visible on cpm35/grd-r, no clipping or colour blotches seen).
- **Unverified:** looks on real photos (bench renders all 7 on originals + corpus in CI); the 5-fixture tuning set.

## 2026-11-08 — cameraMatch plugin: match exposure + tones to the camera HEIC (same press)
- **Why:** first device pairs were +0.63 / +0.31 EV brighter than the camera's HEIC with 2.1 / 6.6 % clipped (HEIC 0.1 %). Our "≥ Apple" reference so far was Apple's CIRAWFilter default decode, not the camera pipeline users compare against.
- **Prototype first (Python, on the pairs' developed.heic vs apple.heic, 1008 px, aligned: best shift 0):** a global quantile tone curve alone gives mid EV 0.00 on both; shot 1 clipping 2.1 → 0 %, ΔE76 9.9 → 3.7; shot 2 clipping only 6.6 → 4.9 % (pixels already clipped in our SDR decode cannot come back). → Two stages: exposure offset **in the decode**, then the curve.
- **What:** `ToneMatch.swift` (pure: histogram quantiles, mid-tone exposure offset bounded −1…+0.5 EV, monotone gain-bounded curve, hue-preserving LUT). `CameraMatchPlugin` (plugin per AGENTS rule 9, default on, no-op without `RenderSettings.cameraReference`). `raw-bench pairs <dir>` compares renders with the camera HEIC; CI runs it on `output/`. Tests: ToneMatchTests (math, Python-checked) + `testCameraMatchOnDevicePairs` (median EV vs HEIC < 0.15 and closer than without; clipping not higher).
- **Not done yet:** the demo app does not pass `cameraReference` yet (next commit, after CI numbers). Smart HDR is local tone mapping; this is global only, so local differences (sky vs face) remain.

## 2026-11-08 — cameraMatch results + fix; app passes the HEIC
- **CI 42490482126 (53/53 tests, Gates unchanged PASS), `raw-bench pairs output`:**
  | pair | variant | mid EV vs HEIC | ΔE00 vs HEIC | clipped % (HEIC 0.20 / 0.18) |
  |---|---|---|---|---|
  | 11-32-13 | before (auto, no match) | +0.47 | 7.51 | 5.62 |
  | 11-32-13 | auto+cameraMatch | +0.00 | 3.36 | 0.32 |
  | 11-33-23 | before | +0.43 | 7.22 | 4.88 |
  | 11-33-23 | auto+cameraMatch | +0.00 | 5.11 | 0.20 |
  Exposure stage −0.42 / −0.47 EV; curve max shift 0.14 / 0.10.
- **Artifact found in the previews:** a bright oval on the upper wall with cameraMatch only. highlightRecovery had decided a 1.36× tone-map headroom at the old exposure; after −0.42 EV that headroom no longer exists. **Fix:** cameraMatch rescales the planned headroom by 2^offset and drops the highlight tone map (logged) when it falls under 1.15×. Test asserts no tone map in that case. To verify in the next CI previews.
- **App:** `settings.cameraReference = apple.heic` when the capture has a HEIC, so device renders use cameraMatch.
- **Not solved:** Smart HDR is local; we are global. ΔE 3.4–5.1 left (local contrast, colour), black p1 slightly off.

## 2026-11-08 — Roadmap 13: scene-dependent look intensity; ProRAW capture tier (option)
- **Look intensity (roadmap 13, remaining-work item 3):** `DecisionEngine.lookIntensityOffset` (pure): dark scene (scene-linear median < −5 stops) −0.10, ISO ≥ 1600 −0.05, people −0.05, landscape labels (≥ 0.5, no people) +0.05; clamped −0.15…+0.10; logged in the recipe. Applied to the stock's or explicit look's intensity; the stock never changes per photo (answer to "one roll, one preset?"). Thresholds from the bench contexts (CI 42490482126): median < −5 selects exactly NIGHT01 (−6.36), CAFE01 (−6.13), TOKYO01 (−5.32); MTN01 (−4.57) is not dark. Tests: `testLookIntensityFollowsSceneBounded`; DecisionEngine reason count 7 → 9 on the stress context.
- **ProRAW tier (user question about Smart HDR / Deep Fusion):** those run on every supported iPhone for the HEIC, but a Bayer RAW is one frame. Apple ProRAW (Pro models) is the multi-frame fused RAW. `RawPreference` + `RawTierPolicy` (pure, tested) + `CaptureService.setRawPreference`; `capture.json` records `rawKind`. Default stays Bayer (roadmap). Demo app toggle, disabled where unsupported. Listed in ROADMAP extras.
- **Unverified:** ProRAW decode through our pipeline (needs captures); look-intensity effect judged visually only.

## 2026-11-08 — Fixes from CI 42491918370 / 42492412535
- **White oval on the wall (cameraMatch):** not highlightRecovery. Dropping its tone map (previous commit) kept the oval and brought clipping back to 2.0 / 2.6 % (vs 0.32 / 0.20 %), so that change is reverted. Real cause: `ToneMatch.curve` forced (1,1) after a compressed last point (0.91 → 0.79), stretching the top tones 2.3×; with our top quantiles bunched in the clipped area, segments reached slope 5–35 (Python check on the pairs). **Fix:** extra top quantiles (98.5 / 99.5 / 99.9 %), slope ≤ 2 per segment, end segment slope ≤ 1. Tests: slope bound in ToneMatchTests; device-pair test now also requires clipping < 1 %.
- **mono400 not neutral on mooncake (testMonoStockSkipsSkinProtection, 0.048 > 0.02):** the new look-intensity offset (people −0.05) ran mono at 95 % = washed-out colour. **Fix:** no intensity offset on black-and-white LUTs (logged).
- **Evidence (CI 42493493277, green: 55/55 tests, Gates 1/2/2-core PASS on all decodable files):** pairs vs the camera HEIC — 11-32-13: mid EV +0.47 → +0.00, ΔE00 7.51 → 3.30, clipped 5.62 → 0.02 % (HEIC 0.20); 11-33-23: +0.43 → +0.00, ΔE00 7.22 → 5.15, clipped 4.88 → 0.01 % (HEIC 0.18). White oval gone in the previews. Our highlights now clip less than the HEIC's; the ceiling lamp is a little greyer than Apple's.

## 2026-11-08 — Xcode build broke on the user's Mac: stale xcodeproj
- **Symptom (user's Xcode):** `Cannot find type 'PresetLookParams'`, `Cannot find 'Preset26'`, `FilmStock.Source does not conform to Equatable` in Look.swift.
- **Cause:** the committed `App/RawFilmDemo.xcodeproj` lists source files one by one and predates `Presets2026.swift` and `ToneMatch.swift`. CI regenerates the project before building, so it never saw the stale copy.
- **Fix:** project regenerated (taken from the XCODEPROJ block of CI 42493493277, which contains both files). CI now fails when the committed project differs from a fresh `xcodegen generate`. AGENTS rule 8 added (rules renumbered: plugins rule is now 10).
