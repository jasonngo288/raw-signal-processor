# Adding or changing a film stock: look mapping guide (PO / BA)

**Audience:** PO / BA preparing a new stock (or a change) for the MoodRoll catalog.
**Created:** 2026-11-12.
**Lives in:** this RSP repo (the looks it maps to are defined here).
**Applies from:** RSP `0.2.0` (MoodRoll task `docs/tasks/T2_RENDER_PROFILE.md` in the MoodRoll repo). Until then, stocks still live in `Sources/RawCore/RollStocks.swift`.

**Sources of truth:**
- **Looks:** `Sources/RawCore/FilmLooks.swift` (`FilmLooks2026.looks`), published to the app as `SupportedLooks` with `RawCore.engineVersion`.
- **Naming rules R1–R10:** `docs/input/doi-ten-film-stock-RR-2026-11-11.md`.
- **Current stocks:** MoodRoll repo `MoodRollApp/Resources/FilmStocks/film-stocks.json` (after T2). The stock catalog is host-app data; RSP only defines the looks.

## 1. The model in one line

> **Stock (layer 1, MoodRoll/server) = name + ISO + one RSP look + arguments.**
> **Look (layer 2, RSP) = the colour science.** It is never edited from a stock.

**You can, without any release:**
- add a stock on an existing look;
- change a stock's name, ISO, intensity, grain, halation, vignette, light leak or decode character;
- hide or retire a stock.

**You need an RSP release** (ask the RSP owner) for:
- a new colour character that no listed look gives;
- a new kind of effect.

## 2. Checklist for a new stock

1. **Describe the feel in one sentence:** colour, contrast, grain, best light, people or scenery.
2. **Pick the look** from the supported list (§4). Pick by what the look does, not by its name.
   - Look for the closest summary.
   - If two looks fit, compare them on the 6 sample scenes (Film Library samples) with the dev.
   - **Never pick a black-and-white look** (`monoSoft`, `monoPunch`) for a colour stock.
3. **Set the arguments** (§5). Start from the look's defaults and change as little as possible.
4. **Name it** by R1–R10:
   - `RR <1–2 descriptive words> <ISO>`;
   - id = ASCII slug `rr-<words>-<iso>`;
   - `nameVi` with full diacritics, `nameEn` as a translation;
   - `T` suffix for tungsten;
   - no maker or product names anywhere;
   - ≤ 3 syllables after `RR`.
5. **Check uniqueness (R5):**
   - no other stock may have the same look + ISO + intensity;
   - two stocks on the same look must differ clearly, either in ISO (grain) or in intensity / arguments.
6. **Fill the catalog entry** (§6), with `status: "hidden"` first.
7. **Validate:**
   - run a DEBUG build, then open Files → On My iPhone → MoodRoll → Diagnostics → `pipeline-log.jsonl`;
   - the stock must have **no error**;
   - a warning needs a written reason.
8. **Review renders:** the dev renders the 6 sample scenes plus 2 real RAW rolls (one daylight, one indoor or night). PO approves.
9. **Release:** set `status: "available"`, bump `revision`, add a line to the change list (§7).

## 3. What you must not do

- Edit a look's values to fit one stock. Looks are shared. Ask for a new look instead.
- Reuse an id for a different look. A changed look means a new `revision`. A different stock means a new id.
- Point a stock to a look that is not in `SupportedLooks` for the current `engineVersion`. The app drops it and logs C1.
- Expect a stock change to leave existing rolls alone: every develop uses the latest catalog entry.
- Copy maker, product or "inspired by" names into any field (R1, R6, R7). Keep "inspired by" only in internal research notes.
- Put a stock with `minEngine` above the shipped engine on `available`. The app hides it and logs C2.

## 4. Supported looks (RSP at `7a304c5`; after T2 all of these are listed)

| Look id | Character (RSP summary, shortened) | Default intensity | Default finish | Used by today |
|---|---|---:|---|---|
| softPortrait | light, airy portrait: open mids, lifted toe, peach skin, soft olive greens | 0.85 | grain 0.25 / 0.06, vignette 0.05 | Da Mềm 160 |
| naturalPortrait | true warm skin, medium contrast, moderate colour, soft rolloff | 0.85 | grain 0.30 / 0.065, vignette 0.04 | Chân Dung 400, Đêm Mềm 800 |
| goldenDay | warm faded everyday: golden light, honey yellows, rich reds | 0.85 | grain 0.40 / 0.07, halation 0.10, vignette 0.04 | Vàng 200 |
| warmMuted | soft warm everyday 200: amber-red warmth, moderate colour | 0.85 | grain 0.30 / 0.06, vignette 0.06 | Ấm 200 |
| everydayGreen | warm-muted analog, emerald greens, magenta-leaning reds | 0.85 | grain 0.45 / 0.075, vignette 0.04 | Sao Mai 200, Sao Hôm 400 |
| pastelCool | pastel airy: soft contrast, slate shadows, mint greens, rose skin | 0.85 | grain 0.20 / 0.06 | Mát 200 |
| trialCoolFade | cool faded 400: grey lifted blacks, cool green-cyan shadows, muted | 0.85 | grain 0.42 / 0.07, vignette 0.08 | Gió 400 |
| vividFine | vivid memory colour: deep crimson, rich yellows, deep blacks | 0.85 | grain 0.22 / 0.055, vignette 0.05 | Rực 400, Rực Rỡ 100 |
| brightTravel | clean vivid daylight: punchy, clean blues, emerald greens, true reds | 0.90 | grain 0.05 / 0.04 | Nắng 100 |
| sunFade | expired warm film: strongly faded, grey-brown blacks, cream cast | 0.85 | grain 0.50 / 0.08, vignette 0.12 | Hoài Cổ 100, Hoài Cổ 200 |
| warmEvening | pushed warm moody: deeper mids, brown blacks, muted warm palette | 0.85 | grain 0.50 / 0.085, halation 0.06, vignette 0.15 | Lăng Kính 200, Lăng Kính 400 |
| mapleRed | slow warm daylight: deep crimson, cyan-teal blues and shadows | 0.85 | grain 0.18 / 0.05, halation 0.05, vignette 0.06 | Lá Phong 100 |
| cleanLab | clean lab scan: neutral colour, accurate skin, clean soft whites | 0.85 | grain 0.22 / 0.055, vignette 0.03 | Chuẩn 400 |
| tungstenGlow | tungsten night: cool teal daylight, neutral lamps, strong halation | 0.90 | grain 0.60 / 0.085, halation 0.45, vignette 0.10 | Đèn Vàng 800T |
| mutedChrome | muted colour: low saturation, brick reds, olive greens, calm blues | 0.90 | grain 0.15 / 0.05 | — (free to use) |
| flashDigicam | early digital compact: hard contrast, clipped whites, cool-green cast | 0.90 | grain 0.30 / 0.05, vignette 0.30 | — (not film-like; avoid for film stocks) |
| monoSoft, monoPunch | black and white | 1.0 | — | **not for colour stocks** |

`cinemaNegative` is retired: do not use it.

## 5. Arguments you can set

The app validates these ranges. Anything outside them is an error (C3).

| Argument | Range | Default | Notes |
|---|---|---|---|
| `intensity` | 0.50 … 1.00 | look default | Below ~0.6 a look gets close to the base render, which is a weak identity |
| `iso` | 50 … 3200 | required by the MoodRoll catalog (C3); optional in RSP | Drives grain and decode. In RSP `LookArguments` it may be left out: the look keeps its own grain and no decode profile is applied (then `grain: {"iso": …}`, `tungsten` and `develop` are errors) |
| `grain` | `{ "iso": { "scale": 0.7…1.0 } }` (uses `iso`) or `{ "explicit": { "amount": 0…1, "size": 0.01…1 } }` | look default | Prefer the ISO form, so grain grows with ISO across the catalog |
| `halation` | `null`, or `{ "amount": 0…1, "threshold": 0.1…0.99, "radius": 0.05…5 }` | look default | Strong halation belongs on night or tungsten stocks |
| `vignette` | 0 … 1 | look default | Keep ≤ 0.15 unless the stock is a "toy" look |
| `lightLeak` | `null` or a named leak (`laPhong`) | none | Only leaks RSP ships. A new leak needs RSP |
| `develop` | `auto` / `vivid` / `portrait` | `auto` | `vivid` keeps more sharpness (saturated landscape stocks); `portrait` is softer on faces |
| `tungsten` | true / false | false | Adds `T` to the name and uses tungsten grain |

## 6. Catalog entry template

```json
{
  "id": "rr-hong-200",
  "revision": 1,
  "status": "hidden",
  "nameEn": "RR Rose 200",
  "nameVi": "RR Hồng 200",
  "iso": 200,
  "tungsten": false,
  "group": "warm",
  "order": 12,
  "code": "RSE",
  "leadScene": 0,
  "characterLine": "Soft rose warmth, gentle contrast",
  "look": "pastelCool",
  "arguments": { "intensity": 0.75, "iso": 200, "grain": { "iso": { "scale": 1.0 } }, "develop": "auto" },
  "personality": null,
  "editorial": null
}
```

`code` is 3 characters, unique, with no maker abbreviations. `group` is one of `everyday`, `warm`, `retro`, `people`, `night`.

## 7. Change list (keep it in the catalog PR / server change note)

```
YYYY-MM-DD · rr-<id> · added | changed | hidden | retired · look <id> · args changed: <list> · reviewed by <PO>
```

## 8. Where problems show up

Every data exception in render or pipeline is written to `Documents/Diagnostics/pipeline-log.jsonl`. In Debug builds you can read it in Files → On My iPhone → MoodRoll → Diagnostics. A Settings screen can also show it when its flag is on. Each line has a code, the stock, a message and a hint.

| Code | Meaning | What to do |
|---|---|---|
| C1 | Unknown look | Pick a look from §4 |
| C2 | Needs a newer engine | Wait for the app update, or keep the stock hidden |
| C3 | Argument out of range | Fix it per §5 |
| C4 | Duplicate id | Rename |
| C5 | B&W look on a colour stock | Pick a colour look |
| C6 | Brand word in a name | Rename (R1, R7) |
| C7 | Same look + ISO + intensity as another stock | Differentiate (R5) |
| M1–M3 | Develop-time fallback (unknown or removed id, legacy LUT path) | Report to dev, with the roll id from the log |
| RSP / IO | Engine or file error at develop time | Report to dev |
