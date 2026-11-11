# Trend → look plan 2026-11-10 (photography-film-lab)

Inputs: the user's report `docs/research/Film Look Trends 2026.html` (text extracted with a stdlib script; its
figures are illustrations, not market photos), its visual appendix `docs/research/Film Look Gallery 2026.html`
(17 reference images, looked at one by one; copyrighted, direction only; 03/08/11/16 are renders of the six external
LUTs that `lutcheck` REJECTED and are ignored; 17 is an AI illustration and is ignored), and the source check
`.orchestration/looks/TREND_2026_BRIGHT_VS_MOODY.md`. Stock, app and brand names in those files are used here for
reasoning only. No look is named after them.
Scope: values in `Sources/RawCore/FilmLooks.swift`, tests in `Tests/RawCoreTests/FilmLooksTests.swift`, one line in
`Sources/RawCore/Look.swift` (trial lookup). Nothing committed.

## 1. How much weight the report carries

The report's verdict is: no single winner. Lead with warm + faded + visible grain (+ direct flash). Vivid only as
stock-like vivid, for travel and Tết. Moody and B&W are a real but narrow segment. Teal-orange only light. It proposes
a 10-preset split and the rule "grain + lifted black on every preset except the one clean vivid".
The source check changes the weights:
- **Lower weight:** Envato "+31 % film grain" counts motion-graphics template searches, not photo grading. The
  InspireFusion "direct flash #1" ranking could not be found. The Instagram Flash filter existed by April 2026 and has
  since been removed. ProCCD install numbers conflict between sources. So the flash/digicam direction is real (Google
  "digicam" interest, apps, celebrity posts), but the report rates it too high.
- **Holds (H/M):** Fuji X Weekly's 2026 top list: #1 a portrait-negative recipe on a muted-chrome base, #2 a
  slide-vivid recipe, #4 a warm consumer recipe. The VSCO film re-release (portrait negative, warm consumer, cool 400,
  grainy B&W). That is evidence for **warm faded and muted-warm chrome first**, slide-vivid second, cool 400 third.
- **No data at all** compares bright and moody engagement, or gives Vietnamese taste. The only Vietnam-specific
  signal is Tết red/yellow. That is seasonal and comes from one month of social posts.
- The source check suggests keeping the **mean Y of the everyday looks within about −2 % of their level before
  today's tune**, because the phone's default is "bright" and a darker everyday look reads as a deliberate darkening.

## 2. Mapping: report direction → our look

| # | Report direction (weight after the source check) | Ours now | Fit | Action |
|---|---|---|---|---|
| 1 | Warm faded: grey-not-black blacks, soft contrast, golden (HIGH) | goldenDay | Colour yes, tone **no**: today's tune made it denser (γ 1.06, density 0.06, mean Y −6 %) | **Changed** to faded: black 0.025 → 0.038, γ 1.06 → 0.96 around pivot 0.45, density 0.06 → 0.04 |
| 2 | Soft skin portrait negative (HIGH) | softPortrait | Yes (lifted, airy, peach skin) | none |
| 3 | Digicam direct flash (MEDIUM; report says #1, the evidence does not hold that up) | flashDigicam | Colour only. Flash is **lighting**: a bright frontal subject and a dark background that falls off fast. A LUT cannot make that; our vignette only imitates the falloff | none to the LUT; see §4 |
| 4 | Vivid memory: deep reds, yellow-greens, warm (MEDIUM-HIGH: #2 recipe; Tết) | vividFine | Mostly. Greens were neutral, not yellow-green. Grain was too fine for "vivid from a stock, not a slider" | **Changed:** greens −4° → −8° (toward yellow) ×1.05, 5500 → 5650 K, grain 0.15 → 0.22 |
| 5 | Cool faded 400: cool magenta-green shadows, lifted (MEDIUM) | everydayGreen (modelled on that 400, but today's tune turned it warm-muted) | **Conflict**: the report wants it cool and faded | Trial `trialCoolFade`. everydayGreen only faded a little (black 0.025 → 0.032, γ 1.06 → 1.0, density 0.05 → 0.03); its warm-muted direction (user brief §2.1) is kept until the user decides (§6) |
| 6 | Night neon: teal + red halation, light (MEDIUM) | tungstenGlow | Yes (teal day, red-orange halation, threshold 0.85) | none |
| 7 | Vivid daylight, the one clean vivid (MEDIUM) | none (vividFine is warm slide, dense, grainy) | gap | Trial `trialVividDay` |
| 8 | Grainy B&W (MEDIUM, real segment) | monoPunch (+ monoSoft) | Yes; we ship two B&W where the report has one | launch: keep one (§7) |
| 9 | Warm pushed moody (LOW-MEDIUM: one moody colour look is enough) | none (cinemaNegative is crimson/teal-sky; mutedChrome is calm-cool) | gap | Trial `trialWarmMoody` |
| 10 | Airy pastel (LOW: lasting niche, not the 2026 wave) | pastelCool | Yes, but our pastel is **cool-slate**. The gallery's airy wedding images (12, 13) are warm-cream and neutral, and that direction is closer to softPortrait | none; §6 asks whether pastel stays |
| — | (not in the report's 10) muted-warm chrome | mutedChrome | The #1 2026 recipe sits on this base, so the source check argues to **keep** it | none |
| — | (not in the report's 10) light cinematic | cinemaNegative | It is the "teal-orange only light" slot: split already halved today, colour separation by hue | none, but see §5 (closest pair in the set) |
| — | stronger "expired" warm fade | none | optional | Trial `trialWarmFade` |

## 3. Critique: where I agree and where I push back

Agree:
- **Faded, not denser, for the everyday warm look.** Today's tune made goldenDay / vividFine / everydayGreen /
  mutedChrome / cinemaNegative 3–6 % darker. For a slide-vivid look and a muted chrome that is in character. For the
  everyday warm look it pulls the wrong way: the report, the gallery (01, 12, 13: lifted, cream, low contrast) and the
  source check (mean Y within −2 %) all ask for soft and lifted. goldenDay has changed. everydayGreen moved half-way.
- **Vivid comes from hue separation + density + grain, not from saturation.** vividFine already worked this way
  (density 0.12, crimson L −7 %). The gallery's vivid images (06: red bus, deep blue, yellow-green grass; 07: dense
  saturated pastels with deep blacks) confirm yellow-greens and a little grain. Done.
- **Teal-orange only light, night only.** cinemaNegative's split was halved today and tungstenGlow is the night look.
  No new teal-orange. The neon references (14, 15: magenta/teal neon) are heavier than anything we should ship.
- **One coloured moody look is enough**, and it should be warm (pushed negative) rather than crushed. That is a gap.

Push back:
- **"Grain + lifted black on every preset except the clean vivid."** No. A slide-vivid look has deep blacks by nature
  (gallery 07 itself). Night looks with lifted blacks turn grey and milky under street light. A punchy B&W needs
  velvety blacks. The flash compact clips by design. Lifting everything also makes the set converge (§5) and pushes black
  p1 toward the research cap (+0.03 over base; above it shadows read "grey milky", which the role file lists as
  cheap). Lifted black belongs on the everyday/portrait/pastel/fade looks (6 of 10), not on all of them.
- **Direct flash is lighting, not colour.** The report's flash look ("bright subject, dark background that falls off
  fast, flat face, blown highlights") is made by a flash at 1–2 m. A LUT applied to an ambient-lit iPhone RAW cannot
  create it. flashDigicam gives the colour (hard contrast, clip, cool-green compact cast, strong vignette) and should be
  marketed as "compact digicam colour", not "flash". A real flash look needs the capture side (CaptureKit torch/flash)
  or a spatial relight plugin with the Vision person mask. That is outside the look stage and outside this task.
- **The report's digicam colour is "warm, slightly faded"; ours is cool-green.** Both exist (CCD cool-blue/green
  compacts vs warm disposable flash). I do not change flashDigicam without the user's choice, because a warm
  flashDigicam would converge with goldenDay/trialWarmFade.
- **Tết red/yellow is seasonal.** It argues for one warm vivid (vividFine), not a separate Tết look, and not for
  pushing reds further. Today's density already keeps reds deep instead of neon.
- **Airy pastel at "smallest slot"** is consistent with the evidence, but the warm-cream airy wedding style in the
  gallery is the common one. Our cool-slate pastelCool is the less common variant. Keep it only if the set needs a
  cool look besides trialCoolFade.
- **Brand-name stocks as preset names** (the report's list) cannot ship (AGENTS / research §3). Our names stay generic.

## 4. Changes to the 11 (names kept, summaries rewritten without trademarks)

Final values after three render rounds. Before = values from today's earlier tune (LOOK_TUNE_2026-11-10.md).

| Look | Before → after | Visual reason |
|---|---|---|
| goldenDay | black 0.025 → 0.038; contrast 1.06 → 0.96 around pivot 0.42 → 0.55; shoulder 0.85 → 0.87; saturation 1.04 → 1.0; highlightDesat 0.25 → 0.35; density 0.06 → 0.04; highlight tint b 0.010 → 0.008; red band L −3 % → −6 %; skin band chroma 0.78 → 0.72; green L −4 % → −2 %; sky L −5 % → −3 % | The report's #1 is warm and FADED. Lifted grey-brown blacks and soft contrast now read as a warm consumer print (gallery 01). Reds stay deep through band lightness instead of global density. The −6 % red L also fixes a 4.2× banding slope at saturated red near white, which the lower density had exposed. Skin band ×0.72 brings dark-skin chroma from ×1.21 back inside ±20 %. A slightly smaller cream highlight tint means a little less peach on overexposed white skies (IMG_1901) |
| everydayGreen | black 0.025 → 0.032; contrast 1.06 → 0.96 around pivot 0.55; shoulder 0.84 → 0.87; density 0.05 → 0.03; green L −5 % → −3 %; vignette 0.12 → 0.08 | Half-way toward faded. Its warm-muted colour stays until the user picks between it and trialCoolFade (§6). The vignette goes back to its earlier value because the corners cost about 1–1.5 % mean Y |
| vividFine | 5500 → 5650 K; greens shift −4° → −6°, ×1.0 → ×1.05; grain 0.15 → 0.22 (size 0.05 → 0.055) | "Vivid memory": yellow-greens (gallery 06) and stock-like grain. −8° was tried in rounds 1–2 and turned overcast grass mustard-olive (20250322_0735), so it went back to −6° |
| others | unchanged | softPortrait, pastelCool, tungstenGlow, mutedChrome, cinemaNegative, monoSoft, monoPunch and flashDigicam already sit where the report and gallery point, or the change belongs to the user (§6) |

## 5. Trial looks (`FilmLooks2026.trialLooks`; not listed in the app)

Registration: `FilmStock.named` falls back to `FilmLooks2026.trialStocks` (one line in `Look.swift`). The trials are
NOT in `FilmLooks2026.names`, `stocks` or `FilmStock.all`. The demo app's list, the 11-name count test and the built-in
stock count test do not change. `raw-bench looks --looks trialCoolFade,…` and `review.py render --looks …` resolve
them, and so does `--stock` validation in `RenderSettings`. Tests: every existing LUT check (neutral ramp/drift,
skin ±8°/±20 %, white/black/gamut, red gradation, banding ≤ 3×, 65³ interpolation) now runs on the 11 + trials. New
`testTrialLooksResolvableButNotListed`. New `testLooksDistinctFromNeighbours`: mean CIEDE2000 between looks on the 24
ColorChecker patches + 9 greys at shipped intensity; a trial must sit ≥ 2 from every look, and every look's nearest
neighbour is printed.

### trialCoolFade — cool faded 400 (report #5)
- Identity: overcast, street, film dump; cool, nostalgic, grainy. Counterweight to the warm looks.
- Tone: black 0.042 (grey, not black), contrast 0.9 around 0.45, shoulder 0.84 → white 0.965 (slightly grey whites).
- Colour: 5250 K, tint −2 (green); saturation 0.80, highlightDesat 0.3, shadowDesat 0.1, density 0.03. Shadows
  green-cyan (−0.012, −0.002) and highlights faintly magenta (+0.003, −0.002): the cool 400 crossover. Reds
  magenta-leaning (−6°, ×0.95). Skin band at 42° ×1.5 holds skin chroma inside the muted frame (without it,
  ColorChecker skins fell to ×0.70–0.75). Yellows muted toward lime (+4°, ×0.75). Greens toward emerald (+8°, ×0.9,
  L −2 %). Skies softened (235°, −4°, ×0.85, L +2 %). neutralDrift 0.035 (declared cool-green cast).
- Finish: grain 0.42 / 0.07, vignette 0.08. Intensity 0.85.
- Renders: on overcast (20250322_0735) and foliage (IMG_0106) it reads exactly as the report's cool faded 400. Its
  nearest neighbour is **pastelCool (ΔE 2.6 on the chart)**: on foliage the two look alike at feed size; pastelCool
  is brighter and rose, trialCoolFade greyer and green. Ship one of the two as the cool look, not both (§7).

### trialVividDay — the one clean vivid (report #7)
- Identity: travel daylight, landscape, festival. Clean, punchy, no fade, almost no grain.
- Tone: black 0.008, contrast 1.15, shoulder 0.88. Colour: neutral WB, saturation 1.28 with highlightDesat 0.5,
  density 0.05 (no neon). Skin band ×0.8 holds skin back from the global boost (net ≈ 1.0). Greens emerald
  (+3°, ×1.12), cyan ×1.12, skies deep (255°, −4°, ×1.15, L −5 %), reds ×1.0. Finish: grain 0.05. Intensity 0.9.
- Renders: on foliage and portrait it is clean emerald and blue, clearly cooler and cleaner than vividFine (warm, dense,
  yellow-greens, grain). **ΔE vs base only 1.7**: the iPhone base is already vivid, so this is close to a "true colour,
  a bit more" look. It also covers the source check's "cleanTrue" candidate. Nearest neighbour vividFine 2.8.

### trialWarmMoody — pushed warm moody (report #9)
- Identity: evening, rain, editorial; warm brown, deeper mids, lifted (not crushed) blacks, coarse grain.
- Tone: black 0.025, contrast 1.08 around 0.45, shoulder 0.82 → white 0.97. Colour: 5900 K, tint +1, saturation 0.82,
  highlightDesat 0.35, shadowDesat 0.2, density 0.06. Warm brown shadows (+0.004, +0.006), cream highlights
  (+0.003, +0.008). Greens olive-brown (−12°, ×0.65, L −4 %), yellows amber (−8°, ×0.85), skies muted (×0.7),
  reds L −3 %, skin band ×1.15. Finish: grain 0.5 / 0.085, halation 0.06, vignette 0.15.
- Renders: it looks good on night snow (DSC_0655) and the café (_DSC6752). On bright daylight (IMG_1901, HDR01)
  white walls go beige-grey, which is in character for a moody look but makes it the wrong pick for daylight.
  Mean Y −11.8 % vs base (round 1 was −12.1 % at contrast 1.12/pivot 0.48). It is the darkest colour look, by intent
  for one moody slot. Nearest neighbour mutedChrome 3.2.

### trialWarmFade — expired warm (optional, the stronger fade)
- Identity: "expired roll" film dump; strongly faded, yellow-cream, heavy grain.
- Tone: black 0.05, contrast 0.85 around 0.45, shoulder 0.8 → white 0.95. Colour: 6000 K, tint +1, saturation 0.8,
  highlightDesat 0.35, shadowDesat 0.15. Yellow-brown shadows (+0.003, +0.008), cream highlights (+0.002, +0.008).
  Greens −12° ×0.7, skies −8° ×0.7 L +3 %, reds +3° ×0.95. Skin band −3° ×1.18: the −3° hue correction keeps light
  skin within 8° under the warm cast (it was 8.3°). neutralDrift 0.04. Finish: grain 0.5 / 0.08, vignette 0.12.
- Renders: the monitor blacks in USER_mug turn grey-brown, which is the "grey not black" the report asks for. Black
  p1 rises up to +0.022 over base (cap 0.03). Next to goldenDay it is clearly flatter and less saturated (chart ΔE 3.5).
  Risk: on feed thumbnails it can read "milky". It is the look most likely to split opinion.

## 6. Open decisions for the user
1. **Cool 400 slot:** keep everydayGreen warm-muted (today's tune, brief §2.1), or move trialCoolFade's values into the
   name `everydayGreen`? The app and feedback.json key on that name, and the generic summary "everyday 400" fits
   both. My recommendation is to move them. The warm-muted version overlaps softPortrait (nearest pair on the chart,
   ΔE 2.6) and goldenDay.
2. **flashDigicam colour:** keep the cool-green CCD compact, or warm it toward the report's "warm, slightly faded
   flash"? A warm version would sit close to goldenDay and trialWarmFade. A real flash look needs capture-side flash
   or a relight plugin, not a LUT.
3. **One cool look or two:** pastelCool and trialCoolFade are close (chart ΔE 2.6, alike on foliage).
4. **trialWarmFade:** ship the strong "expired" fade, or keep goldenDay as the only warm fade?
5. **cinemaNegative vs mutedChrome:** the closest pair in the whole set (chart ΔE 1.95). Push them apart or drop one.
6. Names for promoted trials (generic, without the `trial` prefix), e.g. vividDay / warmMoody / expiredWarm.

## 7. Recommended 10-look launch set (from 11 + trials)
Weights from the report, corrected by the source check: warm faded and muted-warm first, slide-vivid second, cool 400
third, flash lower.

| # | Slot | Look |
|---|---|---|
| 1 | warm faded (lead) | goldenDay |
| 2 | soft skin portrait | softPortrait |
| 3 | muted-warm chrome (#1 recipe base) | mutedChrome |
| 4 | vivid memory / Tết | vividFine |
| 5 | cool faded 400 | trialCoolFade values under the name everydayGreen (decision 1) |
| 6 | night neon | tungstenGlow |
| 7 | the one clean vivid | trialVividDay (rename) |
| 8 | grainy B&W | monoPunch |
| 9 | warm pushed moody | trialWarmMoody (rename) |
| 10 | digicam colour | flashDigicam (lowest weight; swap for trialWarmFade if the user prefers a second fade) |

Out of the launch set: pastelCool (cool airy niche, overlaps trialCoolFade; the gallery's airy style is warm-cream,
and softPortrait covers it), monoSoft (second B&W), cinemaNegative (converges with mutedChrome; night teal is covered by
tungstenGlow). The split comes to 6 warm/faded/vivid + 1 cool + 3 dark/night/B&W, close to the report's 70/30.

## 8. Metrics, renders, what is unverified
`raw-bench looks`, 12 tuning files (originals ×5 + corpus 2024-08-20T124558543-iPhone12Pro, 20250322_0735, DSC_0655,
DSC_7895, IMG_0106, _DSC0140, _DSC6752; all `split: tuning`), 1200 px. Means over files, before (today's earlier tune,
08:33Z) → round 3 (09:44Z). dY = mean per-file meanY change vs base. p1Δ = max black p1 over base.

```
look            clip%       p1             ΔEbase      chroma      meanY         dY%    skin°max  p1Δmax
goldenDay       0.93→1.00   0.0209→0.0255  5.17→5.29   1.17→1.12   0.273→0.276   -5.8   2.0→2.9   0.0071
vividFine       0.00→0.01   0.0170→0.0170  2.63→2.78   0.98→0.97   0.278→0.278   -9.5   2.1→1.9   0.0003
everydayGreen   0.08→0.10   0.0214→0.0250  3.37→3.60   0.93→0.96   0.271→0.272   -6.8   1.6→1.5   0.0061
trialCoolFade   0.13        0.0293         4.29        0.87        0.280         -3.0   1.0       0.0155
trialVividDay   0.01        0.0190         1.69        1.09        0.299         -1.6   0.1       0.0004
trialWarmMoody  0.08        0.0199         4.93        0.81        0.262         -11.8  1.5       0.0011
trialWarmFade   0.06        0.0311         5.88        0.90        0.271         -3.7   2.6       0.0220
```
The other 8 looks are unchanged (identical numbers). No look adds clip over base. No black p1 goes past base + 0.03.
No skin hue above 8° on people (max 2.9°, tungstenGlow 6.2° declared).
**Mean Y target (source check: within about −2 % of the pre-tune level):** goldenDay 0.281 → 0.276 (−1.8 %, met).
everydayGreen 0.286 → 0.272 (−4.9 %, NOT met in round 3). Its vignette 0.12 → 0.08 was changed after round 3, and a
final render with that change was started but not measured. Why faded looks still darken bright files by 10–13 %
(IMG_1901, USER_mug, IMG_0106): the soft shoulder/white < 1 compresses the highlights the base renders near clip.
That is by design (no clip), and pivot/black barely move the linear mean.
Renders: `bench-out/look-review/` (the review server on 8777 reads its looks.json). Contact sheets per file were
checked for every file in round 1 and for the changed looks in rounds 2–3.
Holdout files: not rendered, not tuned.
Unverified: device display; real skin variety (one dark-skinned portrait, DSC_7895); ±1 EV; the user's taste
(feedback.json empty); whether the gallery targets hold on iPhone RAWs (gallery = film scans and edits).
**Test status (user said "stop before the test step"):** `swift test --filter FilmLooksTests` passed 10/10 after the
round-3 LUT edits. NOT run: the last edit (everydayGreen vignette 0.12 → 0.08, finish only, not part of the LUT) and
the final `swift test --filter "FilmLooksTests|Presets2026Tests|DevelopStagesTests"`, which includes the built-in stock
count that the `Look.swift` lookup change must keep.

## 9. Addendum: the user's Instagram scan (`docs/research/bao-cao-tong-hop-film-look-2026-11-10.md` §6)
99 posts from 2026, 794k likes. The query contained a portrait-negative stock name, so stock shares are biased toward
that family. Read as direction, not measurement. No values changed after this (no tests allowed at this point).
- **Feed taste is BRIGHT + WARM** (warm, soft, natural skin, sunny beach/summer), not dark. This strengthens §3: the
  everyday looks should sit at or above their pre-tune brightness. It supports undoing the remaining extra density/
  darkening, next on goldenDay (still −1.8 % vs pre-tune, darker than base on bright files) and on softPortrait if
  review agrees. Proposed next step, untested: goldenDay/everydayGreen white 0.985 → 0.99 and shoulder 0.87 → 0.9 so
  bright files lose less than the current 10–13 % mean Y. vividFine, mutedChrome and cinemaNegative can stay dense
  (not everyday looks).
- **Cool faded 400: 0 posts.** trialCoolFade is downgraded to LOW confidence. Decision 1 in §6 changes: do NOT move
  its values into everydayGreen yet. In §7, slot 5 becomes "pending", and the 10th look can go to a warm alternative
  (trialWarmFade, or a soft flash portrait below) unless TikTok/feedback data shows demand for a cool look.
- **Flash on IG = soft cinematic portrait flash** (golden-hour, soft); digicam party flash had 0 posts (it lives on
  TikTok). That points to a possible **soft "flash portrait" direction** that differs from flashDigicam: warm skin
  held bright (skin band L +, chroma ≈ 1.0–1.1), gentle shoulder (no declared clip), faint golden highlight tint,
  moderate vignette for falloff, fine grain. It is still colour only; the real flash look is lighting (§3).
  flashDigicam (hard, clipped, cool-green) stays the TikTok/party option, and its weight drops further.
- **Slide-vivid style: 1 post; grainy B&W: tiny; moody sells as a night preset, not as feed taste.** Keep vividFine
  for travel/Tết, but not as a lead. Keep one B&W (monoPunch). trialWarmMoody fits better as a night/evening preset
  than as a feed look; recommend it only if a moody slot is wanted.
- **Signal to track:** the comment/like ratio ("asking for the preset") beats likes. Use it, plus in-app usage of each
  look, after launch, instead of trend articles.
Revised launch lean: goldenDay, softPortrait, mutedChrome, vividFine, tungstenGlow, monoPunch, trialVividDay, and one
of {soft flash portrait (new trial, not built), trialWarmFade}, plus flashDigicam and one of {trialWarmMoody,
pastelCool}. Cool faded is pending evidence.

## 10. Roll consistency + goldenDay highlights (2026-11-10, later)
User rule: a look develops a whole roll (24/36 frames), so its effect should be as uniform as possible across frames
of different brightness; per-frame change only from context/objects. New benchmark: `review.py roll [--against <looks.json>]`
over the 12 tuning files (dY = % mean linear Y vs base; slope = % per +0.1 base mean Y, negative = bright frames darkened more).
User decisions already applied: no flash-portrait look; cinemaNegative → `FilmLooks2026.retiredLooks`; trials renamed
trialVividDay → brightTravel, trialWarmFade → sunFade, trialWarmMoody → warmEvening (trialCoolFade unchanged).

**Diagnosis (goldenDay).** Raising only the shoulder/white (0.87/0.985 → 0.9/0.99) moved dY_min −12.57 → −12.40:
the top of the curve was not the main cause. Measured split of the darkening on bright frames: the 0.1 vignette ≈ −7 %
on every frame (vignette 0 → dY_mean +8.0, but white clipping +3.8 % — the vignette was what kept warm whites under 0.98);
density 0.04 + green band L −2 % + blue band L −3 % ≈ −5…−7 % on bright foliage/sky (IMG_0106); the toe lift
(black 0.038, contrast 0.96 below pivot) makes dark frames brighter (+5.8 %), which is the slope.
A pure-Python model of `LookSpec.apply` on the base JPEGs (scratch, not committed) predicted dY per file within ≈ 1 %
of the renders and was used to search values; every candidate was then rendered.

| goldenDay value | before | after |
|---|---|---|
| black / contrast / pivot | 0.038 / 0.96 / 0.55 | 0.034 / 1.0 / 0.55 |
| shoulder / white | 0.87 / 0.985 (default) | 0.88 / 0.99 |
| density | 0.04 | 0.03 |
| band 140 (green) lightness / band 255 (blue) lightness | −0.02 / −0.03 | 0 / −0.02 |
| highlightTint (a, b) | (0.003, 0.008) | (0.003, 0.007) |
| halationThreshold / vignette | 0.8 / 0.1 | 0.9 / 0.04 |
Unchanged: 6200 K / tint 1, saturation, highlightDesat 0.35, red band (L −6 %), skin band ×0.72, yellow band ×1.2,
olive shift −10°, shadow tint, grain 0.4, halation amount 0.1, intensity 0.85.

| roll metric (12 tuning files) | baseline | after | target |
|---|---|---|---|
| dY_mean % | −5.79 | −1.45 | — |
| dY_min % (IMG_1901, was IMG_0106) | −12.57 | −6.72 | ≥ −7 ✓ |
| dY_max % (_DSC0140, darkest) | +5.77 | +6.86 | — |
| dY_spread | 18.34 | 13.58 | lower ✓ |
| dY_slope | −2.20 | −1.70 | \|·\| lower ✓ |
| chroma_spread | 1.026 | 0.985 | not higher ✓ |
| clip_rise_max | 0.000 | 0.000 | 0 ✓ |
| p1_rise_max | 0.007 | 0.005 | not higher ✓ |
| dE_mean (vs base) | 5.30 | 4.82 | ±1 ✓ |
| skin hue shift on people (mooncake / DSC_7895 / _DSC0140) | −0.39 / +1.58 / −2.90° | −0.34 / +1.51 / −2.64° | ≤ old + 0.5 ✓ |
Rejected on the way: density 0.02 + blue L −0.01 (slope worse −2.32, clip +0.009); shoulder 0.92 / white 1.0 with
halation threshold 0.8–0.85 (clip +0.23…+0.55 on HDR01/mooncake: warm white R sits at the 0.99 cube ceiling, halation
and grain push it over 0.98 linear). Halation threshold 0.9 keeps the glow on real highlights only.
Every other look: `roll --against` Δ = 0.000 in all columns, and per-row metrics bit-identical (renamed trials compared
by value against their old names). Distinctness (chart ΔE00): goldenDay nearest warmEvening 3.41 → 3.17, sunFade
3.46 → 3.57 — slightly closer to warmEvening, still well apart.
Seen: before/after JPEGs IMG_1901 (brightest: sky and concrete lighter, less grey-dingy, still cream-warm; corners
no longer dark), _DSC0140 (darkest: practically unchanged, skin same), IMG_0106 (foliage lighter, still olive/faded).
Note: IMG_1901 look clip 6.3 % → 9.0 % (base 45 %): fewer whites pulled down, not new clipping vs base.
Unverified: device display; holdout files not rendered; real skin variety; whether the lighter vignette is missed on
the feed (user review). Next (not done): the same treatment for everydayGreen (dY_min −10.7, slope −2.36).

## 11. Roll consistency: everydayGreen (2026-11-10, later)
Same cause as goldenDay (§10): vignette 0.08 (≈ −5.6 % on every frame), the 0.98 white ceiling on the brightest frame
(IMG_1901, 45 % clipped in base), green band lightness −3 % on foliage (IMG_0106), and the toe (contrast 0.96 below
pivot 0.55) brightening dark frames (the slope). Searched with the §10 Python model, then rendered.

| everydayGreen value | before | after |
|---|---|---|
| black / contrast / pivot | 0.032 / 0.96 / 0.55 | 0.03 / 1.0 / 0.55 |
| shoulder / white | 0.87 / 0.98 | 0.88 / 0.99 |
| highlightDesat | 0.3 | 0.36 (holds chroma_spread: HDR01 chroma ratio rose with the higher white) |
| band 140 (green) lightness | −0.03 | −0.015 |
| vignette | 0.08 | 0.04 |
Unchanged: 5650 K / tint −2, saturation 0.92, density 0.03, shadow tint (−0.008, 0.003) green shadows, highlight tint
(0.002, 0.006) cream, red shift −6°, yellow/skin band, green band shift +5° ×1.05, cyan band ×0.85, grain 0.45/0.075, intensity 0.85.

| roll metric (12 tuning files) | baseline-2 | after | target |
|---|---|---|---|
| dY_mean % | −3.90 | −1.13 | — |
| dY_min % (IMG_1901) | −10.68 | −6.59 | ≥ −7 ✓ |
| dY_max % (_DSC0140) | +5.97 | +5.94 | — |
| dY_spread | 16.65 | 12.54 | lower ✓ |
| dY_slope | −2.36 | −1.67 | \|·\| lower ✓ |
| chroma_spread | 0.287 | 0.280 | ≤ 0.29, not higher ✓ |
| clip_rise_max | 0.000 | 0.000 | 0 ✓ |
| p1_rise_max | 0.008 | 0.005 | not higher ✓ |
| dE_mean (vs base) | 3.44 | 3.19 | ±1 ✓ |
| skin hue shift (mooncake / DSC_7895 / _DSC0140) | −0.53 / +1.49 / +0.06° | −0.41 / +1.53 / +0.21° | ≤ old + 0.5 ✓ |
| distinct (chart ΔE00, nearest) | softPortrait 2.56 | softPortrait 2.69 | ≥ 2 ✓ |
Rejected: black 0.028 (spread 11.94, slope −1.56, but chroma_spread 0.299 > 0.29); cyan band ×0.86 (chroma_spread 0.288).
Every other look: `roll --against` baseline-2 Δ 0.000 in every column, and all 192 other rows bit-identical
(meanY, clip, p1, chroma ratio, ΔE, skin hue).
Seen (before/after, 1200 px): IMG_1901 slightly lighter, corners no longer dim, still cream/faded; IMG_0106 foliage a
touch lighter, still muted emerald with green-grey shadows; _DSC0140 practically unchanged, skin same.
Unverified: device display; holdout files not rendered; real skin variety; whether the lighter vignette is missed.
