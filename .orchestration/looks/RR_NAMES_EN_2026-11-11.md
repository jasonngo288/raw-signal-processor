# RR roll stocks — English names (proposal, 2026-11-11)

**Internal note.** The "inspired by" column must never reach code, the UI or store metadata (R6).
This is not legal advice: run a trademark check on the final list before launch.

## Why not plain abbreviations of the original names
- Many abbreviations are **themselves registered product codes** of the film makers. A product code is as risky as
  the full name, and arguably more, because it reads as "the same product".
  Examples: C200 / C400 (a maker's film codes), E100 (a slide film), Gold, Portra-style "P400", "UM400".
- Safer pattern (R2 kept): `RR <generic English word that cues the vibe> <ISO>`. A film shooter can still guess
  from the cue word together with the ISO, and the ISO + T suffix is generic (R8).
- Avoid words that are a maker's own product word: Gold, Portra, Ektar, Max / Ultramax, ColorPlus, Cine / Cinestill,
  Prism, Maple, Star, Chrome, Vision, Pro.
- Cue words that are ordinary English are generally fine, but the closer to the original, the higher the risk.
  Column B keeps a stronger cue, column C is the safest.

| id | inspired by (internal) | A. today (VI) | B. English, strong cue | C. English, safest |
|---|---|---|---|---|
| rr-sao-mai-200 | YesStar 200 | RR Sao Mai 200 | RR Daylight 200 | RR Everyday 200 |
| rr-sao-hom-400 | YesStar 400 | RR Sao Hôm 400 | RR Dusk 400 | RR Everyday 400 |
| rr-mat-200 | Fuji C200 | RR Mát 200 | RR Cool 200 | RR Breeze 200 |
| rr-gio-400 | Fuji C400 | RR Gió 400 | RR Cool 400 | RR Breeze 400 |
| rr-vang-200 | Gold 200 | RR Vàng 200 | RR Golden 200 | RR Honey 200 |
| rr-am-200 | ColorPlus 200 | RR Ấm 200 | RR Color 200 | RR Warm 200 |
| rr-ruc-400 | Ultramax 400 | RR Rực 400 | RR Ultra 400 | RR Bold 400 |
| rr-hoai-co-100 | KodaColor 100 | RR Hoài Cổ 100 | RR Retro 100 | RR Memory 100 |
| rr-hoai-co-200 | KodaColor 200 | RR Hoài Cổ 200 | RR Retro 200 | RR Memory 200 |
| rr-lang-kinh-200 | Reto Prism 200 | RR Lăng Kính 200 | RR Spectrum 200 | RR Vintage 200 |
| rr-lang-kinh-400 | Reto Prism 400 | RR Lăng Kính 400 | RR Spectrum 400 | RR Vintage 400 |
| rr-la-phong-100 | Reto Maple 100 | RR Lá Phong 100 | RR Red Leaf 100 | RR Autumn 100 |
| rr-nang-100 | Proimage 100 | RR Nắng 100 | RR Sunny 100 | RR Sunny 100 |
| rr-ruc-ro-100 | Ektar 100 | RR Rực Rỡ 100 | RR Vivid 100 | RR Vivid 100 |
| rr-da-mem-160 | Portra 160 | RR Da Mềm 160 | RR Portrait 160 | RR Soft Skin 160 |
| rr-chan-dung-400 | Portra 400 | RR Chân Dung 400 | RR Portrait 400 | RR People 400 |
| rr-dem-mem-800 | Portra 800 | RR Đêm Mềm 800 | RR Portrait 800 | RR Night Soft 800 |
| rr-den-vang-800t | Cinestill 800T | RR Đèn Vàng 800T | RR Tungsten 800T | RR Lamp 800T |
| rr-chuan-160/400/800 | Ektacolor Pro | RR Chuẩn … | RR Lab 160/400/800 | RR Studio 160/400/800 |

## Recommendation
- **Use column B, with three changes from C:**
  - "Ultra 400" → "Bold 400" (too close to a product name);
  - "Color 200" → "Warm 200" (too close to a product name);
  - "Spectrum" is fine.
- B gives the strongest guess with ordinary words.
- **Portrait 160 / 400 / 800:** "Portrait" is a generic English word, but together with exactly 160 / 400 / 800 it
  points at one product family. It is the most recognisable name and also the riskiest; flag it for the legal check
  (fallback: Soft Skin / People / Night Soft).
- **Implementation:** keep the `rr-…` ids as they are (stable for storage and recipes). Add `nameEn` beside
  `nameVi`, and let the host app pick the UI language.
