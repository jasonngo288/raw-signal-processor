# Fact-check of 3 feedback claims (2026-11-11)

Confidence: H = read in a source this session, M = consistent with sources but inferred, L = memory or unverified.
"Measure" = must be measured with `raw-bench` (or on device) before it counts as evidence.

## Verdict table

| # | Claim | Verdict |
|---|---|---|
| 1 | 16 Bayer RAW frames in parallel, motion-aware stacking, DR200/DR400, then DNG/HEIF | Idea is real (HDR+ / Indigo), numbers and wording are wrong or unsupported for iOS. Partly useful at 2-4 frames. |
| 2 | Levoy (Adobe) "SuperRAW" fixes the smartphone look, keeps grain | Project and person are real. The name "SuperRAW" is not in Adobe's article (confusion). The look claim is half right. |
| 3 | Bypass Apple's harsh Local Tone Mapping | Mostly moot: our base is CIRAWFilter on Bayer DNG, not the HEIC. The relevant controls already exist in our code. |

## 1. Adobe Project Indigo and "SuperRAW"

Facts (H, [Adobe Research article](https://research.adobe.com/articles/indigo/indigo.html), Levoy and Kainz, June 2025; [Engadget](https://www.engadget.com/apps/adobe-project-indigo-is-a-new-photo-app-from-former-pixel-camera-engineers-213453207.html), [PetaPixel](https://petapixel.com/2025/06/19/adobes-new-computational-iphone-camera-app-looks-incredible)):
- Experimental iPhone app from Adobe's Nextcam team. Levoy and Kainz are ex-Google Pixel camera engineers. It is not a research paper, it is an app.
- Burst: up to 32 frames in Photo mode (user-adjustable, trading capture time for noise). Night mode: up to 1 s x 32 frames, tripod case. It is not a fixed 16.
- Zero shutter lag: raw frames are captured continuously and the last frame before the press is the reference. The burst starts before the press.
- Frames are aligned and merged in raw, before demosaic. The DNG output holds the merged, still-mosaiced data, linear, no tone mapping. Adobe says it is smaller than ProRAW.
- Exposure strategy: it underexposes more than most cameras to protect highlights, and relies on merging to clean the shadows. Noise falls as sqrt(N).
- Look: mild tone mapping, moderate saturation, sharpening, little smoothing, leaves "a bit of noise" (the article's phrasing). It calls this a more natural "SLR-like" look. Compatible with Adobe Adaptive Color.
- Super-resolution burst at zoom of 2x or more (main lens) and 10x or more (tele).
- "SuperRAW" does not appear in the article. I could not find it as a product name (M: not exhaustive). Likely confusion with Indigo's merged DNG, Adobe's "Super Resolution" (Enhance), or "Raw Details". Treat the name as unverified and drop it.

Critique:
- Right: merged raw is a better input than a single frame, and "less spatial smoothing because the temporal merge already denoised" is the real mechanism behind the natural look.
- Overstated: "keeps natural film grain". Indigo leaves residual noise. It does not synthesize or preserve film grain. Grain in our pipeline is a look-stage effect we design.
- Wrong venue: the look is mostly tone (mild) plus low NR plus moderate saturation. That is a parameter policy we already own through `DecisionEngine` and the explicit CIRAWFilter parameters. It does not require a burst.

## 2. What iOS lets a third-party app do

- `AVCapturePhotoBracketSettings` exists with a Bayer RAW initializer (`init(rawPixelFormatType:rawFileType:processedFormat:processedFileType:bracketedSettings:)`). The array length is bounded by `AVCapturePhotoOutput.maxBracketedCapturePhotoCount`. Apple's sample captures a 3-image RAW bracket and delivers 3 RAW photos. Apple warns that multi-image brackets may need extra resources. (H, [Apple docs](https://developer.apple.com/documentation/avfoundation/avcapturephotobracketsettings)). The actual device limit is not stated in any source I found. Read it at runtime (L for any number I could quote).
- A bracket is an exposure bracket (different EV per frame, auto or manual exposure settings). It is not a burst of identical frames with a ZSL ring buffer like Indigo's. Equal-exposure frames are possible by giving equal biases in the array (M, not tested). A bracket is shot as fast as the sensor and ISP pipeline allow, not at a documented frame rate (L).
- Forum report: on iPhone 16 Pro, brackets with large positive EV offsets (x >= 3) returned a black high-exposure frame, while an iPhone 13 Pro was fine ([Apple forum 767755](https://developer.apple.com/forums/thread/767755)). Anecdotal, so it argues for small offsets and per-model tests.
- Bayer RAW is not available when digital zoom is applied (a developer reports an exception; L, single blog). Our CaptureKit already uses the wide camera only.
- Our repo's own finding: setting `photoQualityPrioritization` on RAW settings raises NSInvalidArgumentException (CaptureService.swift:144). Apple's Deep Fusion / Smart HDR fusion therefore does not run on the Bayer RAW path. Bayer RAW is one frame, unfused (M: it matches WWDC 2021 session 10160, where ProRAW is the format that can get fusion with `.balanced` or `.quality`; I did not re-read the session this time).
- Halide's Process Zero uses a single-exposure RAW and bypasses Apple's processing ([Lux](https://lux.camera/introducing-process-zero-for-iphone)). It shows the market already considers "single Bayer frame, no Apple fusion" the clean baseline. I found no source for how Halide handles multi-frame RAW.
- Memory: ~12 MB per Bayer 12 MP frame (our AGENTS.md figure). 4 frames x 12 MP x 2 B = ~100 MB raw buffers plus working copies. A 16-frame stack is 200 MB or more before float working buffers (alignment tiles, accumulator at float32 = ~4x). Jetsam limits per device are not published (L). Measure: peak memory and thermal state on iPhone 12 and the newest model, with the camera session running.
- Indigo needs a ZSL ring buffer, which the public API does not expose directly. Third-party apps can only approximate it with a video-rate raw stream, not a bracket (M).

## 3. Open-source burst merge

- HDR+ paper: Hasinoff et al., SIGGRAPH Asia 2016, "Burst photography for high dynamic range and low-light imaging on mobile cameras". Method: select a reference frame, tile-based alignment on a pyramid, robust merge in the frequency domain (Wiener-style), operating on raw. Underexposed frames to protect highlights (H via the paper link in search results).
- Wronski et al. 2019, "Handheld multi-frame super-resolution": kernel regression merge using hand-shake sub-pixel shifts, motion-robust. (M; the search did not return the paper itself.)
- Google's HDR+ dataset: CC BY-SA per the Burst Photo README (H via search summary). That is the dataset, not code.
- Implementations:
  - `martin-marek/hdr-plus-swift` ("Burst Photo", Swift/Metal, macOS, DNG-in DNG-out): **GPL-3.0** (H, LICENSE fetched). It includes Adobe DNG SDK under licence. Copying code into our package would force GPL on the Swift package that MoodRoll ships. Do not copy. Reading it for the algorithm is fine. Reimplementing from the paper is clean.
  - `martin-marek/hdr-plus-pytorch`: MIT (H). Python, research use, not shippable on iOS but good as a reference to compare against.
  - `amonod/hdrplus-python`, `AugustinJose1221/hdr-plus`: community, licences not checked (L). IPOL article 2021/336 documents a full HDR+ re-implementation with code (M).
- No Burst Photo app for iOS found. It is macOS only (H, App Store listing). The "Hasselblad" lead in the brief was not verified.
- AGENTS.md rule 9: any third-party dependency needs a written reason. A GPL dependency would also conflict with the "ships as a Swift package" decision.

## 4. Fuji DR200 / DR400

Facts (H, [JM Peltier](https://www.jmpeltier.com/fujifilm-dynamic-range-settings), [DPReview](https://www.dpreview.com/articles/1294642686/), [Fuji X Weekly](https://fujixweekly.com/2017/10/18/fujifilm-x100f-dynamic-range-settings/)):
- DR200 means 1 stop less exposure, DR400 means 2 stops less, then the processing brightens midtones and compresses highlights with a tone curve. It needs a minimum ISO (250/500 on recent bodies, 400/800 older), because the mechanism is underexposure relative to the displayed ISO.
- DR changes the processed JPEG. Raw files are underexposed but keep full sensor data. Sources disagree about wording (some say overexpose). The consistent view is: capture darker, lift later.
- Downside: shadow noise rises by the same stops, and DR400 in a flat scene looks dull.
Critique of the feedback: "compress exposure range DR200/DR400 before exporting DNG" is wrong in direction. DR is a JPEG-stage tone curve plus an exposure shift. The DNG keeps linear data. Compression before DNG would damage the file we want to keep re-decodable.

Mapping to our pipeline (M):
- It equals ETTR-style underexposure at capture (AVCaptureDevice `setExposureTargetBias`, or a bias in the bracket) plus `baselineExposure` / `exposure` lift in CIRAWFilter and a highlight shoulder in the look stage. Our `highlightRecovery` plugin and `DecisionEngine` already change exposure in small bounded steps.
- The sensor gain at the iPhone's native ISO is fixed per sensor mode. Underexposing 1 stop costs about 1 stop of shadow SNR. Without a merge you pay noise for highlight room. This is why Indigo underexposes and merges together. DR200-style alone, on one frame, is a trade, not a gain.
- Measure: for the test set, DR-style (-1 EV capture, +1 EV in decode) vs normal, on clipped-highlight fraction and shadow noise (chart patch SD), both vs `appleDefault`. Gate 2 limits (black p1 +0.002, halo ring +0.01) apply.

## 5. Does CIRAWFilter expose Apple's local tone map? What is the "smartphone look"?

In this repo (H, read):
- `RawDecoder.swift` lines 150-180 read and write `boostAmount`, `boostShadowAmount`, `localToneMapAmount`, `sharpnessAmount`, `contrastAmount`, `detailAmount`, `moireReductionAmount`, `extendedDynamicRangeAmount`, and NR amounts. LTM is written only `if s.localToneMap` (the support flag: `isLocalToneMapSupported`).
- ROADMAP row 9: LTM and lens correction are reported unsupported for all current test files on macOS 15.8. On device (iOS 26), LTM is supported for ProRAW (15 Pro recipe). Lens correction is still unsupported.
- `RenderSettings.swift` line 143-144: the `linear`-style mode zeroes `boostAmount`, `boostShadowAmount`, `localToneMapAmount`, so a no-Apple-tone path already exists in code.

Interpretation (M):
- For our default input (Bayer DNG), LTM is not supported, so there is nothing to bypass. The remaining Apple "look" is the global tone curve (`boostAmount`), `boostShadowAmount`, and decode sharpening/contrast, which we already set explicitly and log in the recipe (hard rule 1).
- In the HEIC and in ProRAW, Smart HDR / Deep Fusion style fusion and local tone mapping are applied in the camera pipeline. The ProRAW is a fused, pre-demosaiced linear DNG with a semantic-map based tone profile and gain map style metadata ([ShopMoment guide](https://www.shopmoment.com/reviews/how-to-shoot-and-edit-apple-proraw-photos-for-iphone) says fusion is baked in; the WWDC 2021 session 10160 says ProRAW can use fusion with `.balanced` or `.quality`). So if the user wants no fused look, Bayer is the right choice and the roadmap is right. For ProRAW, `localToneMapAmount` and `boostAmount` are the knobs, and a forum answer suggests `boostAmount = 0` ([forum 729751](https://developer.apple.com/forums/thread/729751)).
- The HEIC from the same press is a reference (cameraMatch, histograms) and the fallback. Not a base.
- A PetaPixel piece dated 2026-06-10 reports Core Image RAW "version 9" with better tone-curve and micro-contrast handling (headline only, page returned 403, L). Per AGENTS.md we pin `decoderVersion`, so a new decoder version needs an explicit re-bench against `appleDefault` before adoption.
- The over-sharp, over-smooth part of the "smartphone look" comes from Deep Fusion style fusion and NR in the camera. It is absent from a single-frame Bayer decode, but Apple's decode still applies its sharpness / NR defaults, which we override.

Critique of claim 3: right idea (separate tone and look), wrong target. Our scene-linear CCM via `linearSpaceFilter` already sits before Apple's tone, and looks are applied after. The risk is the opposite one: the Apple tone curve under our look (double tone). The existing Gate 2 and the "looks never repair tone" rule address it.

## 6. Cost and fit for a film-roll app

| Item | Cost | Fit |
|---|---|---|
| 16-32 frame ZSL stack | latency (Indigo itself warns of "more patience"), memory, battery, heat, ghosting on moving subjects (alignment failures) | Bad for a one-press film app. The film ritual wants an immediate shutter. Also not exposed by public AVFoundation as ZSL. |
| 2-4 frame RAW merge, post-press, deferred | 4 x 12 MB per press (4x storage until develop: 36 frames = ~1.7 GB, against our 430 MB figure), merge time at develop | Storage decision (2026-11-09) would need revisiting. Merge could run at develop, not at press, so no extra press latency. Only useful in low light (SNR +3 dB at 4 frames). |
| Motion | ghosting, needs robust merge with a fall-back to the reference frame. Frame-to-frame in a bracket is fast but not instant | Needs a rejection metric measured on moving subjects. |
| DR / underexposure | shadow noise | Cheap, no extra frames. |
| Film grain | n/a | Done in the look stage, independent of capture. |

## 7. Recommendations, ranked (for our case)

1. Keep Bayer single frame + Apple demosaic + explicit parameters + CCM. Do not chase a "bypass". (Already decided, H.)
2. Put the Indigo-style *policy* in `DecisionEngine`, not a burst: lower decode sharpness / NR to a measured level, mild boost, moderate saturation, all logged. Measure: sharpness vs `appleDefault`, halo ring, black p1, noise on flat patches.
3. Capture-side exposure bias (ETTR / "DR200-like"): in bright, high-contrast scenes, bias -0.5 to -1 EV at capture, record the bias in the recipe, lift in decode and shoulder in the look. A plugin or DecisionEngine rule, removable with `plugins = []`. Measure on device: clipped fraction, shadow SD, versus the same scene at 0 EV.
4. Optional plugin `burstMerge` (2-4 equal-exposure Bayer frames via `AVCapturePhotoBracketSettings`), only when the scene median is dark (our dark-scene threshold in DecisionEngine) and the device is steady (gyro). Merge on the mosaic in a reimplementation from the HDR+ paper (tile alignment + robust average, reference-frame fallback), written clean-room (GPL issue). Output a merged DNG with DNG-compatible metadata, so `CIRAWFilter` still decodes it. Open risk: CIRAWFilter needs valid DNG tags for the merged file. Not verified. Measure: SNR gain vs N, ghost artefacts on a moving-subject set, peak memory, wall time, thermal state.
5. Do not ship 16+ frames, ZSL, or super-resolution (needs zoom, which Bayer RAW does not allow).
6. Drop "SuperRAW" from internal docs, unless the user can supply a source.

## Open questions / next measurements

- Device values of `maxBracketedCapturePhotoCount` for Bayer RAW on iPhone 12 to 18 (CaptureKit logging call, cheap).
- Frame interval and total time for a 3-4 frame RAW bracket on-device, with HEIC in the same press.
- Does `CIRAWFilter` accept a merged DNG written by us (needs a spike)?
- Peak memory of a 4-frame float merge in the app with the camera running.
- Licence of `amonod/hdrplus-python` and other forks (not checked), and the Wronski paper reference (not fetched).
- PetaPixel on Core Image RAW v9: page blocked; get Apple's release notes before changing `decoderVersion`.
