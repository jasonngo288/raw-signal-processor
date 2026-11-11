# Smartphone look → film develop: plan (tone-mapping-expert, 2026-11-11)

The plan is from the tone-mapping-expert agent, written down by the lead. The agent checked `raw-bench info` on the
5 originals, the 2 device recipes in `docs/2026-11-08T15-*`, RawDecoder write/support, DecisionEngine, Developer,
FilmFinisher, RollStocks and ImageMetrics. The lead re-checked IMG_1901 (`sharpnessAmount` 0.890, `detailAmount` 0,
`localToneMapAmount` 0, `luminanceNoiseReductionAmount` 0, `boostShadowAmount` 0.9).

## 1. Diagnosis: what makes a Bayer CIRAWFilter decode look like a phone
1. **Sharpening.** `sharpnessAmount` defaults to 0.89–0.96 on every iPhone Bayer file (0.5 on the Pixel file, 1.0 on the
   15 Pro ProRAW). It is an unsharp mask at native pixel scale: edge overshoot and crunchy texture.
2. **Our own plugins put phone tone back:**
   - `highlightRecovery` clarity 0.4 is a large-radius unsharp mask: halo and an HDR feel.
   - On device, `cameraMatch` applies the ToneMatch curve fitted to the camera HEIC, which imports the ISP's Smart-HDR tone.
3. **Shadow lift.** `boostShadowAmount` 0.9 reads as flat.
4. **Not the cause on Bayer:**
   - Luma NR defaults to 0 at ISO 32–200; chroma NR is 0.4–0.5.
   - LTM is 0 and unsupported on every Bayer file (macOS 15.8, iPhone 14 Pro). It is supported only on ProRAW (default 1).
   - `detailAmount` is 0 on Bayer, 0.5 on ProRAW.
   - Supported on our files: sharpness, detail, contrast, luma / chroma NR, moiré. Lens correction is unsupported everywhere.
5. **Side finding.** The DecisionEngine face rule lowers `detailAmount` by 0.10, which is already 0 on Bayer, so it does nothing there.

## 2. Design: plugin `filmDevelop`
- Rule 10: not in the ROADMAP, so it is a plugin, listed in EXTRAS.
- **Data:** a pure-Swift `FilmDevelop` in Look.swift as `FilmStock.develop`, with `sharpScale`, `ltmScale` (ProRAW),
  `clarityScale` and `lumaNRMaxDelta`. `RollStock` sets it from ISO and character.
- **Where it runs:** `filmDevelop.decide` reads `settings.stock`, runs after DecisionEngine, scales Apple's per-file
  defaults within bounds, and logs every reason. Stage 1 (decode). The stored analysis is stock-independent.
- **Re-finish:** `Base` records the develop profile it was decoded with. A finish with a stock of another profile logs
  "base developed for X, finished as Y".
- **Gate 2:** plain `auto` has no stock, so the plugin is a no-op. Add a base gate for `auto+<stock>` before the look:
  ΔE00 unclipped ≤ 1.0, black p1 ≤ +0.002, ring ≤ +0.01 vs `appleDefault`. Expected: ΔE ~0.1–0.4, `localContrast`
  slightly lower on purpose (METRICS.md needs a film-stock exception).
- **Grain:** order is decode (softer) → look → halation → grain last; never sharpen after grain. Grain cells
  (≈1.5–2.6 px at 12 MP) sit in the band iPhone sharpening boosts, so grain on a sharpened base reads as digital noise.
  At high ISO: less luma NR, grain hides the leftover noise, chroma NR is kept.

## 3. Metrics
- **Blind spot:** all metrics run at a 1024 px long edge, which hides native-scale sharpening. Add native-resolution
  crops (1024² centre + 4 tiles).
- **New metrics (bench-qa):**
  - edge overshoot % (strongest 1 % log-Y edges, ±6 px profile);
  - HF energy ratio (DoG σ 0.7–2 px over σ 2–6 px, vs appleDefault);
  - flat-area texture (high-pass std in low-gradient areas, before and after grain).
- **Pass:** overshoot −30 % or more; HF ratio 0.6–0.85 (< 0.5 = mush); flat texture before grain ≥ 0.9× Apple.

## 4. Starting values (multipliers on Apple's per-file default, logged)

| Condition | Sharpness | Luma NR | Other |
|---|---|---|---|
| ISO < 400 | ×0.55, floor 0.30 absolute | | |
| ISO 400–1599 | ×0.45 | Δ 0 | |
| ISO ≥ 1600 | ×0.35 | Δ ≤ +0.05 (instead of +0.10) | chroma NR +0.10 kept |
| Vivid stocks | ×0.70 | | |
| softPortrait stocks | ×0.45 | | |
| Faces ≥ faceArea | extra −0.10 | | |
| A stock is set | | | highlightClarity ×0.4 |
| ProRAW only | | | detail 0.5 → 0.2; LTM 1 → 0.6 is a separate trial (tone change, one pair only) |

- Leave contrast / boost / boostShadow alone: they are tone, and looks own the curve.
- **Risks:**
  - the 0.30 floor may look mushy on 12 MP files;
  - sharpening behaviour at `scaleFactor < 1` is unknown (preview vs full-res);
  - no local iPhone file above ISO 200, so the high-ISO values are unverified;
  - the originals are tuning files, so the holdout runs in CI only.

## 5. The user's feedback
- **"Bypass Apple's harsh LTM":** does not apply to a Bayer decode (LTM unsupported, 0; single unfused frame). The
  harshness reaches our output through the cameraMatch ToneMatch curve (HEIC tone) and our clarity. Lever: lower the
  cameraMatch curve strength for stocks (e.g. 0.5, exposure match kept); this is ROADMAP item 7. LTM is real on ProRAW.
  A full bypass (sceneLinear + own curve, as logLook does) breaks "Apple tone is the base" and fails Gate 2.
- **"Multi-frame stacking":** a capture change plus align / merge, i.e. a custom ISP, which the architecture rules
  out. ProRAW already is Apple's stack. Possibly a later CaptureKit option for static scenes. See also
  `FEEDBACK_CRITIQUE_2026-11-11.md`.

## Owners
- raw-core-engineer: plugin, `FilmDevelop`, face-rule fix, cameraMatch strength for stocks.
- bench-qa: native crops, the 3 new metrics, the `auto+<stock>` base gate.
