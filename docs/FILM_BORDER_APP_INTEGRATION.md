# Film Border — app integration guide (for the coding agent in the app repo)

**Audience:** an agent working in the host app (RollioRoll, formerly MoodRoll, `../MoodRollApp`).
**Goal:** let the user put a film border on developed frames, in preview, in saved exports and in Instagram shares,
by calling the Film Border Renderer in the RSP Swift package (`RawCore`).
**Spec:** `FILM_BORDER_RENDERER_SPEC.md` v1.0 (2026-11-21). Engine side: `Sources/RawCore/FilmBorder.swift` and
`FilmBorderRenderer.swift` in raw-signal-processor (RSP).

Read the whole guide before starting, then follow the steps in order. **Stop and report** (do not guess) on any item
in "Stop conditions".

---

## 0. Gate 0 — check before writing code

- [ ] **RSP version.** The app's pinned RSP version contains the Film Border Renderer: `FilmBorderRenderer` and
      `FilmBorderTemplates` resolve. If not, stop. The RSP owner must merge `feature/film-border` (rebased onto the
      release line the app pins) and tag a release; then bump the app's package pin to that tag. Do not copy RSP
      source files into the app.
- [ ] **Where the app develops.** You can name the file and function that calls `Developer.develop(...)` (whole-roll
      develop) and the one that exports / saves (`Renderer.export(...)` or the app's own writer).
- [ ] **The HEIC fallback.** You can name the place that handles frames with no usable DNG. Those frames get a
      border too.
- [ ] **Persistence.** You know where per-roll and per-frame edit state is stored (model, Core Data / SwiftData /
      files).
- [ ] **Clean baseline.** The app builds and its tests pass before you start.

---

## 1. Rules (do not break)

1. **Border is a separate stage after development.**
   - Never pass stock parameters into the border.
   - Never re-apply a look or colour transform in the border stage.
   - Film stock and border are chosen independently; changing one keeps the other (spec §2, §14).
2. **Use RSP's renderer as-is.**
   - Do not re-implement borders, masks or textures in the app.
   - Do not add raster frame assets: the engine is procedural.
3. **Deterministic.**
   - Build every frame's configuration with `forFrame(rollID:frameID:index:count:)`.
   - Never use a random seed per refresh.
   - Preview, export and a re-open months later must match.
4. **Preview and export use the same configuration**; preview only adds `outputLongEdge`.
5. **The original photo is never overwritten.**
   - The border is applied at export / share time, or to a separate derived file.
   - "No border" must always be possible (spec §2).
6. **Every exported file keeps its recipe:** set `recipe.border = result.record` before `Renderer.export(...)`.
7. **No full-resolution work on the main thread.** Rendering must be cancellable when the user leaves the screen.

---

## 2. Engine API (what you call)

```swift
import RawCore

// Templates (P0: classicScan, agedPaper; P1: filmNegative, instantPrint)
FilmBorderTemplates.all                      // [FilmBorderConfiguration], ids:
                                             // "classic_scan", "aged_paper", "film_negative", "instant_print"
FilmBorderTemplates.named("classic_scan")    // FilmBorderConfiguration?

// Per-frame configuration (stable seed, roll context)
let cfg = FilmBorderTemplates.classicScan
    .forFrame(rollID: roll.id, frameID: frame.id, index: frame.index /* 1-based */, count: roll.frameCount)

// User controls (all optional; defaults come from the template)
cfg.layout.sizeMultiplier = 1.0               // border thickness; template defaults = 1
cfg.paper.color = BorderColor(hex: "#FAF8F3")!
cfg.paper.textureStrength = template.paper.textureStrength * k   // k in 0...2 (UI 0...1 → ×0...2)

// Render a print (border only)
let r: FilmBorderResult = try FilmBorderRenderer.render(developedImage /* CIImage */, configuration: cfg,
                                                        outputLongEdge: nil /* Int?: nil = full res */)
r.image   // CIImage, opaque, canvas at the origin
r.record  // FilmBorderRecord: configuration, canvas size, opening, crop fraction, tilt, notes

// Render for sharing (border + fixed-aspect canvas; the print is never cropped)
let s = try FilmBorderRenderer.renderForShare(developed, configuration: cfg,
                                              canvas: .instagram(.portrait4x5))   // .square, .story9x16
// default background: light (#E4E1DA); ShareCanvas.dark / .white are options
s.image  // 1080×1350 / 1080×1080 / 1080×1920

// Export with the recipe
var recipe = developedOutput.recipe
recipe.border = r.record
let data = try developer.renderer.export(r.image, format: .heic10 /* or .jpeg */, recipe: recipe)
```

> The exact call is `FilmBorderRenderer.render(_ developed: CIImage, configuration:outputLongEdge:)` (first argument
> unlabeled). Check the signature in the pinned RSP version.

**Template behaviour the UI should know:**

| Template | What it is | Notes for the UI |
|---|---|---|
| `classic_scan` (P0) | Thin uneven near-white scan border, soft serrated edge, slight tilt | Default. Varies a little per frame by design (seeded). |
| `aged_paper` (P0) | Cream deckle-edge card on a backdrop, aging, fibres | The card has its own backdrop and shadow. |
| `film_negative` (P1) | 35 mm strip: holes, edge print with the real frame number, edge burn | Needs `index` / `count` (frame number, burn on frames 1–2). Hide the size slider (physical size). |
| `instant_print` (P1) | Instant card picked by orientation (wide / mini / square) | Crops only when the photo is outside the card's aspect range: show `record.cropFraction` when > 0 ("Cắt n %"). |

---

## 3. Steps

### Step 1 — Data model
- **Roll:** `borderTemplateID: String?` (nil = no border), `paperColorHex: String?`, `borderSize: Double`
  (default 1), `textureLevel: Double` (UI 0...1, default 0.5 → ×1).
- **Frame:** optional overrides (same fields); `borderSeedSalt: String?` (only if you add "shuffle", see step 5).
- **Migration:** existing rolls get `borderTemplateID = nil`, so nothing changes for old rolls.

### Step 2 — One function that builds the configuration
Write one app-side function (single source of truth for preview and export):

```swift
func borderConfiguration(roll: Roll, frame: Frame) -> FilmBorderConfiguration? {
    guard let id = frame.borderTemplateID ?? roll.borderTemplateID,
          let base = FilmBorderTemplates.named(id) else { return nil }
    var c = base.forFrame(rollID: roll.id, frameID: frame.id + (frame.borderSeedSalt ?? ""),
                          index: frame.index, count: roll.frameCount)
    c.layout.sizeMultiplier = Float(frame.borderSize ?? roll.borderSize)
    if let hex = frame.paperColorHex ?? roll.paperColorHex, let col = BorderColor(hex: hex) {
        if c.filmEdge.enabled { c.filmEdge.baseColor = col } else { c.paper.color = col }
    }
    let k = Float((frame.textureLevel ?? roll.textureLevel) * 2)   // UI 0...1 → ×0...2
    c.paper.textureStrength = base.paper.textureStrength * k
    c.paper.mottleStrength = base.paper.mottleStrength * k
    return c
}
```

### Step 3 — Develop → border → export
- In the roll-develop / export path, after `Developer.develop(...)`: if `borderConfiguration(...)` is non-nil, call
  `FilmBorderRenderer.render`, set `recipe.border`, export. If nil, export as today (no-border path).
- Keep the developed (border-less) result available. The border is a derived output, so changing the template later
  re-renders from it without developing again.
- **HEIC-fallback frames:** load the HEIC as a `CIImage` (apply orientation) and run the same border call. Its record
  says it came from the fallback, as the app already logs.

### Step 4 — Preview
- Render with the same configuration on the preview-size developed image, adding `outputLongEdge` = the preview's
  long edge in pixels (e.g. 1200).
- Debounce slider changes (≈ 100–150 ms).
- Render off the main thread; cancel stale renders.
- Cache per (frame, configuration).

### Step 5 — UI (MVP controls, spec §2)
- **Template picker:** None, Classic Scan, Aged Paper (P0); Film Negative, Instant Print (P1, behind a flag if
  needed). Changing the template never changes the film stock.
- **Border size slider,** with a detent at 1×:
  - classic 0.5–2.5×
  - aged 0.6–1.6×
  - instant 0.8–1.2×
  - film_negative: slider hidden
- **Paper colour swatches** (no colour picker):

  | Swatch | Hex | Note |
  |---|---|---|
  | Scan White | `#FAF8F3` | classic default |
  | Ivory | `#EEE8DC` | |
  | Cream | `#EFE8D6` | aged default |
  | Sepia Card | `#DCCFB6` | |
  | Ink Black | `#1B1A18` | |

  For film_negative the swatches mean film base: Clear `#D5D4D6`, C-41 Orange `#D08A55`, Inverted Black `#141312`.
- **Texture strength slider** 0...1 (maps ×0...2 of the template default).
- **Reset:** back to the template defaults and the frame-id seed.
- **No border:** template "None".
- **Optional "shuffle"** (re-roll imperfections): set a new `borderSeedSalt` on the frame and persist it. Never
  random per refresh.

### Step 6 — Share to Instagram
- **Share sheet options:** 4:5 (default), 1:1, Story 9:16. Use `FilmBorderRenderer.renderForShare(…, canvas:
  .instagram(aspect))`. The default background is light `#E4E1DA`; dark and white are options.
- **Shares a frame without a border too:** use `FilmBorderRenderer.share(developedImage, canvas:)`, so 3:4 photos are
  padded, not cropped.
- **Size:** export 1080 px wide (the presets already do this), as JPEG or HEIC per the app's share policy, with the
  recipe.

### Step 7 — Tests (app side)
- [ ] Unit: `borderConfiguration` returns nil for "None", is stable for the same frame, differs between frames, and
      keeps the roll seed for frames of one roll.
- [ ] Unit: changing the template does not change the stock settings, and vice versa.
- [ ] Snapshot / visual: portrait, landscape and square frames with each P0 template. Preview and export have the
      same proportions (compare `record.opening` / canvas ratios).
- [ ] Export: the file has the border, full resolution, and the recipe with `border`; the no-border export is
      unchanged from today.
- [ ] Share: 4:5 / 1:1 / 9:16 outputs are exact sizes and the print is uncropped.
- [ ] Performance on the oldest supported iPhone: full-res export of a 12 MP frame (and 48 MP if supported). Record
      time and peak memory; the UI never freezes; cancelling works.

---

## 4. Verification before you hand back

- The app builds and all app tests pass.
- Manual run on a simulator or device: pick each template, change size / colour / texture, reset, no border, export,
  share 4:5 and Story.
- Report: files changed, screenshots of each template (portrait and landscape), export timings, anything unverified.

## 5. Stop conditions (report, do not guess)

- The pinned RSP version does not contain the Film Border API, or a signature differs from this guide.
- The app has no clear single develop / export path (more than one place renders final images).
- Memory or time on device is clearly too high (e.g. > 3 s or a memory warning for a 12 MP export). Report the
  numbers; do not lower quality silently.
- Anything that would require changing film-stock or develop code in RSP.

## 6. Out of scope (do not build now)

- Handwritten caption on instant prints (spec non-goal for MVP).
- Creases / cracks on aged paper.
- The neighbour-frame hint on the film strip.
- Custom colour picker; user rotation or repositioning of the photo in the frame.
