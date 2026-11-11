# Review of the user's "Color Science Pipeline Architecture" (2026-11-09)

Reviewed by `tone-mapping-expert` (skill `hdr-tone-mapping`) against the code; implemented by the orchestrator.

## Verdict per point
1. **10-step pipeline** — already the code (`Developer.swift`). Four statements in the document are wrong:
   DecisionEngine does not decide exposure or shadow boost (cameraMatch does); only the calibration exposure is
   "CCM × 2^EV in linearSpaceFilter" (cameraMatch's offset is CIRAWFilter `exposure`); highlight clarity runs only
   inside highlightRecovery; the EDR analysis decode and the shadow-gap → boostShadow rule are missing.
2. **Scene- vs display-referred, Y = I × R** — right as concepts; "Apple's LTM runs on gamma-encoded data" cannot be
   verified (it runs inside CIRAWFilter) and should not be stated as fact.
3. **cameraMatch quantile matching on Apple's render at 1024 px** — both stages already compared display renders,
   never scene-linear, but at 512 px and with two different downscales (CIRAWFilter scaleFactor vs affine).
   **Done:** one size for every comparison (`CameraMatchPlugin.histogramLongEdge = 1024`); the analysis takes
   clipping + histogram from the 1024 px Apple render Vision already used (one decode fewer). Schema 3.
   The tone curve stays on our developed image (matching Apple's render there would undo the exposure/boostShadow).
4. **Brand-named LUTs (Kodak Vision3, Fuji Eterna) / AgX** — brand names are not allowed as display names; a user
   `.cube` works today through `look` under a generic name. AgX as a LUT on Apple's display output would tone-map
   twice (black p1 ≫ +0.002, ΔE00 unclipped ≫ 3: a look repairing tone, against Goal 3). A real AgX base would replace
   Apple's tone from `sceneLinear` — only as an alternative-base plugin, later, if ever. Not done.
5. **Working space linearExtendedSRGB / ITU-R 2020** — the code and AGENTS.md use extended linear Display P3; all
   masks use P3 luminance weights. Changing it would move every mask and the halation hue. Not done (doc is wrong).

## Evidence for 3 (local, macOS 15.2)
`raw-bench bench originals corpus-cache --manifest corpus/corpus.json` before vs after, 27 files (24 decode; the three
Canon EOS RP DNGs never decoded): Gates 1/2/2-core identical on every file, **0 / 24 files changed decisions**, auto
metrics (ΔE00 unclipped, black p1, clipped %, halo ring) identical to 2 decimals. Device pairs (`raw-bench pairs docs`):
15 Pro mid EV −0.00 → −0.01, ΔE00 2.09 → 2.10, black p1 0.0015 → 0.0014; 14 Pro +0.00 → +0.00, 3.79 → 3.78,
0.0040 → 0.0040; clipped 0.00 both. Analysis 1.37 s → 1.16 s mean (−15 %, Mac, 24 files).
