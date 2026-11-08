# Drop 2026 presets — `PRESET_26_*`

Source: brief "tune 7 preset skeleton" (2026-11-07), built from the spec's §3–§5 params. Code: `Sources/RawCore/Presets2026.swift`.
Every preset is a `FilmStock` (`--stock PRESET_26_CPM35`, app picker), so the bench renders all 7 on every file.

| App name | spec id | tier · prio · group | exposure / K / tint | sat · vib · shadow · highlight | grain / size | vignette | intensity | skinProtect |
|---|---|---|---|---|---|---|---|---|
| PRESET_26_CPM35 | cpm35 | Free · P0 · digicam | +0.10 / 5400 / −6 | 0.95 · – · – · – | 0.40 / 1.2 | 0.25 | 60 % | – |
| PRESET_26_PORTRAIT160 | portra-160 | Pro · P1 · film | +0.20 / 5700 / +2 | 0.95 · – · +0.30 · – | 0.25 / 1.0 | – | 60 % | – |
| PRESET_26_SOFT400 | fuji-400h | Pro · P1 · film | +0.20 / 5800 / −2 | 0.90 · – · +0.30 · – | 0.30 / 1.0 | – | 60 % | – |
| PRESET_26_CHROME64 | kodachrome-64 | Pro · P1 · film | 0.00 / 5500 / +2 | 1.15 · 0.35 · −0.10 · −0.40 | – | – | 60 % | – |
| PRESET_26_GOLDEN_R | grd-r | Pro · P2 · digicam | +0.15 / 5900 / +4 | 1.00 · – · – · – | 0.35 / 1.1 | ? | 60 % | – |
| PRESET_26_PALM_SPRINGS | palm-springs | Pro · P2 · cinematic | +0.15 / 5700 / −3 | 1.15 · 0.30 · – · – | 0.20 / 1.0 | – | 60 % | yes |
| PRESET_26_SOCIAL_POP | social-pop | Pro · P2 · cinematic | +0.10 / 5600 / 0 | 1.20 · 0.40 · −0.05 · – | – | – | 80 % | yes |

## What is spec and what is provisional
- **Spec numbers** above are used as given.
- **Tone-curve / per-channel direction is provisional** (`curveLocked = false`): the brief describes it in words only
  ("nâng đen nhẹ, S-curve mềm, G nhỉnh ở shadow…") and says the designer's locked numbers are the real ones. The
  code follows those words with small values so the direction is visible; it does not claim to be the final look.
- **Designer `.cube`:** `--stock PRESET_26_CPM35 --look path/PRESET_26_CPM35.cube` uses the designer LUT and keeps
  the stock's grain / vignette / skin protection.

## Mapping assumptions (to check against the designer's Lightroom values)
- Temperature is relative to 5500 K (Chrome 64 sits at 5500 = neutral). Higher K = warmer (Lightroom semantics),
  computed from Planckian chromaticities → Display P3 gains, luminance kept.
- Tint: − = green, + = magenta, 0.25 % green gain per unit.
- Shadows / highlights ±1 = at most ±0.12 encoded luma, centred on 1/3 and 2/3.
- Grain size 1.0 = the engine's default cell (0.07 % of the short edge).
- Whites roll off to ≤ 0.985 (soft shoulder), output ceiling 0.99: "highlight không cháy" even with +0.2 EV.
- Out-of-gamut colour is pulled toward luma instead of clipped (saturated reds stay dense, not neon).

## Spec §9.2 checks automated (Tests/RawCoreTests/Presets2026Tests.swift)
Names prefixed and free of trademarks · tone monotone · white not clipped and cast < 5 % (grd-r < 8 %, warm on
purpose) · Chrome 64 red keeps saturation without clipping · no shadow chroma blow-up · skinProtect presets force
skin protection ≥ 0.5 on people.
Not automated (need the 5-fixture set on 2 iPhones): skin on 3 tones, 9:16 Story crop, realtime preview ≤ 33 ms.

## Open questions (not guessed)
1. `grd-r`: group B says vignette is part of the identity, but the spec gives no value → none applied.
2. `fuji-400h` display name "Fuji Soft 400" contains a trademark (the checklist forbids it) → app name `PRESET_26_SOFT400`.
3. `kodachrome-64` has no grain in the spec → none applied.
4. PO: ship `palm-springs` or `social-pop` (20 vs 21)? `social-pop` as its own Story preset or 80 % of a feed LUT?
5. `superia-400` and `cinestill-800t` (already done in the drop JSON) are not in this repo; send their JSON to add them.
