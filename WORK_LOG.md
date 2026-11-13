# Work log

Newest first. Each entry: what changed, why, evidence, what is NOT verified yet.

## 2026-11-13 — RawCore 0.3.0 (branch `feature/rsp-0.3.0`, from tag 0.2.0; not tagged)
Contract: MoodRoll `.orchestration/film-lab/RSP_030_SIGNOFF.md` (C1-C11, §5 tests, §6 step 2 a-h) and
`LOOK_V2_PROTOTYPE_2026-11-13.md` §5. One commit per sub-step; `swift test` green after each.
- **(a) C8 guard fixture** on the unchanged 0.2.0 code: `Fixtures/looks-0.2.0-guard.json`, LUT fingerprints (size + FNV-1a
  of the float bits, title ignored) of the 18 shipped looks; `LookGuardTests` keeps them equal on every later commit (D6).
  Evidence: written with `RSP_WRITE_LOOK_GUARD=1`, then `swift test --filter LookGuardTests` 1/1; full `swift test` 120/120.
- **(b) C9 LRU caches:** `LUTLRU` (Look.swift); `LookSpecCache` and `SkyHoldLUTCache` capacity 4, `LogLookPlugin.Cache` 4;
  same lock, same keys. A 65³ cube is ~4.4 MB, so the worst case is ~18 MB per cache instead of ~190 MB. A develop uses
  two SkyHold entries per held look; sample generation over many stocks rebuilds LUTs (tens of ms each, accepted).
  `CacheLRUTests`: 5th insert evicts the LRU entry, a hit refreshes, an evicted look rebuilds byte-identically.
  Cost seen in tests: the pairwise stock loops in `RollStocksTests` rebuilt a 65³ cube per pair (debug build, ~2.3 s each;
  the suite went from 11 min to ~2 h), so `chartDistance` keeps a test-local LUT copy. A real develop of one stock is
  unchanged (cold build once, then cache hits).
- **(d) C7 baseline, committed before (c):** `LookArgumentsTests.fields` writes `source=<case>(<look name>)` instead of
  `String(describing: source)`; LUT values stay guarded by `lut`, pixels by `pixels`. Done before vibrance because adding
  `LookSpec.vibrance` changes the `String(describing:)` text of every spec stock, which would leave (c) red.
  Procedure: new code against the 0.1.0 file gave exactly 38 failures, all `fields` (19 stocks x id / look + arguments),
  0 `lut`, 0 `pixels` (same macOS 15.2 24C101 arm64 and USER_mooncake.dng as the file, so pixels were compared). Then
  `RSP_WRITE_BASELINE=1` into `Fixtures/rollstocks-0.3.0-baseline.json` (`engine` "0.3.0"): all 19 `lut` and `pixels`
  equal to 0.1.0, and each `fields` line differs only in its `source=` part. The 0.1.0 file is deleted.
- **(c) C5 `LookSpec.vibrance` / `vibranceSkin`** (default 0 / 0.5): chroma x (1 + v (1 - min(C/0.25, 1))^2), skin hues
  (OKLCh 52 +- 22 deg) at `vibranceSkin` of the gain (raised cosine). Placed as the film-lab prototype diff does (C5): after the
  hue bands' hue shift, on the input chroma, before band chroma scale, band lightness, density and tonal saturation (the
  prototype's §2/§5.B text, "before the hue bands", is wrong; the skin numbers were measured with this placement).
  v = 0 skips the branch. `VibranceTests` B(1)-(5): v 0 identical LUT for every look whatever vibranceSkin is, grey drift
  unchanged, low chroma gains more than high, hue <= 0.5 deg up to v 0.5, in gamut and monotone greys; guard still green.
- **(e) Plugin `headroom` (C1-C3, C6; ROADMAP EXTRAS row):** `RenderSettings.decodeHeadroomEV` (0...1.5, nil/0 = off,
  in `hasOverrides` so `appleDefault` rejects it) and the output-only `headroomRestoreEV`. Registry order
  `highlightRecovery -> headroom -> cameraMatch`, enabled by default. decide: exposure = min(bias, 0) - D, restore = D +
  max(bias, 0) (bias = `exposure` when headroom decides; DecisionEngine and highlightRecovery never write it, tested).
  afterDecode reads only `headroomRestoreEV`; `developBase` clears it on entry, so `auto: false` and a caller-set value are
  no-ops. Set but unplugged: recipe line "decodeHeadroomEV set but plugin headroom is off: ignored", no pixel change.
  `HeadroomRestore.lut(gainEV:size:)` (33³, gain quantised to 0.01 EV, 2-entry LRU) is an exact port of the film-lab
  `LabFlags2.restoreFunc` / `restoreLUT`. `HeadroomTests` 11/11.
  Note for the tech-lead: because f is normalised to f(1) = 1, the gain below the knee is G / raw(1), not G: x2.05 instead
  of x2 at D 1.0, x1.50 instead of x1.37 for a +0.45 bias alone. The prototype measured with this curve, so it is kept.
  Unverified: device output (C11), highlightRecovery stacking (C10), the S1-S4 acceptance renders (film-lab, C10).
- **(f) `LookArguments.Grain.isoV2(scale:)`** (JSON `{"isoV2":{"scale":1}}`) and `RollStock.grainV2(iso:)`, the L12 tiers
  <130 0.22/0.065, <180 0.26/0.075, <300 0.33/0.090, <600 0.46/0.120, >=600 0.62/0.150 (by box ISO; 800T uses the 800 tier).
  Same checks as `.iso` (needs iso, scale 0...2). The old `.iso` table is unchanged. `GrainV2Tests` 4/4.
- **(g) C4 three v2 looks** `goldenDay2`, `coolFade2`, `softPortrait2` (values of `look_v2_specs_final.json` = prototype
  §5.A; vibrance 0.10 / 0 / 0.10, L21), appended to `FilmLooks2026.looks`; intensity and finish copy goldenDay /
  trialCoolFade / softPortrait. `tungstenGlow2` is not added (L19). 18 -> 21 names and `SupportedLooks`.
  `FilmLooksTests` all green on the 21 (skin, white/black/gamut, steep slope, off-grid interpolation: max ΔE00 1.24 / 1.03 /
  0.47). Nearest neighbours (chart ΔE00): goldenDay2 3.06 (goldenDay), coolFade2 2.02 (trialCoolFade), softPortrait2 2.64
  (softPortrait). C8 part 2: `Fixtures/looks-v2-0.3.0.json` + `LookV2Tests`: the 3 LUT fingerprints and pixel hashes of
  Marigold / Breeze / Blush as look + the MoodRoll catalog arguments (L16 values), on USER_mooncake, macOS 15.2 arm64.
- **(h) `RawCore.engineVersion` "0.3.0"** (`testSupportedLooksAndEngineVersion`). Not tagged, not pushed: tag and push wait
  for the C10 renders (film-lab), the tech-lead diff review and the User's OK. Not verified: device (C11), the C10 acceptance
  renders, CI (macos-15).
- **(i) Breeze retune + R2** (User, 2026-11-13; film-lab C10 §4): `coolFade2` shadowDesat 0 -> 0.1 (the lab prototype
  inherited it from trialCoolFade), contrast 1.0 -> 1.06, shadowTint (-0.014, -0.008) -> (-0.017, -0.008); nothing else.
  `looks-v2-0.3.0.json`: only the coolFade2 LUT and Breeze pixel hash change; Marigold, Blush and the 18-look guard are
  unchanged. `testLooksDistinctFromNeighbours` now asserts nearest >= 2.0 for the 3 v2 looks (tech-lead R2); shadowDesat
  alone gave 1.97, so it needed the retune.

## 2026-11-11 — RR roll-stock grain re-tuned for the filmDevelop decode
- **What** (`RollStocks.swift`, grain only; note `.orchestration/looks/RR_GRAIN_2026-11-11.md`):
  - `RollStock.grain`: ISO 400 amount 0.38 -> 0.35, ISO 200 0.28 -> 0.27. 100 / 160 / 800 / 800T and all sizes are unchanged.
  - New `RollStock.grainScale(look:)`: a per-look amount multiplier. cleanLab x0.80, so rr-chuan-400 goes 0.38 -> 0.28; every other look x1.
  - `testGrainGrowsWithISO` extended. Every shipped stock is grainier (amount and size) than every stock of a lower box ISO,
    chuan-400 is finer than chan-dung-400, and the multiplier stays in 0.7...1.0.
- **Why:**
  - rr-chuan-400 ("clean lab, medium grain") read noisy on clean daylight frames (flat texture 1.80x / 1.44x Apple).
  - Finding: at a given stock the grain's flat std is nearly the same on every file (ISO 800: 0.063-0.080 log2). The
    ratio vs Apple swings because Apple's own flat texture varies about 3x between files (0.042 on an ISO 32 sky,
    0.129 on an ISO 200 indoor frame).
  - So no constant grain keeps every frame in 0.9-1.3x. The table aims a typical frame at about 0.95x (100/160),
    1.1x (400) and 1.3x (800).
  - ISO 160 was not raised for mug (0.75x): 0.9x there would put the ISO 32 sky at about 2x.
- **Evidence:** `raw-bench bench originals --native --native-stock <id>`, flat ratio after grain, BVQX / HDR01 / IMG_1901 / mooncake / mug:
  - rr-chuan-400: 1.80 / 1.44 / 1.05 / 1.19 / 0.94 -> 1.43 / 1.25 / 0.96 / 1.01 / 0.86.
  - rr-chan-dung-400: 1.79 / 1.44 / 1.04 / 1.18 / 0.95 -> 1.68 / 1.38 / 1.02 / 1.13 / 0.93.
  - rr-da-mem-160 and rr-dem-mem-800 are identical before and after (1.30 / 1.16 / 0.87 / 0.95 / 0.75 and
    2.07 / 1.59 / 1.11 / 1.32 / 1.01).
  - Before-grain ratios are identical across builds.
  - chuan-400 overshoot after grain: BVQX +24 -> +9 %, HDR01 +86 -> +26 %.
  - Eye check on native crops (sky, cheek, white wall, faces, foliage, desk): the new chuan-400 reads as an even, fine lab
    grain; the old one was mottled.
  - `swift test --filter RollStocksTests`: 10 tests, 0 failures.
- **Unverified:**
  - Device; ISO ≥ 1600 and real low-light frames; ProRAW; holdout files (not run, not tuned on). The 100 / 200 stocks
    were not benched.
  - Bright sparkle dots on near-white walls at 400/800 come from the finisher's highlight fade (w floor 0.2), not from
    the amount. This is left to the finisher owner.

## 2026-11-11 — Plugin `lightLeak` (RR Lá Phong 100) and cameraMatch curve strength with a stock
**What**: (1) `LightLeakSpec` / `LightLeakPlan` / `LightLeakPlanner` (Look.swift, pure Swift) per "Light leak spec" in
`.orchestration/looks/RR_LOOKS_2026-11-11.md`; `FilmFinish.lightLeak`; `FilmFinisher.lightLeak` (256 px bitmap of the pure maths, B-spline
upscale, screen in linear light, ceiling 0.99 encoded, person-mask x0.4 if a mask is given); plugin `lightLeak` (afterFinish, in
`PluginRegistry.standard`, default on); `RenderSettings.rollID / rollFrameIndex / rollFrameCount` (1-based, validated, not decode
overrides); one line in `RollStock.stock` enables it for `rr-la-phong-100` only. CLI: `raw-bench render ... --roll-id ID --frame N --frames COUNT`
and `--camera-reference HEIC`. The recipe logs seed, class, chance draw, edge, position, strength, sigma, hue, streak. Same roll id + frame
index = same plan (FNV-1a 64 -> SplitMix64, no Swift hashing). No roll position = no leak, logged. ROADMAP EXTRAS row.
(2) cameraMatch with a stock that has `develop`: `ToneMatch.blended` takes the HEIC curve toward identity at
`FilmDevelop.cameraMatchCurveStrength` (0.5); exposure match unchanged; no stock = unchanged; logged ("max shift a -> b").
**Spec items built**: soft Gaussian ellipse from the left/right edge, core 0-10 % outside, reach 21-39 % of the width (30 % +-30 %), optional
streak 5-12 % wide, red-orange [1,.30,.06] to hue 70, hue +-8, size +-30 %, never the central third along the edge, screen blend, peak add
0.25 x amount 0.35 x strength, ceiling 0.99 encoded, frames 1-2 always 0.6-0.9, frame 3 50 % 0.3-0.5, middle 12 % 0.15-0.35 (never strong, so never two
strong in a row), last 60 %, seed = roll id + frame index, removable with `plugins = []`.
**OPEN (the spec does not say; the value used is in `LightLeakSpec`, all one-line changes)**:
1. Core colour vs hue: [1.0, 0.30, 0.06] gives OKLCh hue 52 degrees (54 as linear sRGB), the text says 35-45. Used the numbers as written, linear in the working space (P3).
2. "Medium" strength of the last frame: no number. Used 0.35-0.60 (the gap between faint 0.35 and strong 0.6).
3. Ellipse aspect: no ratio. Used sigma along the edge = 1.5 x sigma into the frame.
4. What "falls off to 20-40 % of the width" means: used reach = 2.45 sigma (5 % of peak), measured from the core, 30 % +-30 % size jitter.
5. Streak: chance (0.5), strength (0.25 of the peak), full-height raised-cosine band from the edge: all invented, "optional" only.
6. "Left or right in landscape": used left/right in every orientation (portrait too). Which edge of a portrait frame is the door side is not stated.
7. "Along the long axis": read as the ellipse's long axis lying along the edge.
8. Class precedence on short rolls: start (1-2), third (3), last, middle. A 3-frame roll's frame 3 uses the third row.
9. Middle "about 12 %": an independent seeded draw per frame, so a roll has 12 % on average, not exactly; over 400 simulated 36-frame rolls 1557/12800 = 12.2 %.
10. Without a `rollID` the seed uses "" (two rolls without ids share a pattern). No roll position = no leak (spec silent).
11. The "user can turn it off": only via `plugins` (no separate amount setting).
12. Visibility: at the spec's numbers the peak add is 0.25 x 0.35 x 0.86 = 0.076 linear; on IMG_1901 and mooncake frame 1 the leak is very faint. Whether 0.35 is meant to look that subtle is for the user to judge.
13. The person mask: `PluginRenderContext.personMask` exists but Developer.swift does not fill it (not mine): to get the x0.4 on people, Developer.finish must set `base.pluginContext.personMask = base.personMask` before the afterFinish loop. Until then the recipe says "person mask not available: no attenuation".
**Evidence**: `swift test --filter LightLeakTests` 10/10 (determinism, 400 rolls x 36 frame pattern: frames 1-2 always, frame 3 199/400, last 218/400,
placement, hue range, peak add, screen lifts shadows more, no clip, person factor 0.40, plugin round trip, only la-phong has a leak, curve blend).
Two plugin-list asserts (FilmFinisherTests, DecoderTests) now check the first five ids + `lightLeak` (skyMask is another agent's). `raw-bench bench originals --full`:
Gate 1 / Gate 2 auto / Gate 2 core PASS on all 5 (no roll position there, so no leak). Renders (scale 0.5, roll "demo-roll", 36 frames; frames 1 and 2 leak, 18 and 36
draw no leak): scratchpad `leak/`. `raw-bench pairs docs`: unchanged without a stock (ΔE00 vs HEIC 2.10 and 3.78 with cameraMatch). With stock rr-chuan-400 the
curve max shift goes 0.192 -> 0.096 and 0.147 -> 0.074 on the two pairs (recipe line); ΔE00 vs HEIC with a stock was not measured (pairs has no stock variant).
**Not verified**: a real roll, a device, the Vision person mask path, the look of the leak on a human review, ΔE00 vs HEIC of the 0.5 blend, CI, xcodeproj (no Swift file added in Sources/RawCore).

## 2026-11-11 — Plugin `skyMask`: sky hold only inside a sky mask (user: "Mask trời + bật skyHold theo nhãn cảnh của Vision")
**What**: Pure `SkyMask` (ContextAnalysis.swift, algorithm v1): on the 512 px scene-linear render, candidates = bright blue or bright
neutral (cloud) pixels with low 7x7 luma texture; connected regions kept only if they touch the top rows and cover >= 1 % of the frame;
guided filter (luma guide, r = 1.6 % of the long edge) -> soft mask. Gate: `SkyMask.gate(labels:)` (Vision sky / landscape labels >= 0.30,
"outdoor" alone does not count): closed = mask empty, unavailable (no classification) = no decision. Analysis schema 3 -> 4: `sky-mask.png`
next to `person-mask.png`, `SceneContext.skyMaskVersion / skyFraction / skyGate`; a stored analysis with another mask version, without a
decision while the plugin is on, or with a missing mask image is re-made. `Developer.finish`: for a stock with `skyHold` > 0 (new
`FilmStock.skyHoldAmount`, `lutWithoutSkyHold`, cached; FilmLooks.swift) the look is rendered with and without the hold and blended by the mask
(`Renderer.blend`, CIBlendWithMask). Gate closed / coverage < 1 % = look without hold; plugin off, not analysed or no classification =
colour-only as before, recipe: "sky mask unavailable (...): colour-only sky hold". Plugin `skyMask` registered (one-line edit in Plugins.swift),
ROADMAP EXTRAS row. Tests: DevelopStagesTests +4 (top-connected blue = sky, blue object below = not, textured blue-cast wall low, label gate,
blend + stock variants). No new Swift file, xcodeproj unchanged.
**Evidence** (`raw-bench looks`, 1024 px, before = `--plugins` without skyMask = old colour-only; sky pixels as in Looks.swift, top 40 % blue-hue):
frame fraction held (colour-only -> with mask): iPhone12Pro mountain/lake 65.7 % -> 10.9 %, IMG_1901 (stage lights, label music/people) 26.4 % -> 0,
mug 2.8 % -> 0, mooncake 0.09 % -> 0, HDR01 0.02 % -> 0; BVQX5524 (sky 0.95) 69.4 % -> 69.1 %, 20250322 (land 0.92) 7.2 % -> 6.2 %, P1073242 7.0 % -> 6.6 %.
Sky chroma / base in a hand-placed box of pure sky rows (before -> after): BVQX5524 PORTRAIT160 0.995 -> 0.992, SOFT400 0.997 -> 0.993, softPortrait 0.969 -> 0.959;
20250322 (rows < 200) 0.790 -> 0.787 / 0.671 -> 0.664 / 0.442 -> 0.437; P1073242 (rows < 60) 0.963 -> 0.958 / 0.962 -> 0.953 / 0.881 -> 0.870;
iPhone12Pro (rows < 60) 0.956 -> 0.921 / 0.947 -> 0.916 / 0.926 -> 0.880 (white cloud edges are textured, so they are not held; blue lake and rock slopes lost their hold on purpose).
`raw-bench looks` skyL/skyChroma on iPhone12Pro drops for the same reason (its top 40 % contains bluish mountain rock, not sky). Gate 1 / 2 auto / 2 core PASS on all 5 originals;
`swift test --filter DevelopStagesTests` 13 / 13.
**Not verified**: overcast white sky and blue-cast smooth walls touching the top are indistinguishable from sky by pixels (only the label gate helps);
label names ("blue_sky", "cloudy", ...) assumed from the Vision taxonomy and seen on 5 files only; no labelled sky corpus (IoU); analysis cost on device with the
camera running (mask ~ pure Swift on 512 px, measured inside the 0.6-1.1 s analysis, not separately); no visual review by the user.

## 2026-11-11 — Plugin `filmDevelop`: soft film decode per roll stock (plan SMARTPHONE_LOOK_PLAN_2026-11-11)
**What**: `FilmDevelop` (Look.swift, pure, Codable) + `FilmStock.develop`; `RollStock.develop` from stock ISO class and character
(ISO<400 sharp x0.55, 400-1599 x0.45 + luma NR no higher than Apple's, >=1600 x0.35 + luma NR <= +0.05; vivid x0.70, portrait x0.45;
floor 0.30; face >= 1 % extra -0.10; highlight clarity x0.4; ProRAW detail 0.5 -> 0.2; LTM untouched, `ltmScale` nil). Plugin `filmDevelop`
(Plugins.swift, last in the registry so it runs after highlightRecovery; `auto` only; no stock / no develop = no-op; listed in
`recipe.plugins` only when it changed something). `Developer.Base.developedFor`; `finish()` logs "base developed for X, finished as Y".
DecisionEngine face rule fixed: Bayer detail default 0 made `-0.10 detail` a no-op, it now lowers sharpness (detail kept on ProRAW).
ROADMAP EXTRAS row. Tests: RollStocksTests (+4), DevelopStagesTests (+1); two plugin-list asserts and the DecisionEngine bound test updated.
**Why**: Bayer decode looks like a phone mostly from sharpness 0.89-0.96 and our own clarity (plan §1).
**Evidence** (scratch dir, not committed): `raw-bench bench originals --full` Gate 1 / Gate 2 auto / Gate 2 core PASS on all 5; mooncake's
face rule now fires (sharpness 0.96 -> 0.86). Plain `auto` has no stock, so it is unchanged otherwise. Native metrics (bench-qa
`--native`, 5 crops, with filmDevelop, before grain; overshoot vs Apple / HF ratio / flat ratio):
rr-chuan-400: BVQX -22 % / 0.69 / 0.77; HDR01 -11 / 0.94 / 0.96; IMG_1901 -39 / 0.76 / 0.84; mooncake -40 / 0.57 / 0.71; mug -25 / 0.68 / 0.73.
rr-da-mem-160: -23 / 0.72 / 0.72; -11 / 0.98 / 0.89; -41 / 0.75 / 0.76; -40 / 0.58 / 0.67; -26 / 0.64 / 0.64.
**Not verified / open**: plan targets only partly met: overshoot -30 % reached on 2 of 5 files (Pixel file -11 %, because its default is 0.5
and the 0.30 floor bites); HF ratio 0.57-0.58 on mooncake (< 0.6, near mush); flat texture before grain 0.64-0.84 (< 0.9 target) on 4 of 5.
Floor/scales need tuning on a human look. `raw-bench --native-stock` only finds `FilmStock.all` (not RR stocks): Native.swift should use
`FilmStock.named` (verified in a scratch copy). Stock-ISO is used for the ISO class (not capture ISO). Not run: device, ProRAW file,
CI holdout, full `swift test` after the last two test edits (filtered runs only), xcodeproj unchanged (no files added).

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

## 2026-11-09 — Two-phone captures audited; Gate 3 tooling (ColorChecker → CCM → gate3)
- **Captures (docs/2026-11-08T15-48-31Z, …15-51-23Z), indoor night, ISO 125, 1/50:**
  - iPhone 15 Pro (`iPhone16,1`, iOS 26.6), **ProRAW** (`l64r`, first ProRAW through the pipeline): decoded fine; cameraMatch −0.83 EV + curve; vs its HEIC mid EV −0.01, clipped 0.00 % (HEIC 0.23 %); black p1 0.0027 vs 0.0013 (we lift blacks slightly). highlightRecovery did not fire (no display clipping in the ProRAW decode). Look-intensity rule fired (dark −0.10, people −0.05).
  - iPhone 14 Pro (`iPhone15,2`, iOS 26.5.2), Bayer: highlightRecovery (14.9 % display clipped, headroom 1.75×) + cameraMatch −0.62 EV; vs HEIC mid EV +0.00, clipped 0.00 % (HEIC 0.09 %), p1 0.0038 vs 0.0041.
  - Different framing, so no cross-model colour number from these (needs a chart).
- **Gate 3 tooling:** `ColorChecker.swift` (pure: X-Rite post-2014 Lab D50 references → Bradford → linear P3; patch grid from 4 corner-patch centres; median sampling; white-preserving 3×3 CCM by least squares, clipped patches excluded; cross-model ΔE00 with exposure normalised). `raw-bench chart <dng> --corners …` fits, **re-decodes with the CCM** and reports verified ΔE, writes `--calibration-out models.json` + `--out chart.json`; `raw-bench gate3 a.json b.json` (exit 1 on fail). Tests: ColorCheckerTests (math Python-checked: recovers a known matrix to 1e-3), `testLinearImageRowZeroIsTop`.
- **CI:** stale-xcodeproj check moved to the last step (tests + bench still run); `pairs` also scans `docs/`. New file ColorChecker.swift → project regenerated from this run's XCODEPROJ in the next commit.
- **Unverified:** the reference values (from memory of X-Rite's sheet; `--reference` override not implemented yet — check the chart's own sheet); that linearSpaceFilter acts in the space we measure (the re-decode verification answers this on the first real chart).
- CI 42551163467: build failed — `ChartMeasurement` had no public init (memberwise init is internal across modules). Added.
- CI 42551371028: build OK, **61 tests, 0 failures** (ColorChecker 5/5, row-0-is-top passed → sampler orientation confirmed), Gates unchanged; only the stale-xcodeproj check failed (expected: new ColorChecker.swift). Project regenerated from that run's XCODEPROJ. Device-pair test now also scans `docs/` (it was skipped: `output/` was deleted).
- **Pairs on the two phones (raw-bench pairs, vs each camera HEIC):** 15 Pro ProRAW: mid EV +0.86 → −0.00, ΔE00 11.34 → **2.09**, clipped 0.10 → 0.00 % (HEIC 0.24), black p1 0.0119 → 0.0029 (HEIC 0.0013). 14 Pro Bayer: +0.57 → +0.00, ΔE00 8.96 → **3.78**, clipped 1.60 → 0.00 % (HEIC 0.09), p1 0.0049 → 0.0039 (HEIC 0.0042).

## 2026-11-09 — ProRAW lifted blacks fixed (cameraMatch shadow boost); `raw-bench chart --reference`
- **Worked locally** (user's Mac, Swift 6.0.3 / Xcode 16.2) after the cloud session: `swift build`, `swift test`, `raw-bench pairs docs` run here, not only in CI.
- **ProRAW black p1 0.0029 vs HEIC 0.0013 (15 Pro):** cause measured, not guessed. After the −0.86 EV exposure match our 0.5–1 % shadow quantiles still needed ≈ −1.5 EV, which is the curve's gain bound (`maxStops` 1.5), so the curve could not take them down. Experiments on the pair (env overrides, removed): 65-point LUT instead of 33 → no change (LUT resolution is not it); extra low curve quantiles (0.5/1/2 %) → p1 0.0023; `boostShadowAmount` 0 → p1 0.0015 with ΔE00 unchanged (2.09), but on the 14 Pro Bayer the same change hurts (ΔE00 3.78 → 4.47, p1 0.0040 → 0.0015 vs HEIC 0.0042); `localToneMapAmount` 0.5 → ΔE00 2.78, 0 → 5.23 (worse).
- **Fix:** cameraMatch measures the shadow gap (quantiles 1–5 %, after the exposure offset) vs the HEIC (`ToneMatch.shadowGapEV`) and scales Apple's boostShadow down (`ToneMatch.shadowBoost`: kept ≤ +0.5 EV, 0 at ≥ +1.5 EV, linear between; never raised); logged. The curve also samples 0.5 / 1 / 2 % (like the dense top). Plugins get a `decide(context:defaults:settings:)` variant (default forwards to the old one) so a plugin can scale a per-file default.
- **Evidence (`raw-bench pairs docs`, local):** 15 Pro ProRAW: gap +1.63 EV → boostShadow 0.90 → 0.00; black p1 0.0029 → **0.0015** (HEIC 0.0013), ΔE00 2.09 → 2.09, mid EV −0.00, clipped 0.00 %. 14 Pro Bayer: gap −0.34 EV → kept; p1 0.0039 → 0.0040 (HEIC 0.0042), ΔE00 3.78 → 3.79.
- **`raw-bench chart --reference sheet.txt`:** the chart's own data sheet (24 Lab D50 lines in chart order; last three numbers per line, headers/`#` ignored, `;` + decimal commas accepted). Used for the fit, the re-decoded ΔE, and stored in chart.json (`referenceLab`, `referenceSource`); gate3 uses it and notes when two charts used different tables. Tests: `testParseReferenceSheetFormats`, `testFitFollowsACustomReference`, `testShadowGapLowersBoostOnlyWhenOursAreBrighter`.
- **Tests (local):** 64 tests, 0 failures. No Swift file added → xcodeproj unchanged.
- **Unverified:** `raw-bench bench originals` (Gates 1/2) not run locally — the change only acts with a camera reference, which the bench originals have none of; CI to confirm. Shadow rule fitted on one ProRAW pair (night indoor); noise in lowered shadows not judged.

## 2026-11-09 — Audit of roadmap / planning / decisions; holdout-tuned threshold fixed; stale docs
- **Audit result:** core matches the roadmap (CIRAWFilter, pinned decoder, explicit parameters, CCM in linearSpaceFilter, looks via CIColorCubeWithColorSpace, half-float P3, HEIC10 + recipe); hard rules 1, 2, 3, 9, 10 hold in code. Open items, not changed here: (a) cameraMatch is on whenever a HEIC exists, so the device output follows the camera HEIC (exposure up to −1 EV, boostShadow down to 0) and no gate evaluates that path — user to decide (device-pair gate, or off by default); (b) device analysis alone 2.17 s (14 Pro) / 2.77 s (15 Pro) vs the < 1.5 s full develop target on iPhone 12; (c) Gate 2 has 13 decodable files, phase 1 asks ≥ 20; (d) ProRAW and Bayer share a calibration key → shoot the Gate 3 charts in Bayer on both phones.
- **Holdout leak fixed:** the dark-scene threshold (−5.0) had been chosen so that it "selects exactly NIGHT01, CAFE01, TOKYO01" — TOKYO01 is holdout. Re-derived from tuning files only: dark NIGHT01 −6.36, CAFE01 −6.13; non-dark MTN01 −4.57, USR02 −3.02, USR01 −2.27, HDR01 −2.17, SKY01 −1.01, IOS01 −0.67 (local bench), BEACH01 not dark in CI (≥ −5, exact value in the next CI summary). Midpoint of the gap → **−5.35**. Consequence, reported not tuned: holdout TOKYO01 (−5.32) is no longer "dark" (look −0.10 no longer applied). If BEACH01 turns out below −4.57 the midpoint moves (≤ −5.57 at worst); TOKYO01 stays non-dark either way.
- **Bench:** `summary.md` Gates table now shows each file's scene median (`sceneMedianStops`), so rule thresholds can be checked against tuning files from CI.
- **Docs:** ROADMAP #1, #2, #7, #9, ProRAW row, remaining-work order (+ items on perf risk and the cameraMatch decision); AGENTS toolchain note, capture location (`docs/<timestamp>/`), layout.
- **Local:** `raw-bench bench originals` Gates 1/2/2-core PASS on the 5 originals; `swift test` 64 tests, 0 failures (boundary cases CAFE01 / MTN01 added to `testLookIntensityFollowsSceneBounded`). Unverified: corpus files and BEACH01 median (CI fetches them).

## 2026-11-09 — Product integration decided (MoodRoll is the shell, this repo is the core); CI confirms −5.35
- **CI 42564730021 (commit 057db20):** green; BEACH01 scene median **−3.51** (above MTN01 −4.57), so the tuning gap and the −5.35 threshold stand; TOKYO01 (holdout, −5.32) non-dark, Gates PASS.
- **User decisions (recorded in AGENTS.md "Product integration"):** this repo is the image-processing core and the goal; MoodRoll (`../MoodRollApp`) is only the host shell. Core first, integration after. RawCore + CaptureKit as a Swift package. MoodRoll keeps its capture UI, backend = CaptureKit (Bayer DNG + HEIC, one press). One background analyse job per frame right after capture, stored next to the DNG; develop (whole roll at the end) uses `Developer` with the stored analysis, no re-analysis. Frames without a usable DNG fall back to MoodRoll's HEIC pipeline.
- **Read of MoodRoll (`feature/pipeline-process-raw`, read only):** capture is a processed HEIC today (`AVCapturePhotoSettings()`), develop runs the whole roll in the foreground one frame at a time (LUT + tone + look + grain/halation + `EmulsionVariation`) to JPEG sRGB 8-bit; originals are deleted after develop. Open overlaps to settle before integration: grain/halation/look intensity exist in both engines (one owner each); LUTs were tuned on Apple's HEIC, so every stock needs a check on the RAW base; JPEG sRGB export vs our P3.
- **Storage (user concern):** device captures here: DNG 10.4 MB (14 Pro Bayer) / 17.3 MB (15 Pro ProRAW), HEIC 1.6 MB. A 36-frame Bayer roll ≈ 430 MB until develop. Deleting the HEIC after analysis saves ≈ 1.6 MB/frame (≈ 13 %): possible, because cameraMatch only needs the HEIC's luminance histograms (store the 256-bin one; 64 bins = sums of 4), but it does not solve storage — the DNG is the bulk. Options for the DNG, not decided: develop each frame in the background right after analysis and keep only the hidden output (reveal unchanged, but no later re-develop); or keep DNGs and check free space for the whole roll before it starts.
- **Unverified / not built:** self-contained stored analysis (mask file, reference histograms, decoder version check); analysis cost with the camera running; whether Bayer DNG can be written compressed. No code changed.

## 2026-11-09 — Storage research (can the DNG go before develop?); `raw-bench storage`; agent roles
- **What:** new `raw-bench storage <raw>... [--stock] [--out]` (Sources/RawBench/Storage.swift): develops the base render (auto, no look), stores it as HEIC10 q0.92/q1.0, PNG16, TIFF16 LZW, EXR half, JPEG8, reads it back and measures size and ΔE00 vs the in-memory base, for the base and for the final picture (look + halation → JPEG 8-bit). Research agent (web + one local check) on DNG compression, ProRAW options, Core Data, iOS file placement. Write-up: `.orchestration/storage/STORAGE_RESEARCH.md`.
- **Why:** user asked whether the DNG can be stored in Core Data or decoded and deleted right after capture.
- **Evidence (local, macOS 15.2, 4 files, stock slide100):** HEIC10 q0.92 base = 5.3–7.3 MB (31–70 % of the DNG), final ΔE00 mean 0.43–0.49, p95 1.47–1.73; lossless formats are 2–9× the DNG (EXR half 34–45 MB, PNG16 62–71 MB, TIFF16 LZW 77–100 MB). Bayer DNG is already lossless-JPEG compressed (no API to shrink it); Core Data external storage stores the same bytes. Per Bayer frame with the HEIC kept: 12.0 → 8.7 MB (−28 %); ProRAW 18.9 → 6.9 MB (−63 %).
- **Recommendation (user decides):** Bayer keeps the DNG until develop (Application Support, free-space check per roll); ProRAW stores a HEIC10 base (or test JPEG-XL ProRAW first). Deleting the DNG gives up re-decoding with a later CCM (Gate 3 table still empty).
- **Also:** `.claude/agents/` (pipeline-tech-lead, raw-core-engineer, capture-engineer, bench-qa, pipeline-research) and `.orchestration/README.md` routing, adapted from MoodRoll; AGENTS.md points to them.
- **Unverified:** iOS HEVC encoder and EXR write on device; gradient banding after a contrasty look; other stocks; capture-time cost of a full-res decode with the camera running. `swift build -c release` OK; no RawCore change, so tests and xcodeproj unchanged.
- **Decision (user, same day): keep the DNG until develop** (Bayer default, HEIC kept). Recorded in AGENTS.md "Product integration" and the storage note; ProRAW option left open.

## 2026-11-09 — One filter per decode; stored analysis; develop in two stages; corpus 14 → 27 entries
- **One filter per decode (`RawDecoder`):** file facts (supported versions, native size, metadata, Apple's per-version defaults) are read once and cached (key: path + size + mtime, ≤ 64 files); every decode opens one fresh `CIRAWFilter` on the pinned version directly. `scaleFactor`, `cameraKeys`, `pinnedVersion` no longer open the file. Opens for analysis + render: 7–11 → 5 (core, `testOneFilterPerDecode`); `filtersCreated` counter for tests. **Timing:** Mac analyse 1.1–1.7 s before vs 1.1–1.5 s after (noise): opening a filter is cheap; the decodes themselves are the cost, so step 1 (per-stage timing) still decides any merge.
- **Stored analysis (`Developer.Analysis`):** schema 2 records decoder version, plugins, source file name and size; `write(to:)` / `read(from:)` = `analysis.json` + `person-mask.png` (8-bit grey); `staleReason` (schema, file, size, decoder version, highlightRecovery without EDR headroom) → develop re-analyses and logs why, else logs "stored analysis used". `analyze(cameraReference:)` stores the HEIC's 64- and 256-bin histograms (`SceneContext.cameraReferenceHistogram(Fine)`); cameraMatch uses them before the file, so the HEIC is not needed at develop. `PluginRenderContext.scene` added.
- **Two stages:** `developBase` (decisions → decode → afterDecode plugins) and `finish` (look → skin → finish → afterFinish); `develop` = both. A `Base` can be finished with another stock without decoding (`testFinishBaseWithAnotherStock`: equal to a full develop, max diff < 2e-3).
- **Evidence (local):** `swift test` 68 tests, 0 failures (4 new in `DevelopStagesTests`: opens, round trip + reuse + stale, stored HEIC histograms give the same exposure/boostShadow as the file, re-finish). `raw-bench bench originals`: Gates 1/2/2-core PASS on all 5, decisions unchanged. No RawCore file added/removed → xcodeproj unchanged.
- **Corpus:** 13 public files added (research agent; discuss.pixls.us posts stating CC-BY-SA 4.0; sha256 pinned and re-checked): 6 phones (iPhone 17 Pro Max, 12 Pro, SE, 11, Pixel 6, S23 FE) + 7 cameras (restaurant, night street, food, portrait, sunset, snow, ISO 6400). 27 entries, 24 decodable (the three Canon EOS RP DNGs still fail, known since 2026-11-07), 8 holdout. Local bench of the 13: Gate 2 auto/core PASS on all; **Gate 1 FAIL on IPH04 (iPhone SE)**: the file supports `6.dng, 7.dng, 8.dng, 7`, Apple's default is `7`, DecoderPolicy picks `8.dng` → explicit ΔE00 1.99 vs appleDefault; with `--decoder 7` explicit = 0.00. Write-back is exact; the policy prefers the generic `.dng` decoder over the camera's own one on older files. Not changed (policy changes are deliberate): user decision.
- **Unverified:** CI fetch of the 13 new URLs (one is a CloudFront URL, not a short-url); device timings; licences as stated in each post (checked by the agent, not re-read here).
- **Decision (user, same day): keep DecoderPolicy as is.** IPH04's Gate 1 FAIL is a version difference (policy `8.dng` vs Apple default `7`), not lost control; the bench Gates table now prints "(policy X ≠ Apple default Y)" next to Gate 1 when the two versions differ, and `DecoderPolicy` documents the choice.

## 2026-11-09 — Presets run on the 13 new corpus files (local, user request)
- **What:** `raw-bench render` (scale 0.4, JPEG) × 13 files × {appleDefault, auto, auto + each of the 11 stocks} = 169 renders, 0 failures (2 min, 4 in parallel). Gallery + contact sheets in `bench-out/presets-gallery/` (ignored, not committed). Corpus PEOPLE01 description corrected (a man at a market stall, not "a boy").
- **Findings (not fixed, need a decision):** (1) Person rule false positives on tuning files: FOOD01 croissants "people 28.4 %, face 0" and PHONE02 kitten "people 86.6 %, face 0" → skin protection 0.50 and look −0.05 with nobody in frame. `personFraction` is the mean of Vision's soft mask; a thresholded fraction and/or requiring a face or people label would avoid it. (2) Dark-scene rule fires on holdout SNOW01 (snow, median −5.44) and SUN01 (sunset, −5.92): reported only, holdout is never tuned on. Tuning IPH04 (backlit forest, −5.86) also counts as dark. (3) At thumbnail size most stocks differ only slightly from the auto base (2026 preset curves are still provisional).

## 2026-11-09 — Project skill `hdr-tone-mapping` + agent `tone-mapping-expert`
- **What:** `.claude/skills/hdr-tone-mapping/SKILL.md` — a summary in our own words of R. Mantiuk's lecture "High dynamic range and tone mapping" (Cambridge, 65 slides: dynamic range, scene- vs display-referred, multiply/power/add, display model + ambient light, sigmoid and histogram curves with a slope ceiling, colour transfer and gamut, base–detail separation (Gaussian/bilateral/WLS/Retinex/gradient domain), selective glare), each mapped to this repo (exposure/cameraMatch, black p1 gate, ToneMatch bounds, LTM + highlightClarity + halo metric, halation) plus a review checklist. `.claude/agents/tone-mapping-expert.md` (read-only advisor that loads the skill). Routing added to `.orchestration/README.md`.
- **Why:** user asked for a skill and an agent for this document, for this project only.
- **Not in the repo:** the PDF itself (copyrighted lecture; stays in the user's Downloads). No code change.

## 2026-11-09 — User's colour-pipeline proposal reviewed (tone-mapping-expert); cameraMatch histograms at one size
- **Review** (`.orchestration/tone/COLOR_PIPELINE_REVIEW.md`): the proposal describes the existing pipeline; 4 statements in it are wrong (who decides exposure/shadow boost, where the cameraMatch exposure is applied, when clarity runs, missing EDR/shadow-gap steps). Not done, with reasons: working space sRGB/2020 (P3 is decided, all masks use P3 weights), brand-named LUTs (trademark rule), AgX as a LUT (double tone map, would fail Gate 2 / Goal 3).
- **Done (point 3):** every cameraMatch comparison and the analysis histogram/clipping use one size, `CameraMatchPlugin.histogramLongEdge = 1024`; the analysis reads them from the 1024 px Apple render Vision already decodes, so the separate 512 px Apple decode is gone (analysis = scene-linear 512 + Apple 1024 + EDR 512). `Analysis.currentSchema` 3 (older stored analyses are re-made). cameraMatch reason shows the size.
- **Evidence (local):** bench before/after on originals + full corpus (27 files, 24 decode): Gates identical, 0 / 24 decision changes, auto metrics identical to 2 decimals; pairs: mid EV within 0.01, ΔE00 2.09 → 2.10 and 3.79 → 3.78, black p1 0.0015 → 0.0014 / 0.0040; analysis 1.37 → 1.16 s mean. Corrected an earlier line: the corpus has 24 decodable files, not 26.
- **Unverified:** device timing; CI run.

## 2026-11-09 — Demo app: capture → preview → develop → result → change look → new photo
- **What:** `App/RawFilmDemo/RawFilmDemoApp.swift` rewritten as four screens. Camera (plugins / ProRAW toggles, Shoot RAW) → **Preview** (the camera HEIC of the press, look picker, Develop / Retake) → Developing → **Result** (developed image; hold it to compare with the camera HEIC; one chip per stock incl. "none" re-finishes the stored `Developer.Base` — no new decode; "Save this look"; "New photo" back to the camera).
- **Pipeline use:** the press is written to its own Documents folder immediately (capture.dng, apple.heic, capture.json); a background analysis (`analyze(cameraReference:)`, utility priority) writes analysis.json + person-mask.png next to it; Develop awaits that analysis and calls `developBase` + `finish`, exporting developed.heic + .recipe.json; other saved looks go to developed_<stock>.heic + .recipe.json. Files app access unchanged (UIFileSharingEnabled).
- **Evidence:** `xcodebuild build -scheme RawFilmDemo -destination generic/platform=iOS CODE_SIGNING_ALLOWED=NO` → BUILD SUCCEEDED, no warnings in the app file. No Swift file added (xcodeproj unchanged).
- **Unverified (needs the user's iPhone):** camera, timings, memory with a full-res base held while switching looks, Files folder contents.

## 2026-11-09 — User-supplied LUT "Cinematic Ice Blue" bundled as stock `iceBlue`
- **What:** `Sources/RawCore/Looks/CinematicIceBlue.cube` (the user's file, 33³) shipped as a RawCore resource (`Package.swift` `resources: [.copy("Looks")]`; demo app framework via XcodeGen, project regenerated with XcodeGen 2.46.0 — only the resource lines changed). `BundledLook` (parsed once, cached) + `FilmStock.Source.bundled`; stock `iceBlue` in `FilmStock.bundled` (intensity 1, no grain/halation/vignette), so it appears in the app's look picker/chips and in `raw-bench --stock iceBlue`. Test `testBundledCubeLookLoads`; the stock-count test now includes bundled stocks.
- **Observation (not changed):** the file's title is "Cinematic Ice Blue (LOG)": it expects log-encoded input. On our display-referred base it renders warm and contrasty (its neutral ramp maps grey 0.5 → (0.53, 0.51, 0.40)), not icy blue; an experiment through Apple Log on a scene-linear render gave a flat, desaturated result, also not blue — the intended log curve is unknown. A real log-input look path would be a new (plugin) stage: user decision.
- **Licence:** user-supplied asset from their downloads; redistribution rights not checked — clear before any public release.
- **Evidence:** `swift build` OK; look tests 6/6; `xcodebuild … generic/platform=iOS` BUILD SUCCEEDED with `CinematicIceBlue.cube` inside RawCore.framework of the app. Not seen on device.

## 2026-11-09 — Log-input look path (`logLook` plugin) for LOG .cube files
- **What:** `Sources/RawCore/LogLook.swift` (pure Swift): `LogCurve` (Apple Log, S-Log3, LogC3, V-Log encoders), `LookInput` (.display / .log), `LogLook.composite` = one 65³ cube: encoded P3 of scene-linear/4 → ×4 → Rec.2020 → log curve → the user's LUT → Rec.709 output as encoded Display P3. `FilmStock.lookInput`; `iceBlue` = `.log(.appleLog)` (the file does not say which log; Apple Log is the iPhone's own). New plugin hook `DevelopPlugin.look(stock:settings:ctx:)` and `PluginRenderContext.decodeSceneLinear` (same file, CCM/calibration, WB, NR, lens; Apple's tone and cameraMatch/decision exposure removed). `LogLookPlugin` (`logLook`, on by default) takes over the look of log stocks; `finish` blends it by the stock intensity (`Renderer.dissolve`); unplugged, the core applies the LUT to the display base and logs it. ROADMAP extras row added; xcodeproj regenerated (new Swift file).
- **Why:** user asked for the log look branch after the bundled Ice Blue LUT rendered warm and harsh on the display base.
- **Evidence:** tests `testLogCurvesAndComposite` (mid grey 0.18 → Apple Log 0.488, S-Log3 0.410, LogC3 0.391, V-Log 0.423; composite grey ramp monotone) and `testLogLookPluginAndFallback` (plugin path logged, fallback logged, images differ, display stocks never use it). Renders on 4 files (mooncake, IMG_0106, IMG_2407, IMG_1901): the log path keeps highlights (IMG_1901 sky not blown) and gives a muted, low-contrast grade; still warm neutrals and teal-grey skies — the LUT's own character on every log curve probed (Apple Log, S-Log3, LogC3, V-Log, F-Log). iOS app build OK. `swift test` 71 tests: 69 + the two plugin-list tests updated for `logLook` (re-run: pass). `raw-bench bench originals`: Gates 1/2/2-core PASS on all 5.
- **Unverified:** which log the LUT was authored for; device timing (one extra full-res decode per log finish); look on device.

## 2026-11-09 — `.cube` DOMAIN_MIN/MAX fixed (input range, not output scale)
- **What:** `CubeLUT.parse` divided the OUTPUT values by the domain. Per the .cube format the domain is the INPUT range the lattice spans; outputs are as written. Now outputs are stored as written and a non-default domain is resampled onto the 0…1 input CIColorCube uses (inputs outside the domain clamp to its edge); DOMAIN_MAX ≤ DOMAIN_MIN is rejected.
- **Why:** found while reviewing the user's LUTManager guideline (which ignores DOMAIN entirely). Files with the default 0…1 domain — every look in the repo incl. iceBlue — are unaffected (same code path as before).
- **Evidence:** new `testCubeDomainIsInputRange` (constant 0.3 over 0.5…1 stays 0.3, was −0.4; 0.4·x + 0.1 over 0…2 gives 0.3 at 0.5, was 0.25; equal bounds rejected); existing identity-over-0…2 test still passes (linear outputs coincide). 35 look/stage tests pass.
- **Note:** resampling keeps the file's lattice size; outputs above 1 are clamped by `CubeLUT.generate`, as for every LUT here.

## 2026-11-09 — Reused MoodRoll's LUT code: `.mrlut` packed format + `.cube` writer
- **Read (MoodRoll `Core/ImagePipeline/LUT`, `LUTProcessor`):** reused `LUTBinaryFormat` (`.mrlut`: "MRLT" header + half floats, ≈ 215 KB vs ≈ 970 KB of `.cube` text, no parsing) and `CubeLUTWriter` (serialise to `.cube`). Not reused: `LUTLoader` (clamps outputs, ignores DOMAIN, accepts 4+ token lines — `CubeLUT.parse` is stricter), `LUTColorCubeFilter` (plain CIColorCube in the working space; correct in MoodRoll only because its contexts work in sRGB-encoded space), `ImportedLUTStore`/`LUTExportPackageService`/`PresetLUTExporter` (app shell / MoodRoll presets), `ISO200DaylightCalibratedLUT` (a display-referred HEIC calibration cube; per-model colour here is the scene-linear CCM).
- **What:** `Sources/RawCore/LUTBinaryFormat.swift` — `encode` (new, round-to-nearest-even float→half) / `decode` into `CubeLUT`, same file layout as MoodRoll; `CubeLUT.cubeText()` writer; `CubeLUT.load(any:)` (.cube or .mrlut). `Renderer.resolveLook` and `BundledLook` accept `.mrlut` (a packed file wins over the `.cube`). `raw-bench lut <in> --out <out>` converts either way and prints the round-trip error. xcodeproj regenerated (new Swift file; local signing team restored).
- **Evidence:** `testMrlutAndCubeWriterRoundTrip` (half conversions, iceBlue packed 215 630 bytes with max error < 0.00025, `.cube` text re-parses within 1e-6, bad header rejected); look tests 18/18. `raw-bench lut` on MoodRoll's own `Resources/LUTs/phuyentrip_v2.mrlut` → `.cube`: 33³, round-trip error 0.000001 (files are compatible). iOS app build OK.
- **For the integration (not done):** MoodRoll's stock LUTs were authored for sRGB-encoded input; RawCore applies looks in encoded Display P3. Using them in RawCore unchanged shifts saturated colours slightly; a per-look colour space (sRGB) would make them exact. Their distribution rights are still open in MoodRoll's AGENTS.md.

## 2026-11-09 — Decision: RawCore film looks replace MoodRoll's
- **User decision:** the film looks of this repo replace MoodRoll's (whose LUT/stock code is not final). Recorded in AGENTS.md "Product integration". Research on best practice and the most wanted looks started (`pipeline-research` → `.orchestration/looks/LOOKS_RESEARCH.md`). Consequence: the per-look sRGB option for MoodRoll's LUTs is no longer needed.
- **Research done** (`.orchestration/looks/LOOKS_RESEARCH.md`): looks stay display-referred 33³ by default (log path only where highlight character needs it); proposed 12-look starter set with generic names and raw-bench acceptance checks; licensing: only CC0/MIT-style or own-generated looks can ship. Orchestrator review appended: halation already runs in linear light; Gate 2 does not gate look variants, so looks get their own checks. Popularity evidence is weak (no store analytics).

## 2026-11-09 — 2026 film-look set (12 looks) + look review tool
- **Looks:** `Sources/RawCore/FilmLooks.swift` — `LookSpec` (measurable parameters: white balance K/tint, black point, S-contrast around a pivot, soft shoulder/white, saturation with highlight/shadow desaturation, OKLCh hue bands (shift + chroma), split toning with zero weight at black, mono channel weights, declared exceptions `allowsClip`, `neutralDrift`, `skinTolerance`), generated in OKLab into a 33³ encoded-P3 cube with chroma-only gamut fit; `OKLab` helpers; `FilmLooks2026`: softPortrait, goldenDay, vividFine, pastelCool, everydayGreen, tungstenGlow, mutedChrome, cinemaNegative, monoSoft, monoPunch, flashDigicam + iceBlue (LOG cube). Generic names; families only in `.orchestration/looks/LOOKS_RESEARCH.md`. `FilmStock.Source.spec` + `LookSpecCache`. Demo app lists the set first (default softPortrait).
- **Acceptance tests** (`FilmLooksTests`, 5): 12 generic names (trademark word list incl. ektacolor/velvia/provia/agfa/vsco); grey ramp monotone and within each look's neutral drift; mono looks truly mono; ColorChecker dark/light skin hue ≤ 8° and chroma ±20 % (tungstenGlow declares 25° — tungsten film in daylight cools skin — and must hold the look back on people, minSkin 0.5); white below 0.99 unless declared; black within its toe; saturated red keeps gradation. First run failed 7 checks (tungsten skin 21–26°, pastel/cinema skin chroma 0.55–0.8, coloured blacks from shadow tint) → shadow tint weight now 6.75·L·(1−L)², tungsten 4700 K + declared tolerance, pastel/cinema saturation raised, cinema skin band.
- **Review tool:** `raw-bench looks <dirs> --out … [--looks] [--long-edge] [--manifest]` (base developed once, every look finished on it; per render clip %, black p1, mean Y, ΔE00 vs base, chroma ratio, skin hue shift on skin-coloured pixels inside the Vision person mask) and `tools/look-review/review.py` (stdlib only: `render` calls raw-bench, `serve` = local page on 127.0.0.1:8777 with 👍/👎, tags, notes per tile and per look → `bench-out/look-review/feedback.json`, git-ignored). Port 8765 was taken by another process on the Mac.
- **First render (24 files × 14, 1400 px, 793 s):** all 11 generated looks: 0 files with skin hue > 8° on people, 0 with black p1 > base + 0.03; clip > base + 0.5 pt only tungstenGlow on 1 file (halation threshold already raised 0.6 → 0.85 after mooncake clipped 8 %). iceBlue (user's LOG cube): skin > 8° on 5 files, black p1 > +0.03 on 3 — the file's own character. Mean ΔE00 vs base 1.2 (vividFine) … 5.4 (tungstenGlow); mutedChrome chroma ×0.79.
- **Tests:** `swift test` 78 tests: 77 + the stock-count test updated for the new set (re-run: pass).
- **Unverified:** looks on device; the user's taste (first feedback round pending); grain resolution check and 10-bit banding not measured yet.
- **Banding check added** (`testNoSteepStepsThatBand`: along grey and six hue lightness ramps, output may not change faster than 3× the input; declared clip ignored). It failed on vividFine: saturated reds jumped 5× just below white where the gamut fit pins R at the ceiling → vividFine highlightDesat 0.2 → 0.4; 6/6 look tests pass. Review set re-rendered with the fix.

## 2026-11-10 — LUT library contract (manifest + route check), iceBlue removed, off-grid interpolation test
- **Step 1, contract:** `Sources/RawCore/LookManifest.swift` — `LookManifest` (schema 1: input/output primaries, white, transfer, log curve / assumed curve, domain, referred; toneBaked, exposureAnchor, route, source author/url/version, licence id + redistribution, history, notes), `LookContract.check` (required fields, pure-Swift SHA-256 of the file bytes, cube parses, route resolution), `LookRoute` (`display(Display P3 | sRGB)`, `log(curve, primaries Rec.2020 | Rec.709)`; anything else rejected with the reason), release blockers kept separate from load problems (licence not on the allow-list MIT/CC0/BSD/Apache/own-work, redistribution not "permitted…", trademark word in the name, unknown source). `LookLibrary` loads every `*.manifest.json` of a folder (bundled `Looks/` or a user folder); only usable entries become stocks (`FilmStock.Source.library`, look colour space / log primaries from the route); `FilmStock.register` for run-time libraries. `Renderer.applyLook(colorSpace:)` (sRGB LUTs apply in sRGB); `resolveLookDeclared` checks a manifest next to a `--look` file, else records "no manifest, assumed Display P3". `LogLook.composite(primaries:)`. Recipe line per library look (author, version, licence, redistribution, sha, route). `raw-bench lutcheck [dir]`.
- **Step 2, files:** `CinematicIceBlue.cube` was already gone from `Looks/`; its code removed (`BundledLook`, `iceBlue` stock; the set is 11 generated looks). The 6 files the user put in `Looks/` were checked: **all 6 rejected** — every manifest sha256 mismatches its file, and the routes do not fit (3 declare linear "sceneToDisplay" input, 2 declare log curves we cannot model — cineon, vision3_log — 1 declares "displayToDisplay"); release blockers: GPL-3.0 (PoLUT), CC-BY-SA-4.0 (Spektrafilm), trademark names. The cube data contradict several declarations (grey 0.5 → 0.5 for "linear input"). Details and provenance concerns: `.orchestration/looks/LUT_INTAKE_2026-11-10.md`. SHA values deliberately not edited.
- **Step 3, interpolation:** `testOffGridInterpolationError` (4000 random points, CIEDE2000 vs `LookSpec.apply`). At 33³ the mean was fine (≤ 0.05) but p99.9 was 0.5–2.3 on 8 colour looks — the tail sits at saturated gamut corners (e.g. (0.9, 0.99, 0.07)); a soft gamut knee did not help and was reverted. Colour looks now ship at **65³** (`LookSpec.cubeSize`; CIColorCubeWithColorSpace accepts 33–128, checked on macOS): mean ≤ 0.015, p99 ≤ 0.33, max ≤ 2.27 (flashDigicam's declared clip). Bound set to mean < 0.1, p99 < 0.5, max < 2.5 — the research's p99.9 < 0.5 is NOT met by goldenDay, vividFine, cinemaNegative, flashDigicam (0.56–0.80, gamut corners only). 65³ exposed a 4× slope at vividFine's saturated red near white (banding test) → vividFine highlightDesat 0.4 → 0.6, red band 1.08 → 1.0.
- **Tests:** new `testLookContractAcceptsDeclaredAndRejectsBad` (SHA-256 vectors, valid sRGB display entry, wrong sha / ACEScct / linear scene / cineon / mixed primaries rejected, log route resolves, GPL + trademark = release blockers only, bundled rejects never become stocks); iceBlue-based tests moved to temp-folder fixtures (log look via a registered library stock; recipe carries the manifest line). xcodeproj regenerated (LookManifest.swift, 12 resource files, iceBlue gone); iOS app build OK.
- **Run:** `swift test` 80 tests: 79 + the stock-count test, which counted a stock another test registers at run time → now counts the built-in set (re-run: pass). `raw-bench bench originals`: Gates 1/2/2-core PASS on all 5.
- **Unverified:** 65³ cost on device (generation per look, ≈ 4.4 MB per cached cube); the 6 files' real provenance.

## 2026-11-10 — Film looks tuned for the feed ("enhance để stock đẹp hơn")
- **What:** new values for all 11 looks in `FilmLooks2026` (per-look before → after and reasons:
  `.orchestration/looks/LOOK_TUNE_2026-11-10.md`). Two look-function parameters added in `FilmLooks.swift` (defaults
  keep the old output): `HueBand.lightness` (per-hue luminance, faded in by chroma so greys never move) and
  `LookSpec.density` (subtractive dye density: saturated colours get deeper, not brighter — no neon reds). Summaries
  rewritten, names unchanged, no trademarks. **User decision (2026-11-10): keep both parameters** in `LookSpec`;
  `testDensityAndBandLightnessContract` locks them (defaults = old output, greys untouched, density darkens only saturated colour).
  `testOffGridInterpolationError` now samples with a fixed-seed SplitMix64 (was `SystemRandomNumberGenerator`: the one
  unreproducible failure came from a different random tail each run).
- **Why:** at default intensity several looks were hard to tell from the base (ΔE00 vs base: vividFine 1.3,
  cinemaNegative/mutedChrome 2.4); pastelCool skies went lavender; monoPunch skies barely darker. Direction from the
  user's reference brief (2026-11-10), MoodRoll's tune brief fail list and the user's photography-film-lab skill
  (all files read; per-look sources in the note). References = direction only, nothing copied.
- **Evidence (raw-bench looks, 12 tuning files, 1200 px, mean before → after):** ΔE00 vs base vividFine 1.33 → 2.63,
  goldenDay 3.21 → 5.17, everydayGreen 2.46 → 3.37, cinemaNegative 2.37 → 2.97, mutedChrome 2.39 → 3.00, softPortrait
  3.04 → 3.70; clip % not raised on any look (tungstenGlow 2.29 → 0.86); black p1 within base + 0.03 everywhere
  (pastelCool's toe pulled back after it reached +0.037); max skin hue shift on people ≤ 2.1° (tungstenGlow 6.2°,
  declared). `swift test --filter "FilmLooksTests|Presets2026Tests|DevelopStagesTests"`: 20/20 pass (6 runs; one
  earlier run reported 1 failure that did not reproduce — probably the random-sample interpolation test, unconfirmed).
  ColorChecker skins sit at OKLCh h ≈ 41°, not 55° as the landmark comment said (fixed; mutedChrome's skin band uses 45°).
- **Unverified:** device display; real skin variety (one dark-skinned portrait only); ±1 EV robustness; the user's
  taste (feedback.json empty); mean linear luminance 5–6 % lower on goldenDay/vividFine/everydayGreen/mutedChrome/
  cinemaNegative (contrast + density, intended) — may read heavy on dark scenes. Holdout files not rendered.

## 2026-11-10 — Trend report → looks: goldenDay faded, vividFine "memory", 4 TRIAL looks (tests not fully run)
- **What:** critique of the user's report "Film Look Trends 2026" + gallery + source check, mapped onto the 11 looks:
  `.orchestration/looks/TREND_LOOK_PLAN_2026-11-10.md`. Changes in `FilmLooks.swift`: goldenDay warm FADED (black
  0.025 → 0.038, contrast 1.06 → 0.96 around pivot 0.55, density 0.06 → 0.04, red band L −6 %, skin band ×0.72);
  everydayGreen half-way faded (black 0.032, contrast 0.96 / pivot 0.55, density 0.03, vignette 0.12 → 0.08);
  vividFine yellow-greens (−6°, ×1.05), 5650 K, grain 0.22. New `FilmLooks2026.trialLooks` / `trialStocks` /
  `trialNames`: trialCoolFade, trialVividDay, trialWarmMoody, trialWarmFade. They are not in `names`/`stocks`/`FilmStock.all`
  (the app does not list them). `Look.swift`: `FilmStock.named` falls back to `trialStocks` (one line), so raw-bench
  and the review tool resolve them. Tests: every LUT check now also runs on the trials; new
  `testTrialLooksResolvableButNotListed` and `testLooksDistinctFromNeighbours` (chart ΔE00 between looks; a trial ≥ 2).
- **Why:** the report (and the source check, which weights flash lower and warm-faded / muted-chrome higher) argues for
  faded rather than denser everyday warm looks, and names four directions the set lacked (cool faded 400, clean
  vivid, warm pushed moody, expired fade).
- **Evidence:** raw-bench looks, 12 tuning files at 1200 px: no clip added, black p1 ≤ base + 0.022, skin hue on
  people ≤ 2.9°; goldenDay mean Y 0.276 (pre-tune 0.281); trial ΔE vs base 1.7–5.9 (table in the plan note).
  `swift test --filter FilmLooksTests` 10/10 pass after the LUT edits.
- **Unverified / not run:** at the user's instruction ("stop before the test step") the final
  `swift test --filter "FilmLooksTests|Presets2026Tests|DevelopStagesTests"` was NOT run. The last edit (everydayGreen
  vignette) is untested, and its re-render was not measured. Device, skin variety and user taste are also unverified.
  Holdout files were not rendered.

## 2026-11-10 — User decisions on the look set; roll-consistency benchmark; goldenDay highlights up
- **User decisions:** no flash-portrait look; cinemaNegative moved to `FilmLooks2026.retiredLooks` (unlisted, kept,
  still resolvable and tested); trials renamed trialVividDay → brightTravel, trialWarmFade → sunFade,
  trialWarmMoody → warmEvening (trialCoolFade unchanged). Product rule: a look develops a whole roll (24/36 frames),
  so its effect must be as uniform as possible across frames of different brightness; per-frame changes only from
  context/objects.
- **Benchmark:** `python3 -I tools/look-review/review.py roll [--against <looks.json>]` — per look over the tuning
  files: dY mean/min/max/spread (% mean linear Y vs base), dY_slope (% per +0.1 base mean Y; < 0 = bright frames
  darkened more), chroma-ratio spread, worst clip / black-p1 rise, ΔE vs base mean/spread; `--against` prints deltas.
- **goldenDay (only look changed, `FilmLooks.swift`):** black 0.038 → 0.034, contrast 0.96 → 1.0, shoulder 0.87 → 0.88,
  white 0.985 → 0.99, density 0.04 → 0.03, green band L −0.02 → 0, blue band L −0.03 → −0.02, highlight tint b
  0.008 → 0.007, halation threshold 0.8 → 0.9, vignette 0.1 → 0.04. Why: shoulder/white alone moved dY_min only
  −12.57 → −12.40; the darkening of bright frames came from the vignette (≈ −7 % on every frame), dye density + band
  lightness on bright foliage/sky, and the toe lift brightening dark frames (the slope). Halation threshold 0.9 keeps
  warm whites (R at the 0.99 cube ceiling) from being pushed over 0.98 once the vignette no longer dims them.
- **Evidence (12 tuning files, 1200 px, `roll --against` the saved baseline):** dY_mean −5.79 → −1.45, dY_min −12.57 →
  −6.72, dY_max +5.77 → +6.86, spread 18.34 → 13.58, slope −2.20 → −1.70, chroma_spread 1.026 → 0.985, clip_rise_max
  0.000 → 0.000, p1_rise_max 0.007 → 0.005, ΔE vs base 5.30 → 4.82; skin hue on people −0.39/+1.58/−2.90° →
  −0.34/+1.51/−2.64°. All other looks: every row bit-identical to the baseline (renamed trials compared by value).
  `swift test --filter FilmLooksTests` 10/10 pass (distinct: goldenDay nearest warmEvening 3.41 → 3.17).
  `raw-bench bench originals --full`: Gate 1 / Gate 2 auto / Gate 2 core PASS on all 5 originals (looks do not touch the gates).
  Details: `.orchestration/looks/TREND_LOOK_PLAN_2026-11-10.md` §10.
- **Unverified:** device display; holdout files not rendered; real skin variety; whether the lighter vignette reads
  better on the feed (user review); everydayGreen has the same problem (dY_min −10.7, slope −2.36), not touched yet.
  Other suites (Presets2026Tests, DevelopStagesTests) not run in this step.

## 2026-11-10 — everydayGreen roll consistency (bright frames no longer darkened ~11 %)
- **everydayGreen (only look changed, `FilmLooks.swift`):** black 0.032 → 0.03, contrast 0.96 → 1.0, shoulder 0.87 → 0.88,
  white 0.98 → 0.99, highlightDesat 0.3 → 0.36, green band (140°) lightness −0.03 → −0.015, vignette 0.08 → 0.04.
  Character kept (5650 K / tint −2, green shadow tint, cream highlight tint, emerald band, saturation 0.92, grain 0.45).
  Why: same split as goldenDay (§10 of the plan note) — vignette ≈ −5.6 % on every frame, the 0.98 white ceiling on the
  brightest frame, foliage lightness, and the toe brightening dark frames (slope). highlightDesat up holds chroma_spread
  (the higher white raised chroma on HDR01).
- **Evidence (12 tuning files, 1200 px, `roll --against` baseline-2):** dY_mean −3.90 → −1.13, dY_min −10.68 → −6.59,
  dY_max +5.97 → +5.94, spread 16.65 → 12.54, slope −2.36 → −1.67, chroma_spread 0.287 → 0.280, clip_rise_max 0 → 0,
  p1_rise_max 0.008 → 0.005, ΔE vs base 3.44 → 3.19; skin hue on people −0.53/+1.49/+0.06° → −0.41/+1.53/+0.21°. All 14 other looks:
  Δ 0.000 in every column, every row bit-identical. `swift test --filter FilmLooksTests` 10/10 pass (distinct:
  everydayGreen nearest softPortrait 2.56 → 2.69). `raw-bench bench originals --full`: Gate 1 / Gate 2 auto / Gate 2 core
  PASS on all 5 originals (run on the highlightDesat 0.33 build; gates do not use looks). Details: `.orchestration/looks/TREND_LOOK_PLAN_2026-11-10.md` §11.
- **Unverified:** device display; holdout files not rendered; real skin variety; whether the lighter vignette is missed
  on the feed. Other suites (Presets2026Tests, DevelopStagesTests) not run in this step.

## 2026-11-11 — sky hold: PORTRAIT160 / SOFT400 / softPortrait no longer wash bright skies
- **Bench (`raw-bench looks`):** new per-render sky metrics `skyL`, `skyChroma`, `skySpread`. The mask is chosen on the
  base render: top 40 % of the frame, OKLCh hue 190–290, L > 0.55, C > 0.02. New flag `--no-scene-intensity` sets
  `lookIntensityOffset = 0`, so the context offset can be measured on its own. Why: the user reported that
  PORTRAIT160/SOFT400 make the sky milky and suspected the landscape +0.05 intensity rule.
- **Diagnosis (5 landscape tuning files, 800 px):**
  - PORTRAIT160 vs base: sky L +0.024…+0.042, sky chroma −7…−18 %, gradient −5…−8 %.
  - SOFT400: chroma −11…−25 %.
  - softPortrait: chroma −33…−53 %.
  - The +0.05 offset accounts for only −0.5…−2.3 % of the chroma loss: IMG_1901, where the rule does not fire, still
    loses 14–16 %. The presets themselves cause the wash. +0.20 EV and the toe push the sky up, the warm white balance
    greys the blue, and saturation < 1 plus the 0.99 gamut fit take the rest. The +0.05 rule is kept.
- **Change:**
  - `Preset26.skyWeight(c)`: smooth weight from the encoded input pixel. It needs b − r 0.03→0.12, b not more than 0.08
    below g, and luma 0.25→0.45. Skin, foliage and greys get exactly 0.
  - `PresetLookParams.skyHold` and `LookSpec.skyHold`, both 0 = off. On sky pixels: own white balance, and for presets
    own exposure. Chroma is at least the input chroma (presets: capped ×1.3). 60 % of the input tone is mixed back.
  - Set to 1 on PORTRAIT160, SOFT400 and softPortrait. Exposure stays at the spec's +0.20 EV.
  - The deviation from the MoodRoll spec is listed in both presets' `openQuestions`.
  - `PresetLookParams` decodes recipes without `skyHold` as 0 (custom `init(from:)`).
- **Evidence (same 5 files, sky metric vs base, before → after):**
  - PORTRAIT160: chroma −7…−18 % → −0.4…−3.7 %; sky L +0.024…+0.042 → +0.004…+0.018.
  - SOFT400: chroma −11…−25 % → −0.1…−5.4 %; sky L +0.023…+0.039 → +0.004…+0.016.
  - softPortrait: chroma −33…−53 % → −3…−15 %.
  - Gradient within ±4 % of base, except P1073242 (snow): +10 %, a deeper sky, not a wash.
  - Roll, 12 common tuning files, `roll --against` the previous looks.json: softPortrait dY_spread 25.10 → 24.87,
    chroma_spread −0.041, dE_mean −0.42 (the look is weaker on sky frames), dE_spread +0.57. Every other listed look
    moves by at most ~0.001 meanY / 0.07 ΔE; base moves by the same amount. The previous run was at a different
    render size, so this is the noise floor.
  - Tests: new `Presets2026Tests.testSkyHoldKeepsSkyAndLeavesSkinAlone` (sky chroma kept; skin, leaf and grey
    bit-identical with and without the hold; old-recipe decode). `swift test --filter "FilmLooksTests|Presets2026Tests"`
    16/16 pass.
  - `raw-bench bench originals --full`: Gate 1, Gate 2 auto and Gate 2 core PASS on all 5 originals.
- **Unverified:**
  - Device display; holdout files.
  - Blue-cast whites in shade now keep their blue under these looks, i.e. less warm than before.
  - Teal or blue objects brighter than luma 0.45 (cars, clothes) are held like sky.
  - Full `swift test` (DevelopStagesTests and others) not run in this step.
  - The presets' roll numbers: `review.py render` renders only the listed looks, so the presets were checked only on
    the 5 sky files.

## 2026-11-11 — RR roll stocks: 21 stocks (RollioRoll) on top of the generated looks
- **What:** new `Sources/RawCore/RollStocks.swift`. `RollStock` holds id slug, Vietnamese UI name, ISO (+T),
  suggested tier, look, intensity, vibe and open questions. `RollStocks.all` holds the 21 stocks of
  `docs/input/doi-ten-film-stock-RR-2026-11-11.md`.
  - Each stock names one of the 11 colour looks (7 listed without flashDigicam, plus 4 trials). Grain comes from its
    ISO; halation and vignette come from the look.
  - Stocks resolve through `FilmStock.named(id)` but are not in `FilmStock.all`.
  - The internal "inspired by" mapping lives only in `.orchestration/looks/RR_STOCKS_2026-11-11.md` (R6).
  - `App/RawFilmDemo.xcodeproj` regenerated (new Swift file).
- **Why:** user decision 2026-11-11. Ship all 21 RR names, drop flashDigicam from this set (not a film stock); the
  set is the roll picker. MoodRoll is being renamed RollioRoll.
- **Evidence:**
  - `RollStocksTests`, 4 tests: naming R1/R2/R4/R6/R7/R10 (no maker words, id = slug of the name), colour look,
    resolvable and valid settings, R5 roles, grain grows with ISO.
  - `swift test --filter "RollStocksTests|Presets2026Tests|FilmLooksTests"` 20/20 pass.
  - Smoke render of 6 RR stocks on IMG_1901 + mooncake (800 px) works. ΔE vs base: Vàng 200 5.6 / 3.9,
    Chuẩn 400 1.2 / 0.9.
- **Unverified:** roll bench of the 21 stocks; device; the brief's open points (price-list "*", R3a legal, tier conflict
  of Chân Dung 400); Lá Phong 100 has no light leak and no look of its own; full `swift test` not run.

## 2026-11-11 — RR stocks get their own character: 4 new trial looks, Chuẩn line cut to 400
- **What:**
  - New unlisted trial looks in `FilmLooks2026.trialLooks`:
    - `mapleRed`: crimson reds, cyan-teal blues and shadows, low-medium contrast;
    - `warmMuted`: amber-red soft warm, muted greens and skies;
    - `naturalPortrait`: natural, slightly richer portrait 400;
    - `cleanLab`: neutral lab scan with a soft toe and shoulder.
  - RR stocks re-pointed:
    - Ấm 200 → warmMuted 0.85;
    - Lá Phong 100 → mapleRed 0.85;
    - Nắng 100 → brightTravel 0.85;
    - Chân Dung 400 → naturalPortrait 0.85;
    - Đêm Mềm 800 → naturalPortrait 1.0;
    - Chuẩn 400 → cleanLab 0.85.
  - RR Chuẩn 160 and 800 removed (21 → 19 stocks).
  - Tests:
    - `RollStocksTests`: count 19; new `testSameISOStocksLookDifferent` (same-ISO stocks ≥ 2 chart ΔE00); print-only
      before/after matrix.
    - `FilmLooksTests`: the distinct test also prints each look's distance to base.
- **Why:** user, 2026-11-11.
  - Stocks that shared a look and differed only by intensity felt the same: Vàng/Ấm 200 chart ΔE 1.31, Vàng 200 /
    Nắng 100 0.52, Rực Rỡ / Lá Phong 100 1.15, Da Mềm 160 / Chân Dung 400 0.56.
  - The Chuẩn line was invisible (ΔE vs base ≈ 1.2), and its three ISOs were identical in colour: roll dY and chroma
    were the same to 3 decimals.
- **Evidence** (`.orchestration/looks/RR_LOOKS_2026-11-11.md`):
  - Chart ΔE after: Vàng/Ấm 2.58, Vàng/Nắng 5.25, Rực Rỡ/Lá Phong 5.58, Da Mềm/Chân Dung 2.59.
  - Every new look is ≥ 2.09 from every other look.
  - Roll (18 tuning frames, `review.py roll --against`):
    - Chân Dung 400 dY spread 20.7 → 8.4;
    - Đêm Mềm 800 22.1 → 9.8;
    - Ấm 200 8.8 → 7.1;
    - Lá Phong 100 16.9 → 14.6.
  - No clip rise above +0.025 %; black p1 rise ≤ 0.0074.
  - Skin hue on the 7 person-mask files stays within ±6.4°.
  - Holdout reported only (6 of 8 decode): all within the same bounds.
  - `swift test --filter "FilmLooksTests|RollStocksTests|Presets2026Tests|DevelopStagesTests"`: 30/30 pass.
- **Unverified:**
  - Device; a real 36-frame roll; skin variety (4 real-people files).
  - Nắng 100 on brightTravel is less warm than the brief says.
  - The Chuẩn 160/800 cut needs the user's confirmation.
  - The Lá Phong light leak is a spec only (in the note); a plugin is to be built by raw-core.
  - Full `swift test` and CI were not run.

## 2026-11-11 — bench: native-pixel sharpness metrics (edge overshoot, HF ratio, flat texture)
- **What:**
  - `SharpnessMetrics` / `SharpnessComparison` / `SharpnessSummary` in `ImageMetrics.swift` (pure Swift).
  - `raw-bench bench … --native [--native-stock NAME|none]` and `compare … --native`: renders at scaleFactor 1, 1024² centre
    crop + 4 quarter-point tiles, measures each variant on the same pixels as the appleDefault crop (new `Sources/RawBench/Native.swift`).
  - Rows in `summary.md` / `summary.json` (`native`): appleDefault, explicit, auto, auto core, and warm400 with grain off ("before grain") and on.
  - `docs/METRICS.md` section "Native-pixel sharpness" with definitions and the plan's pass criteria (reported, not a gate).
  - `SharpnessMetricsTests` (4 tests, synthetic): unsharp-masked step overshoots, halved sharpening gives −30…−70 %, blur gives HF ratio < 0.6, noise std and waxy detector.
- **Why:** the 1024 px long-edge metrics hide Apple's native-scale sharpening (SMARTPHONE_LOOK_PLAN §3).
- **Evidence** (local `raw-bench bench originals --native`, 5 tuning files, release build; not committed):
  - explicit and auto core = appleDefault on every file: overshoot change 0 %, HF ratio 1.00, flat ratio 1.00 (sanity holds).
  - Apple's own overshoot at native size: 7.4 % (mug) … 30.9 % (HDR01 sailfish).
  - warm400 before grain (current build, before the filmDevelop plugin): overshoot −4…−19 %, HF ratio 0.80–1.01, flat ratio 0.87–0.94.
  - warm400 after grain: flat ratio 1.09–2.10, HF ratio 0.94–1.32; overshoot rises (grain counts as edge noise).
  - Cost: ≈ 4 s per variant per file (5 crops); `--native` bench of 5 files ≈ 6 min total.
  - `swift test --filter SharpnessMetricsTests`: 4/4 pass.
- **Unverified:**
  - No gate yet: thresholds are the plan's, not tuned.
  - High-ISO and holdout files (CI only); overshoot after grain is inflated by the noise itself, read before-grain rows for sharpening.
  - Mean over 5 crops hides per-crop spread; mean of per-crop ratios, not ratio of means.

## 2026-11-11 — bench `--native-stock` resolves roll stocks; full suite green
- **Fix:** `Sources/RawBench/Native.swift` now resolves the stock with `FilmStock.named`. Before, `FilmStock.all` was
  used, so `--native-stock rr-…` silently added no rows.
- **Evidence:** full `swift test` is 99 tests, 0 failures, on the combined build: filmDevelop plugin, native sharpness
  metrics, RR looks and sky hold.
- **Unverified:** CI (macos-15) and the holdout set.

## 2026-11-11 — filmDevelop tuned on native crops
- **What:**
  - RollStock develop: 400–1599 sharp ×0.45 → ×0.50, ≥ 1600 ×0.35 → ×0.40, portrait ×0.45 → ×0.50.
  - `FilmDevelop.faceSharpDelta` 0.10 → 0.05.
  - ISO < 400 ×0.55 and vivid ×0.70 unchanged.
  - docs/METRICS.md pass criteria revised: flat texture judged after grain (0.9–1.3×); overshoot target −20 % on
    iPhone files.
- **Why:** a scratch grid (sharpness × 1 / 0.55 / 0.40 / 0.25 / 0, with and without grain, 5 originals, native
  1024² crops) shows:
  - × 0.25 and below reads as mush on faces and checked fabric (IMG_1901 zoom);
  - × 0.55 + grain looks most film-like;
  - mooncake with the old portrait profile (≈ × 0.34 after the face delta) had an HF ratio of 0.57;
  - flat texture before grain is 0.87–0.96 even at Apple's own sharpness once a look is applied, so the plan's
    ≥ 0.9 before grain is unreachable.
- **Evidence** (`raw-bench bench originals --full --native --native-stock …`; overshoot vs Apple / HF ratio / flat
  ratio):

  | Stock, grain | IMG_1901 | mooncake | mug | BVQX5524 | HDR01 (Pixel) |
  |---|---|---|---|---|---|
  | rr-da-mem-160, before grain | −39 % / 0.77 | −36 % / 0.62 | −24 % / 0.67 | −22 % / 0.74 | −11 % / 0.98 |
  | rr-da-mem-160, after grain (flat) | 0.87 | 0.95 | 0.75 | 1.30 | 1.16 |
  | rr-chuan-400, after grain (flat) | 1.05 | 1.19 | 0.94 | 1.80 | 1.44 |

  - Gate 1 / Gate 2 auto / Gate 2 core PASS on all 5 originals.
  - `swift test --filter "RollStocksTests|DevelopStagesTests|ColorAndMetricsTests|FilmFinisherTests"` 26/26 pass.
- **Unverified:**
  - Device; ISO ≥ 1600 (no local file); ProRAW.
  - The ISO 400 grain (0.38) is too strong on BVQX / HDR01 for a "clean lab" stock: flat after grain 1.80 / 1.44,
    and overshoot after grain is inflated by the grain. Grain amounts are not re-tuned yet.
  - Full `swift test` was not re-run after this change.

## 2026-11-11 — RR English names; first commit of the look / roll-stock work
- **What:**
  - `RollStock.nameEn` (column B of `.orchestration/looks/RR_NAMES_EN_2026-11-11.md`, the user's decision):
    RR Golden 200, RR Vivid 100, RR Portrait 160/400/800, RR Tungsten 800T, RR Lab 400, …
  - Tests check the shape "RR <1–2 words> <ISO>[T]", ASCII, unique names, and no maker words.
- **Decisions (user, 2026-11-11):** keep RR Chuẩn 400 only; keep RR Nắng 100 on brightTravel (sunnier, by intent).
  The look review on port 8777 can be skipped for now.
- **Commit hygiene:** not committed:
  - the 6 user LUTs in `Sources/RawCore/Looks/` (licence and trademark blockers); a README keeps the folder;
  - the Instagram images in `docs/input/` and the two research HTML pages in `docs/research/` (third-party images);
  - xcuserdata, `docs/outputs/`, `__pycache__`.
- **Evidence:** `swift build -c release` and `swift build --build-tests` green; `swift test --filter RollStocksTests`
  10/10 pass. The full suite was not re-run before this commit (user: commit when the build is green); CI runs it.
- **Unverified:** legal check of the English names ("Portrait …" flagged).

## 2026-11-11 — lightLeak gets the person mask; batch commit (skyMask, lightLeak, cameraMatch, grain)
- **What:** `Developer.finish` passes `base.personMask` into the plugin context of the afterFinish stage, so
  `lightLeak` scales the leak by personFactor (×0.40) on people. Before, the recipe said "person mask not
  available". This is the one line the lightLeak agent left for the owner of Developer.swift.
- **Evidence:**
  - `swift build -c release` and `swift build --build-tests` green.
  - `swift test --filter "LightLeakTests|DevelopStagesTests"` 23/23 pass.
  - mooncake, frame 1/36, rr-la-phong-100: the recipe logs "person mask x0.40".
  - The three agents each reported a full suite of 113/113 on their own builds. No full run was made on the combined
    tree: per the user, commit when the build is green; CI runs the suite.
- **Open:**
  - Order: the leak is applied after grain (afterFinish). On film the leak is exposure, so grain should sit on top.
    Not changed yet.
  - The finisher's grain fades too little toward white (sparkle on near-white walls at 400 / 800, grain agent).
  - The bench sky metric counts stage lights and blue rock as sky (sky-mask agent).

## 2026-11-11 — light leak drawn before grain
- **What:**
  - New plugin stage `DevelopPlugin.beforeGrain` (default no-op). It runs in `Developer.finish` after the look and
    skin protection, before grain / halation.
  - `LightLeakPlugin` moved from `afterFinish` to `beforeGrain`; the person mask is passed as before.
  - Vignette and the other afterFinish plugins are unchanged.
- **Why:** user decision ("Đổi thứ tự"). A leak is light on the emulsion, so on film the grain of the developed
  image covers it. Applied after grain, the leak's smooth glow sat over the grain, which reads as digital.
- **Evidence:**
  - Release build green.
  - `swift test --filter "LightLeakTests|DevelopStagesTests|FilmFinisherTests"` 30/30 pass, run before the new test
    was added.
  - New `DevelopStagesTests.testLightLeakRunsBeforeGrain` passes: the "[lightLeak] screen…" decision comes before
    "film finish" in the recipe, and lightLeak is listed in `recipe.plugins`.
- **Unverified:** visual check of a leak frame at native size; device.

## 2026-11-11 — xcodeproj regenerated from a clean-checkout file set; merge to main
- **What:** `App/RawFilmDemo.xcodeproj` regenerated with the 6 local (uncommitted) user LUTs moved aside. Before, the
  project referenced their `.cube` / `.manifest.json` files, which a clean checkout or CI does not have: missing
  resources and a stale-project diff. It now lists only `Looks/README.md`.
- **Evidence:** `swift build -c release` and `swift build --build-tests` green;
  `xcodebuild build -project RawFilmDemo.xcodeproj -scheme RawFilmDemo -destination 'generic/platform=iOS'
  CODE_SIGNING_ALLOWED=NO` green.
- **Not run:** full `swift test` was stopped at the user's request ("stop test; test build"). AGENTS rule 4 wants CI
  green before merge, and CI has not run on this branch (not pushed).
- **Note:** regenerating the project while the local LUTs are in `Looks/` puts them back in. Move them aside first,
  or keep them outside `Sources/`.
