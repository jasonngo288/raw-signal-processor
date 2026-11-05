# Planning — CIRAWFilter-based RAW "film development"

## Why this direction
Previous attempts (custom DNG → ForwardMatrix → XYZ → LUT, then a C++ ISP) produced renders that were
hazier (black p1 0.012–0.033 vs Apple 0.0003), softer and haloed compared with Apple's decode of the same DNG;
a per-scene LUT can hide that on one image but not in general. Apple's `CIRAWFilter` already contains the
demosaic, noise reduction, lens correction, local tone mapping and per-camera profiles Apple uses in Photos,
and exposes them as parameters. So: **use Apple's decoder as the base, control it explicitly, differentiate
on top** (context decisions + film looks).

## Phases
| phase | content | exit criterion |
|---|---|---|
| 0 Spike (this branch) | RawCore + raw-bench + CI on originals/ | Gate 1 (explicit ≡ appleDefault) measured in CI |
| 1 Controlled base | pin decoder per OS, read & store Apple defaults per model, DecisionEngine tuning on more RAWs | Gate 2 on ≥ 20 RAWs |
| 2 Colour consistency | ColorChecker per model (12…18), fit 3×3 CCM in linearSpaceFilter, store per model + decoder | Gate 3: ΔE00 < 2 cross-model |
| 3 Looks | film looks (parametric + .cube), grain/halation as Metal CIKernel, intensity | user study / visual review |
| 4 App | AVFoundation capture (Bayer RAW / ProRAW), live preview via same Core Image graph at draft scale, HEIC10 export with recipe in metadata | on-device perf: < 1.5 s full-res develop on iPhone 12 |

## Fixed vs per-device
- Fixed: working space, metrics, look definitions, DecisionEngine rules and bounds, export.
- Per device/OS (stored, recipe-logged): decoder version, Apple default parameters, CCM.

## Open questions (tracked in WORK_LOG.md)
- Exact behaviour of `neutralTemperature/Tint` round trip (only written when changed).
- Whether Pixel/HDR+ DNG (originals/HDR01) gets the same quality from CIRAWFilter as iPhone DNGs.
- iPhone 8 DNG (BVQX5524) has BaselineExposure −1.79 EV: check `baselineExposure` default handling.
