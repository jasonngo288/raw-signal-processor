# AGENTS.md — rules for anyone (human or agent) changing this repo

## Goal
An iPhone camera app (iPhone 12 → 18) that captures RAW and "develops film":
1. **Base render at least as good as Apple's own RAW decode** (Photos "RAW gốc") — never worse.
2. **Consistent colour across models**: ΔE00 < 2 on a colour chart between models after per-model CCM.
3. **Film looks as the differentiator**, applied on top of the base render (looks never repair tone/colour).

## Architecture (decided — see docs/ROADMAP.md, the roadmap the user set on 2026-11-08)
- Decode with **Core Image `CIRAWFilter`** (Apple's demosaic, NR, lens correction, tone). No custom C++ ISP.
- **Pin the decoder version** (`decoderVersion`) and write **every parameter explicitly** in production modes.
- Per-model colour: 3×3 CCM via `linearSpaceFilter` (scene-linear, before Apple's tone).
- Context: pure-Swift stats on a scene-linear thumbnail + Vision (faces, classification). `DecisionEngine`
  makes **small bounded** changes to Apple's per-file defaults and **logs every reason** into the recipe.
- Looks: `CIColorCubeWithColorSpace` in encoded Display P3, parametric built-ins (`BuiltInLook`) or `.cube`.
- Working space: extended linear Display P3, half float. Export HEIC 10-bit (primary), PNG16, JPEG.

## Product integration (user decisions, 2026-11-09)
This repo is **the image-processing core and the goal**. MoodRoll (`../MoodRollApp`, film-roll camera app) is only
the host shell: UI, rolls, storage. **Priority: make the core pipeline solid here first, then integrate.**
- **Packaging:** RawCore and CaptureKit ship as a Swift package; MoodRoll pins a tag. Bench and gates stay here.
- **Capture:** MoodRoll keeps its UI; the backend is CaptureKit: Bayer DNG and HEIC from one press.
- **Analyse at capture time:** every frame gets a background analyse job (serial, one frame at a time) right after
  the press. Its result is stored next to the DNG, so develop never analyses again.
- **Develop** (whole roll at the end) uses this repo's `Developer` with the stored analysis.
- **Fallback:** a frame with no usable DNG goes through MoodRoll's current HEIC pipeline; the recipe says so.
- What this asks of the core (not built yet): a stored analysis must be self-contained (person mask on disk,
  the HEIC's histograms for cameraMatch, decoder version and plugin set it was made with; re-analyse if they
  differ at develop time); per-stage timings in the recipe; analysis cost measured on device with the camera running.
- **Open:** storage. A frame is DNG ≈ 10 MB (14 Pro Bayer) / 17 MB (15 Pro ProRAW) + HEIC ≈ 1.6 MB, kept until the
  roll develops (36 Bayer frames ≈ 430 MB). Deleting the HEIC after analysis saves ≈ 13 % only; see WORK_LOG 2026-11-09.

## Hard rules
1. **Every render writes a `DecodeRecipe`** (decoder version, defaults, effective values, support flags, decisions, OS).
2. `appleDefault` mode must never carry overrides (validated). It is the reference, not a product mode.
3. Pure-Swift code (`ColorMath`, `LinearImage`, `ImageMetrics`, `Look`, `RenderSettings`, `DecisionEngine`)
   must not import Core Image; Apple-framework code sits behind `#if canImport(...)`.
4. **CI (macos-15) must be green** before merge: build, `swift test`, `raw-bench bench originals`.
   Cloud/Linux sessions have no Swift toolchain — there CI is the compiler. On the user's Mac (Swift 6, Xcode 16) build and test locally first.
5. Quality claims need numbers from `raw-bench` (docs/METRICS.md), pixel-aligned vs `appleDefault` of the same file.
   Never claim "better than Apple" from a box ΔE alone; check black p1, halo ring, local contrast too.
6. `originals/` holds the user's test RAWs (files prefixed `USER_` were added at the user's request from earlier chats).
   Do not add other personal images. Do not commit bench outputs (CI prints a base64 preview tarball to its log instead).
   `docs/<timestamp>/` (formerly `output/`) holds device captures from the demo app that the user pushed (private, like `USER_` files).
7. **Update WORK_LOG.md in the same commit** as any change: what, why, evidence (CI run / numbers), what is unverified.
8. **Adding or removing a Swift file** in Sources/RawCore or Sources/CaptureKit means regenerating `App/RawFilmDemo.xcodeproj`
   (`cd App && xcodegen generate`, or take it from the XCODEPROJ block of the CI log). CI fails on a stale project.
9. No third-party dependencies without a written reason in WORK_LOG.md.
10. **Anything not in docs/ROADMAP.md is a plugin** (`DevelopPlugin`, Plugins.swift): it must be removable with
   `plugins = []` without breaking the core, list itself in `recipe.plugins`, and be listed in the ROADMAP "EXTRAS" table.
   The bench always runs `auto` (default plugins) and `auto core` (no plugins) so the effect of the plugins is visible.

## Decision gates
- **Gate 1**: `explicit` (Apple defaults written back) reproduces `appleDefault` — ΔE00 mean < 0.5. Proves we control the decoder.
- **Gate 2**: `auto` stays within ΔE00 ≤ 3 of `appleDefault` **on pixels Apple did not clip** (`deltaE00MeanUnclipped`),
  with black p1 not raised (> +0.002) and halo ring not brighter (> +0.01). Evaluated per file in `summary.md`; holdout files are reported, never tuned on.
- **Gate 3**: cross-model chart ΔE00 < 2 after CCM (needs ColorChecker shots from ≥ 2 iPhone models — not yet available).

## Layout
```
Sources/RawCore/   ColorMath, LinearImage, ImageMetrics, RenderSettings, Look, ContextAnalysis, ToneMatch, ColorChecker, Presets2026 (pure Swift)
                   Calibration (per-model CCM table, DecoderPolicy)
                   RawDecoder, Renderer, Developer (analyse → decode → plugins → look → skin protection → finish; Vision requests),
                   FilmFinisher, Plugins (highlightRecovery, cameraMatch, vignette)
Sources/CaptureKit AVFoundation Bayer RAW / ProRAW + HEIC capture (iOS; runs on device via App/)
Sources/RawBench/  raw-bench CLI: info | render | compare | bench
corpus/            corpus.json (public RAWs, fetched by CI, never committed) + README
Tests/RawCoreTests unit tests (Sharma CIEDE2000, metrics, LUT, settings, decisions) + decoder tests on originals/
docs/              ROADMAP.md, PLANNING.md, METRICS.md, PRESETS_2026.md; <timestamp>/ device captures
```

## How to run (macOS 14+, Xcode 16)
```
swift build -c release
swift test
.build/release/raw-bench info originals/IMG_1901.DNG
.build/release/raw-bench bench originals --out bench-out --full
```
