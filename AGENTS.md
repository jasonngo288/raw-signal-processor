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

## Hard rules
1. **Every render writes a `DecodeRecipe`** (decoder version, defaults, effective values, support flags, decisions, OS).
2. `appleDefault` mode must never carry overrides (validated). It is the reference, not a product mode.
3. Pure-Swift code (`ColorMath`, `LinearImage`, `ImageMetrics`, `Look`, `RenderSettings`, `DecisionEngine`)
   must not import Core Image; Apple-framework code sits behind `#if canImport(...)`.
4. **CI (macos-15) must be green** before merge: build, `swift test`, `raw-bench bench originals`.
   This Linux dev container has no Swift toolchain (download.swift.org blocked) — CI is the compiler.
5. Quality claims need numbers from `raw-bench` (docs/METRICS.md), pixel-aligned vs `appleDefault` of the same file.
   Never claim "better than Apple" from a box ΔE alone; check black p1, halo ring, local contrast too.
6. `originals/` holds the user's test RAWs (files prefixed `USER_` were added at the user's request from earlier chats).
   Do not add other personal images. Do not commit bench outputs (CI prints a base64 preview tarball to its log instead).
   `output/` holds device captures from the demo app that the user pushed (private, like `USER_` files).
7. **Update WORK_LOG.md in the same commit** as any change: what, why, evidence (CI run / numbers), what is unverified.
8. No third-party dependencies without a written reason in WORK_LOG.md.
9. **Anything not in docs/ROADMAP.md is a plugin** (`DevelopPlugin`, Plugins.swift): it must be removable with
   `plugins = []` without breaking the core, list itself in `recipe.plugins`, and be listed in the ROADMAP "EXTRAS" table.
   The bench always runs `auto` (default plugins) and `auto core` (no plugins) so the effect of the plugins is visible.

## Decision gates
- **Gate 1**: `explicit` (Apple defaults written back) reproduces `appleDefault` — ΔE00 mean < 0.5. Proves we control the decoder.
- **Gate 2**: `auto` stays within ΔE00 ≤ 3 of `appleDefault` **on pixels Apple did not clip** (`deltaE00MeanUnclipped`),
  with black p1 not raised (> +0.002) and halo ring not brighter (> +0.01). Evaluated per file in `summary.md`; holdout files are reported, never tuned on.
- **Gate 3**: cross-model chart ΔE00 < 2 after CCM (needs ColorChecker shots from ≥ 2 iPhone models — not yet available).

## Layout
```
Sources/RawCore/   ColorMath, LinearImage, ImageMetrics, RenderSettings, Look, ContextAnalysis (pure Swift)
                   Calibration (per-model CCM table, DecoderPolicy)
                   RawDecoder, Renderer, Developer (analyse → decode → plugins → look → skin protection → finish), VisionAnalyzer,
                   FilmFinisher, Plugins (highlightRecovery, vignette)
Sources/CaptureKit AVFoundation Bayer RAW + HEIC capture (iOS; compiled in CI, not run)
Sources/RawBench/  raw-bench CLI: info | render | compare | bench
corpus/            corpus.json (public RAWs, fetched by CI, never committed) + README
Tests/RawCoreTests unit tests (Sharma CIEDE2000, metrics, LUT, settings, decisions) + decoder tests on originals/
docs/              PLANNING.md, METRICS.md
```

## How to run (macOS 14+, Xcode 16)
```
swift build -c release
swift test
.build/release/raw-bench info originals/IMG_1901.DNG
.build/release/raw-bench bench originals --out bench-out --full
```
