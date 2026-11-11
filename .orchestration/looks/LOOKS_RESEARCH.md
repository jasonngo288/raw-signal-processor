# Looks research (2026-11-09)

Question: the film looks of RawCore will replace MoodRoll's looks. What is best practice, what do people want, what can we legally ship, and which starter set should we build.

Read first: AGENTS.md, docs/ROADMAP.md, docs/PRESETS_2026.md, hdr-tone-mapping SKILL, Look.swift, LogLook.swift, Presets2026.swift, FilmFinisher.swift. I did not read Renderer.swift or Developer.swift, so claims about stage order there are marked "verify".

Confidence: H = primary or repeated source, M = one decent source or standard knowledge, L = vendor claim, forum, or my inference. "MEASURE" = needs raw-bench evidence before it counts (AGENTS rule 5).

Web search quality was poor for popularity data. Most sources are vendor blogs and preset shops. Treat section 2 as weak evidence; it says so per claim.

---

## 1. Best practice for film emulation in a RAW pipeline

### 1.1 Where looks sit
- Film-emulation tools in video model a chain: scene-referred input, negative, then print stage (2383 or paper), then display. Dehancer exposes this as "Print: Linear / Cineon Film Log / Kodak 2383 / Kodak Endura paper", and its negative profiles have the paper characteristics measured and removed so they can be re-printed. [Dehancer blog](https://blog.dehancer.com/articles/print-film-profiles-in-dehancer/) (M, vendor claim, not independently verified).
- Print-film-emulation (PFE) LUTs such as 2383 are usually built for Cineon-style log input. Several colorists report that, and that PFE LUTs are a last stage or a monitoring step. [ACES Central](https://community.acescentral.com/t/how-can-i-use-kodak-2383-lut-in-the-aces-workflow/3474), [Lowepost](https://lowepost.com/insider/insights/print-film-emulation-workflow-r76/page/2/) (M, forum and practitioner).
- Consequence for this repo (my inference, L): our base is Apple's display-referred render, and Apple's tone is already applied. A true negative + print model needs the scene-linear path (`LogLook`: linear, then log, then LUT; +1 full decode per finish). That is costly on device and Apple's tone is switched off on that path, so highlights and shadows look different from the base the user sees.
- Recommendation:
  - **Default = display-referred 33³ looks** on the Apple base, generated in code. These are "single creative LUT" looks, but built from a negative+print-like analytic model (per-channel toe/shoulder, hue-dependent saturation, highlight desaturation) so they are physically plausible and re-derivable.
  - **Log/scene path only for looks whose character depends on the highlight range** (tungsten night with halation, "Cinematic Ice Blue", an optional print-stock look).
  - Do not ship a full spectral negative+print model in v1. Revisit if the scene-linear decode gets cheap on device.
- MEASURE: render the same file through the display path and the log path with the same intended look. Compare highlight clip fraction, black p1, and time per frame on device.

### 1.2 LUT size and interpolation
- A SMPTE study found tetrahedral interpolation more accurate than trilinear. For 10-bit SDR, grids above 41³ (trilinear) or 31³ (tetrahedral) give unnoticeable error. For 12-bit HDR the thresholds are 72³ and 55³. [SMPTE Motion Imaging Journal](https://journal.smpte.org/periodicals/SMPTE%20Motion%20Imaging%20Journal/129/2/17/) (H for the thresholds, M for applying them to photos).
- So 33³ with trilinear is borderline for 10-bit output and fine for smooth looks. Our export is 10-bit HEIC, so the case that matters is gradients (skies, skin) with strong curves.
- A film-simulation author who checked interpolation error concluded 33³ is sufficient for his LUTs. [pixls.us thread](https://discuss.pixls.us/t/spektrafilm-luts/57879) (L, anecdote).
- Core Image: Apple's docs list `cubeData` (float RGBA, red fastest), `cubeDimension`, `colorSpace`, and an `extrapolate` flag for values outside 0...1. [Apple docs](https://developer.apple.com/documentation/coreimage/cicolorcubewithcolorspace.md). They do not state the interpolation method (not found). GPU 3D texture sampling is normally trilinear, but that is my assumption (L). Tetrahedral is not available in the built-in filter.
- Facts about our code (read in Look.swift): `CubeLUT.generate` clamps outputs to 0...1, and the CPU reference `apply` is trilinear. So the cube cannot output values above 1, and the CPU reference matches the likely GPU behaviour. Verify in `Renderer.applyLook` whether `extrapolate` is set, because the base is in extended linear P3 and values above 1 would otherwise clip before the look.
- Recommendation: 33³ for smooth built-ins. 65³ for any cube with steep features (log composite already uses 65). Do not move to a custom tetrahedral kernel unless the measurement below fails.
- MEASURE (a): max and mean ΔE00 between the 33³ cube and the analytic function it was sampled from, on a dense random grid and on the gradient test ramps. Proposed bound: mean < 0.1, p99.9 < 0.5.
- MEASURE (b): CIColorCube output vs the Swift trilinear `apply` on the same pixels (this settles what Core Image does).
- MEASURE (c): 10-bit HEIC grey and skin gradient: count of distinct code values, no banding steps.

### 1.3 Shaper / 1D pre-LUT
- A shaper matters when the cube input is linear (resolution is spent in the highlights). Our display path uses encoded Display P3 input, which already spaces nodes perceptually, so no shaper is needed (M, standard colour-management knowledge).
- The log path uses the log curve as its shaper (LogLook). Headroom 4 (2 stops above diffuse white) is a decision to validate: MEASURE how much of a sunny-day frame lies above 4x diffuse white, and what clips.

### 1.4 Gamut mapping
- Our `Preset26` pulls out-of-gamut colour toward luma. LogLook clamps then re-expresses Rec.709 output as P3, with no soft clip (read in code).
- The spektrafilm thread discusses soft gamut compression before the film model (radial Reinhard knee in xy; per-LUT cost: Oklch 30 ms, Jzazbz 40 ms, CAM16UCS 70 ms, ACES RGC-style 4 ms). The author says hard clipping gave red artefacts in one test. [pixls.us](https://discuss.pixls.us/t/spektrafilm-luts/57879) (L).
- Recommendation: soft compression of out-of-gamut colour toward the neutral axis in every generated look (done offline when generating the LUT, so runtime cost is zero).
- MEASURE: fraction of pixels where any channel is clamped after the look (proposed < 0.1 % on the 10 originals), and saturated red/blue patch detail (no flat patches).

### 1.5 Highlight roll-off, highlight desaturation, black and white points
- Film shoulders compress highlights and lose saturation toward white. `BuiltInLook.film` does this (tanh shoulder + `highlightDesat`). `Preset26` caps whites at 0.985 (output ceiling 0.99).
- A film look must not hide that the base already has Apple's tone. Looks should be gentle in the shoulder because Apple's render already has a shoulder (my inference, L).
- Black point: a lifted toe is a signature of several looks (soft negative, digicam). It conflicts with Gate 2's "black p1 not raised > +0.002", which was written for the base render without a look. The gate for looks needs its own rule: black p1 may rise by at most the look's declared toe.
- Paper white: ceiling 0.985-0.99 makes pure white a light grey. Decide per look; "lowest ceiling" is a style choice, not a quality property.
- MEASURE: black p1, white p99.9, clip fraction (>= 0.99), vs `appleDefault`, per look.

### 1.6 Intensity
- Blend of look and identity in encoded space, default 60 % for `Preset26` (spec). `DecisionEngine` changes it by -0.15...+0.10 and logs it. Fine.
- Add checks: intensity 0 equals the base (ΔE00 mean < 0.1), and the look strength rises monotonically with intensity (ΔE00 to base).

### 1.7 How products structure looks (public information only)
- Dehancer: negative and print profiles separate, print stage choosable, grain and halation separate tools; grain is procedural, not scanned overlays. [Mixing Light](https://mixinglight.com/color-grading-tutorials/dehancer-film-print-emulation-review-part-1), [Digital Production](https://digitalproduction.com/2026/07/22/dehancer-brings-film-dirt-to-scratch/) (M, reviews). No public white paper on the algorithms (confirmed by search, H that it is missing).
- Fujifilm film simulations: a base simulation plus separate sliders: grain (strength, size), Color Chrome Effect and Color Chrome FX Blue, highlight tone, shadow tone, colour, DR. Official example for Classic Chrome: grain weak/small, Color Chrome strong, Color Chrome Blue strong, tone curve 0. [Fujifilm X](https://www.fujifilm-x.com/en-us/stories/classic-chrome-fs-recipe-x-eric-bouvet/) (H for the official recipe; community recipes are M). Fuji changed how blue renders on Classic Chrome / Classic Neg between sensor generations, so a look is calibrated per pipeline.
- Apple Photographic Styles (iPhone 16): tone and colour on a 2D pad plus a palette/intensity slider, named styles (undertones Standard, Cool Rose, Neutral, Rose Gold, Gold, Amber; moods such as Cozy, Quiet, Dramatic). [PetaPixel](https://petapixel.com/2024/10/24/how-apples-next-gen-photographic-styles-transform-iphone-photography), [MacRumors](https://macrumors.com/guide/iphone-16-photographic-styles) (M; sources disagree on the exact meaning of "palette"). Useful as a naming model: generic, mood-based names.
- Takeaway (L, my inference): the structure "look (tone + colour) | grain | halation | vignette | intensity" in this repo matches how the products separate things.

### 1.8 Grain, halation, bloom
- Grain: procedural, not overlay scans (Dehancer). Size as % of the short edge, so a preview and a full-res export look the same at the same viewing size: our `FilmFinish` already does this and the repo says it was verified resolution-independent. Amplitude should fade toward white (done: w = 1 - 0.8Y), and sit in the toe/mid-tones.
- Halation: red-orange glow from scattered light reaching the film base. Dehancer notes it appears on film without an anti-halation layer and not only around light sources. [Dehancer](https://blog.dehancer.com/2021/03/29/halation-effect-what-is-it-and-why-is-it-important-for-the-film-emulation/) (L; the page has no radius/threshold data). The skill file (Mantiuk lecture) says: apply glare to very bright pixels only, blur in linear light.
- Facts about our code: `FilmFinisher.halation` thresholds on luma of the image it receives and blurs it. The roadmap order is look, skin protection, finish, so the finisher likely runs on the display-encoded image (verify in `Developer`/`Renderer`). That contradicts "blur in linear light". MEASURE: render a clipped light source with halation in the encoded domain vs linear domain; compare glow radius and colour. Decide before adding more halation looks.
- Grain MEASURE: grain std per luminance zone at 1024 px vs 3024 px export at equal viewing size (proposed within 10 %); mean luminance shift < 0.002; no stuck black dots (the repo already had that bug once).

---

## 2. What people want (popularity)

Evidence is weak. There is no public app-store ranking for looks. What exists:

| Evidence | Finding | Confidence |
|---|---|---|
| Darkroom "most exported" presets, 12-month window, page 1 | Top 10 (exports): Q3 Reluxe 8,500; Film 3,099; Kodak gold 200 v3 2,389; Dose Of Cute 2,275; Leica BW HC 1,175; Sunny Soccer 1,069; Fuji-2 888; Kodak Gold 707; TPL GOAT 615; B1 560. [Darkroom](https://darkroom.co/presets/collections/most-exported) | M (real counts, but one app, user-made presets, includes brand names) |
| Preset shop claims "Portra 400 is the top preset of 2025" | Self-promotion. A search snippet gave about 6,600 exports for a Portra 400 preset on Darkroom, which I could not reproduce on the page I fetched | L |
| Film Log survey: 293 photographers, 850+ rolls, published 2025-12-02 | CineStill 800T is #3; CineStill 400D #10; Kodak Pro Image 100 #9, ColorPlus #8, UltraMax #7. Ranks 1-2 and 4-6 behind a paywall. [Analog.Cafe](https://www.analog.cafe/r/top-10-film-stocks-according-to-293-photographers-wlzp) | M for the visible ranks. It measures film shooters, not preset users |
| VSCO relaunched its film presets in 2026 (stocks named: Portra 160/400/800, three Ektar renditions, HP5+, Tri-X, Acros, Gold 200, Superia, Neopan 1600), about $59. [Pellica blog](https://pellica.app/blog/vsco-film-presets-comeback-2026/) | Shows what a major vendor believes sells. The page is from a small unverified site | L |
| "Digicam" trend: Google Trends data cited by the Hindustan Times (July 2025) shows rising searches from mid-2024. [HT via Magzter](https://www.magzter.com/de/stories/newspaper/Hindustan-Times-Noida/DIGICAM-DIARIES-WHY-BLURRY-PAP-SHOTS-OF-2007-ARE-BACK). Apps in the niche: Dazz, Huji, Gudak, LoFi Cam, Y2K Cam | The trend is real as search interest; I found no current download numbers | M for the trend, L for any app ranking |
| Discontinuation | Fujifilm Pro 400H and Superia X-Tra remain discontinued (Fujifilm, PetaPixel 2025-06). [PetaPixel](https://petapixel.com/2025/06/30/fujifilm-says-beloved-400h-and-superia-films-remain-discontinued). Nostalgia for gone stocks is an argument for those looks | H |

Not found: Sensor Tower / Appfigures data, "cinematic teal-orange" demand numbers, Classic Chrome / Classic Neg popularity outside Fujifilm circles. To close this gap the owner needs a store-analytics tool. I did not verify any of the three.

Defining traits. These are from general film-photography knowledge plus the sources above, NOT measured by me. They are design targets to be calibrated on reference scans or chart data (L). Numbers are proposals.

| Look family | Traits in measurable words |
|---|---|
| Portra-like soft portrait negative | Low-moderate contrast, toe lifted (black ~0.02-0.03 encoded), soft shoulder; saturation 0.9-1.0 overall, skin hue slightly toward orange-peach (hue shift <= +5 deg), greens slightly yellow and muted, blues slightly teal; fine grain; no halation |
| Gold 200-like warm consumer | Warm white balance shift (+300-400 K look), yellows/reds boosted (+10-15 % chroma), greens toward yellow, blues desaturated, mid contrast, visible grain |
| Ektar-like vivid | Contrast 1.1, saturation 1.15-1.25, deep blues and reds, fine grain, near-neutral white balance |
| 400H-like pastel cool | Low contrast, lifted shadows, greens shifted cyan, skin slightly pink/magenta, overall sat 0.85-0.95, airy highlights |
| Superia-like everyday 400 | Slight green cast in shadows, magenta-leaning reds, medium contrast, medium-strong grain |
| CineStill 800T-like tungsten | Cool/teal shadows and midtones in daylight, warm lights neutralised, red-orange halation around highlights (strong), medium grain, high-ISO feel |
| Classic Chrome / Classic Neg style | Muted saturation (0.8-0.9), blues deepened and slightly desaturated, shadows teal-leaning (Classic Neg) with higher shadow contrast, warm highlights, weak small grain (Fujifilm's own recipe) |
| HP5 / Tri-X black and white | Luminance only (r = g = b), channel weights act like a filter (red/orange filter option darkens skies), S-curve; HP5 soft, Tri-X punchy; strong grain |
| Digicam / Y2K | High contrast with hard highlight clip, flash-lit look (bright centre, dark falloff = vignette), cool-green cast, slightly blown whites, visible chroma noise, sharp edges |
| Cinematic teal-orange | Teal in shadows/blues, orange in skin/highlights, contrast up; needs skin protection so skin hue stays bounded |

---

## 3. Licensing and naming

Not legal advice. Items marked "not checked" I did not fetch.

- **Film brand names are trademarks, and they are moving.** Kodak announced in March 2026 that Portra is renamed Ektacolor Pro and T-Max is renamed Ektapan, because Kodak Alaris held the old names and Eastman Kodak chose to drop rather than buy them back. [Fujifilm X Weekly](https://fujixweekly.com/2026/03/26/kodak-renames-portra-and-t-max/) (H). Fujifilm product names like Velvia, Classic Chrome, Superia are Fuji marks (M, standard knowledge). CineStill is a brand of a third party (M).
- **Nominative use** (US doctrine) lets you name a product to refer to it, if you do not suggest sponsorship. [Wikipedia](https://Www.wikipedia.org/wiki/Nominative_use) (M). I found no case about film presets and nothing on how VSCO or RNI handle it. Preset shops (Gumroad, Sellfy, VSCO's own page) use "Portra" and "Tri-X" openly with no notice; that tells us risk is tolerated in the market, not that it is legal (M).
- **App Store**: Apple's review guidelines (section 5.2, intellectual property) forbid using protected third-party material such as trademarks without permission (from memory, not checked). A name in the listing or the picker is the visible risk.
- **Repo rule already in place**: no brand names in display names (PRESETS_2026 open question 2 shows the checklist forbids even "Fuji Soft 400"). Keep it. A neutral descriptor in internal docs/specIds is fine; do not put brands in strings the user can see, in App Store metadata, or in screenshots.
- **Licence of look sources.**
  - CC0: no attribution, safe to bundle (a CC0 film LUT republished on KDE Store). [KDE Store](https://store.kde.org/p/1484461) (M)
  - MIT (G'MIC film LUTs): bundle allowed, copyright notice must ship in the app. [Film-Luts repo mirror](https://gh.r-mj.com/lucasbuick/Film-Luts) (M, not checked at source)
  - CC BY: attribution screen needed.
  - CC BY-SA / GPL (spektrafilm profiles are GPL; the author leaned to CC BY-SA 4.0 for LUTs): share-alike and GPL obligations are uncertain for a closed app; avoid unless counsel clears it. [pixls.us](https://discuss.pixls.us/t/spektrafilm-luts/57879) (M).
  - Commercial packs from Gumroad and similar: usually "commercial use of the output, no redistribution or resale" or "redistribution prohibited". Bundling in an app is redistribution. Do not use. [example listing](https://ahphotographypro.gumroad.com/l/CinematicFilmLUTs) (M)
  - Free sites ("free for commercial use") often do not say anything about redistribution: not enough.
- **Recommendation**: keep the existing policy: parametric looks written in code by the project (no third-party LUT assets). Only import a LUT if the licence text explicitly allows redistribution inside an app (CC0 or a written commercial licence), and record it in WORK_LOG. The user's own `.cube` files (e.g. Cinematic Ice Blue) need the user's confirmation that they own or have the right to ship them.
- **How competitors name looks (what I could verify)**: Apple uses mood and undertone names; Fujifilm uses its own marks (Classic Chrome) and its simulations are named for its own products; VSCO uses the real stock names; Darkroom user presets are named freely (e.g. "Kodak gold 200 v3"). Safe naming pattern for us: descriptive, generic words (Soft Portrait, Golden Day) plus an internal code. Do not copy VSCO's approach.

---

## 4. Recommendation for this repo

### 4.1 Rules for every look (all proposed, to be confirmed by raw-bench on the 10 originals + corpus)
1. Names generic (test in `Presets2026Tests` style: no brand strings).
2. Generated in code; 33³ display unless stated; one `FilmStock` per look with its own `FilmFinish`.
3. Neutral ramp (r=g=b input, 33 steps) output strictly non-decreasing in luma. Neutral chroma bound: ΔC*ab <= 3 for "neutral" looks, <= 8 for declared split-tone looks.
4. Skin: ColorChecker patches 1-2 (dark/light skin) plus a skin mask on people: hue-angle shift in Lab <= +/-8 deg, chroma change within +/-20 %, with `skinProtect` on for the look. Cinematic looks use `minSkinProtection` 0.5.
5. Highlight clip fraction (>= 0.99 encoded) not above `appleDefault` (exception: digicam, declared). White p99.9 reported.
6. Black p1 <= `appleDefault` + the look's declared toe (max 0.03). Gate 2's +0.002 stays for the base without a look.
7. Out-of-gamut clamp fraction < 0.1 %.
8. Intensity 0 = base (ΔE00 mean < 0.1); ΔE00 to base rises monotonically with intensity.
9. 33³ vs analytic function error: mean < 0.1, p99.9 < 0.5 ΔE00.
10. Cross-model: the same chart through the look on two models still ΔE00 < 2 between models (gate 3 after the look), so looks do not widen the model spread. Needs the ColorChecker shots.
11. Grain resolution-independent (std within 10 % between 1024 px and full at equal viewing size). Halation present only on looks that declare it, bounded halo ring (+0.01 rule from Gate 2 does not apply to halation looks; use a per-look bound).
12. Each look listed in the recipe (stock name, version, intensity, finish) per hard rule 1.

### 4.2 Starter set (11 display-referred + 1 existing log look)
Order is my guess at demand (L); reorder after store analytics.

| # | Generic name (proposal) | Inspired by (internal only) | Space | Key traits to hit | Extra acceptance |
|---|---|---|---|---|---|
| 1 | Soft Portrait | Portra 400 | display 33³ | toe 0.025, contrast 0.92, sat 0.95, skin toward peach, fine grain 0.25 | skin hue shift <= +5 deg; clip fraction not raised |
| 2 | Golden Day | Gold 200 | display 33³ | warm +, reds/yellows +12 %, blues -10 %, grain 0.35 | neutral ramp warm tint bound <= 8 ΔC*ab |
| 3 | Vivid Fine | Ektar 100 | display 33³ | contrast 1.1, sat 1.2, fine grain 0.15 | red/blue patches not flat-clamped |
| 4 | Pastel Cool | Pro 400H | display 33³ | toe 0.03, contrast 0.88, greens toward cyan, sat 0.9 | skin shift <= +/-8 deg |
| 5 | Everyday Green | Superia 400 | display 33³ | slight green shadows, magenta-leaning reds, grain 0.4 | shadow tint bound <= 6 ΔC*ab |
| 6 | Tungsten Night | CineStill 800T | display 33³ + strong halation (linear light, verify) | teal shadows, warm lights neutral, halation 0.5, grain 0.35 | halo ring bound; no clipped-sky colour cast |
| 7 | Muted Chrome | Classic Chrome | display 33³ | sat 0.85, blue deepened, contrast up in shadows, grain weak/small | skin shift <= +/-8 deg |
| 8 | Cinema Negative | Classic Neg | display 33³ | teal shadows, warm highlights, contrast 1.05, sat reds up | skin protection >= 0.5 |
| 9 | Mono Soft | HP5 | display 33³ | r=g=b exactly, S-curve gentle, toe 0.02, grain 0.5 | `isMonochrome` true; monotone |
| 10 | Mono Punch | Tri-X | display 33³ | r=g=b, contrast 1.2, grain 0.6, red/orange filter option | same |
| 11 | Flash Digicam | CCD/Y2K | display 33³ + vignette 0.25 | hard highlight clip, cool-green cast, contrast 1.15, chroma noise optional | declared exception to clip rule; skin shift <= +/-10 deg |
| 12 | Ice Blue Cinema (exists) | user's own cube | log 65³ (existing `logLook`) | muted grade, highlights kept | clip fraction vs display-path version (MEASURE) |

Why mostly display-referred: the base is Apple's tone-mapped render and the log path costs one extra full decode per finish. Keep `logLook` for 6 only if halation in linear light proves worth the cost (see 1.8 measurement), and for look 12.

What to drop or merge from the current 7 `PRESET_26_*`: they stay as provisional until a designer locks curves. They are a subset of this set (CPM35 = 11, Portrait160 = 1, Soft400 = 4, Chrome64 = a slide look not in the table, Golden R = 2, Palm Springs and Social Pop = cinematic 8). The decision on which are product looks belongs to the owner.

### 4.3 Order of work (my proposal)
1. Write the measurement harness first (LUT error vs analytic, CIColorCube vs Swift trilinear, neutral-ramp and skin checks, banding count). No new look counts until these run in `raw-bench bench`.
2. Fix/verify stage order for halation (linear light) and the `extrapolate` flag.
3. Build looks 1, 4, 7, 9 first (cover the most distinct traits: warm negative, pastel, muted, mono), then the rest.
4. Collect store analytics (Sensor Tower or Appfigures) before locking the order.

### 4.4 Open questions for the owner
- Are internal brand-based `specId`s acceptable in the repo (they are not user-visible)?
- Which `.cube` files besides Ice Blue exist, and who holds their licence?
- Is a print-film look (2383-style) wanted? It needs the log path and a licence-free implementation (own curves, not a downloaded LUT).
- Per-look black p1 and clip rules above are proposals; the owner decides what "never worse than Apple" means once a look is on.

## Sources
- https://blog.dehancer.com/articles/print-film-profiles-in-dehancer/
- https://community.acescentral.com/t/how-can-i-use-kodak-2383-lut-in-the-aces-workflow/3474
- https://lowepost.com/insider/insights/print-film-emulation-workflow-r76/page/2/
- https://journal.smpte.org/periodicals/SMPTE%20Motion%20Imaging%20Journal/129/2/17/
- https://developer.apple.com/documentation/coreimage/cicolorcubewithcolorspace.md
- https://discuss.pixls.us/t/spektrafilm-luts/57879
- https://www.fujifilm-x.com/en-us/stories/classic-chrome-fs-recipe-x-eric-bouvet/
- https://petapixel.com/2024/10/24/how-apples-next-gen-photographic-styles-transform-iphone-photography
- https://macrumors.com/guide/iphone-16-photographic-styles
- https://mixinglight.com/color-grading-tutorials/dehancer-film-print-emulation-review-part-1
- https://digitalproduction.com/2026/07/22/dehancer-brings-film-dirt-to-scratch/
- https://blog.dehancer.com/2021/03/29/halation-effect-what-is-it-and-why-is-it-important-for-the-film-emulation/
- https://darkroom.co/presets/collections/most-exported
- https://www.analog.cafe/r/top-10-film-stocks-according-to-293-photographers-wlzp
- https://pellica.app/blog/vsco-film-presets-comeback-2026/
- https://www.magzter.com/de/stories/newspaper/Hindustan-Times-Noida/DIGICAM-DIARIES-WHY-BLURRY-PAP-SHOTS-OF-2007-ARE-BACK
- https://petapixel.com/2025/06/30/fujifilm-says-beloved-400h-and-superia-films-remain-discontinued
- https://fujixweekly.com/2026/03/26/kodak-renames-portra-and-t-max/
- https://Www.wikipedia.org/wiki/Nominative_use
- https://store.kde.org/p/1484461
- https://ahphotographypro.gumroad.com/l/CinematicFilmLUTs

## Orchestrator review against the code (2026-11-09)
- **Halation order — no change needed.** `Developer.finish` runs look → skin protection → `FilmFinisher.apply` (halation, then grain). Core Image filters run in the context's working space (extended linear Display P3, `Renderer`), so the halation threshold and blur already operate on linear light, even after a display-referred LUT (CIColorCubeWithColorSpace converts to encoded P3 for the lookup and back).
- **Gate 2 — no conflict.** Gates 2 / 2-core are computed on `auto` and `auto core` (no look). Look variants (e.g. `auto+warm400`) are reported, never gated. Looks therefore need their own acceptance checks (section 4 above), not a change to Gate 2.
- **`extrapolate`** is not set in `Renderer.applyLook`; inputs above 1 clamp at the cube edge. Fine for the SDR base; only relevant if a look ever runs on EDR values.
- **Kodak rename (March 2026)** comes from one source (Fuji X Weekly); not re-checked here. It does not change anything: display names stay generic either way.
