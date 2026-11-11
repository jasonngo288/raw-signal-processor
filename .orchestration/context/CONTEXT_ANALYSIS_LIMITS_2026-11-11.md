# Context analysis limits: per-pixel masks (sky, skin, foliage, lamps) - research 2026-11-11

Confidence: H = Apple doc / source read, M = consistent secondary sources, L = memory or inference. "UNVERIFIED" = must be tested on device with raw-bench / a capture probe. Web search was thin (no Apple doc pages fetched in full); nothing was downloaded or run.

## 1. Native per-pixel masks

| API | What it gives | Capture-only or on stored file | Cost / availability | Conf |
|---|---|---|---|---|
| VNGeneratePersonSegmentationRequest (already used) | person / not-person | any image, incl. render of DNG | quality levels fast/balanced/accurate; accurate is slowest, run once at capture | H (existing) |
| VNGenerateForegroundInstanceMaskRequest (iOS 17+) | class-agnostic foreground instances (people, pets, objects). No class label. Not sky/skin. | any image (CGImage/CIImage input) | Apple research page: the older lift-subject net runs on ANE, <10 ms on iPhone 14; the iOS 17 Vision request's cost not documented. Forum reports of lower-res/jagged edges in beta (L). | M |
| AVSemanticSegmentationMatte (skin, hair, teeth, glasses) | per-pixel matte, low resolution, for people | capture-time via AVCapturePhotoOutput: `enabledSemanticSegmentationMatteTypes`, read with `photo.semanticSegmentationMatte(for:)`, or embedded as auxiliary image in HEIC/JPEG (`embedsSemanticSegmentationMattesInPhoto`). Readable later from a HEIC via CIImage option `.auxiliarySemanticSegmentationSkinMatte` etc. | only types in `availableSemanticSegmentationMatteTypes`; people only; glasses needs iOS 14.1+. Which iPhone models offer it: UNVERIFIED (WWDC19 s.260 era; probably any portrait-capable device, not only Pro). | M |
| Sky matte (`auxiliarySemanticSegmentationSkyMatte`, `semanticSegmentationSkyMatteImage`) | sky matte exists as a CoreImage/ImageIO key | Not in `AVSemanticSegmentationMatte.MatteType` (only hair/skin/teeth/glasses). A forum poster could not obtain it from AVCapturePhotoOutput; reply "needs private libraries" is secondhand. It appears only in files made by Apple's Camera app (L). | Not usable as a public capture API. Treat sky as NOT available natively. | M (forum, unanswered by Apple) |
| Portrait effects matte / depth (`AVPortraitEffectsMatte`, depth data) | person matte, depth map | capture-time only (needs depth-capable camera config; LiDAR/dual cam) | Not compatible with a plain Bayer RAW press assumption: UNVERIFIED whether depth/mattes can be delivered in the same capture as `rawPhotoPixelFormatType`. | L |
| Core ML models from Apple gallery | DeepLabV3 (PASCAL VOC 21 classes: has person, plant (potted only), no sky) and others | any image | Apple gallery models: no sky class in VOC. Licence per model card, check. | M |

RAW/DNG question: I found no evidence that mattes are written into the DNG. Mattes are auxiliary images of HEIC/JPEG. In a RAW+HEIC press the matte, if offered at all, would come from the processed HEIC photo (`AVCapturePhoto` callback for the processed format) and would have to be stored by us next to the DNG. UNVERIFIED; one probe on 12 / 15 Pro / 17 settles it (see section 5).

Sources:
- Sky matte forum thread: https://developer.apple.com/forums/thread/735020
- Matte types write-up (glasses iOS 14.1): https://zenn.dev/paraches/articles/switch-ssmtype-error
- AVSemanticSegmentationMatte: https://developer.apple.com/documentation/avfoundation/avsemanticsegmentationmatte
- WWDC19 s.260 (capture of mattes): https://developer.apple.com/videos/play/wwdc2019/260/
- WWDC23 s.10176 lift subjects: https://wwdcnotes.com/notes/wwdc23/10176
- Apple salient object research (ANE, <10 ms iPhone 14): https://machinelearning.apple.com/research/salient-object-segmentation
- VNGenerateForegroundInstanceMaskRequest: https://developer.apple.com/documentation/vision/vngenerateforegroundinstancemaskrequest

## 2. Fallback models and heuristics

Licence rule: MIT / Apache only. Check the licence file in the original repo, not the mirror.

| Candidate | Classes | Licence (as found) | Size / speed | Verdict |
|---|---|---|---|---|
| skyseg.onnx (U2-Net small, sky only; repo xiongzhu666/Sky-Segmentation-and-Post-processing; HF JianyuanWang/skyseg; wrapper github.com/Parskatt/skyseg) | sky | MIT per HF listing (M, mirror; verify in origin repo) | size/speed not found (U2-Net small is typically few MB, L). Core ML conversion not published; convert with coremltools (op support UNVERIFIED). | First candidate if a model is wanted. |
| SkyWater-Seg (SegFormer MiT-B2, sky/water/person; HF Realcat/skywater_seg) | sky, water, person | MIT per HF page (M) | 24.7M params, heavier | Gives water too; B2 likely 100+ ms on device (L, measure). Second candidate. |
| SegFormer-B0 ADE20K (nvidia/segformer-b0-finetuned-ade-512-512) | 150 ADE classes incl. sky, tree, grass, water, plant, person | HF card says "other" -> NVIDIA SegFormer repo licence. Sources disagree: one says non-commercial, Qualcomm says Apache-2.0. | ~3.7M params (L) | FLAG: NVIDIA licence is known to restrict commercial use (L); do not use until read in the NVlabs repo. |
| DeepLabV3 (Apple gallery / MobileViT-DeepLabV3 on HF Apple org) | VOC 21 | gallery: check card; MobileViT HF says "other" | small | No sky class. Not useful. |
| Qualcomm AI Hub DeepLabV3-ResNet50 | VOC | BSD-3 source, separate deployable licence | big | No. |
| Train own tiny sky/foliage model on ADE20K | n/a | ADE20K data licence is research/non-commercial (L) | n/a | Avoid. |

Sources: https://huggingface.co/JianyuanWang/skyseg/tree/main , https://github.com/Parskatt/skyseg , https://huggingface.co/Realcat/skywater_seg , https://huggingface.co/nvidia/segformer-b0-finetuned-ade-512-512 , https://huggingface.co/collections/apple/core-ml-gallery-models-666b66ca4e6657b7d179bc42 , https://apple.github.io/coremltools/docs-guides/source/convert-a-pytorch-segmentation-model.html

Pure-Swift heuristic sky mask (no model, no licence issue; accuracy UNVERIFIED, must be benched):
1. On the 512 px scene-linear thumbnail (already computed): per pixel score = blue-dominance in OKLab (hue band, chroma > c0) OR (very low chroma + high luma for overcast), AND low local gradient (texture proxy: 5x5 variance of luma < t).
2. Keep only connected components that touch the top border (or the top 1/3) and have area > 3 %; reject components that sit below a strong horizontal edge on a person/face bbox.
3. Refine with a guided filter (luma guide, r ~ 8, eps small) at 512 px; feather. Pure Swift, vDSP; expect a few ms (L).
4. Known failure: blue walls/water/clothes touching the top edge, sky behind foliage, sunset with no blue, ceilings. The top-connected + texture test fixes the "blue object mid-frame" and "shade whites" cases, which is exactly the skyHold complaint. Vision `VNClassifyImageRequest` labels (sky, outdoor) can gate the whole mask (frame-level prior: only apply when label confidence for sky/outdoor > x). The classifier is already run.

## 3. Skin-only mask

- Matte route: `AVSemanticSegmentationMatte` skin is real skin segmentation but low-res, people only, capture-time, availability per model UNVERIFIED. Cheap to store if available (small image next to DNG).
- Colour-in-person-mask route (works on a stored DNG, any model): inside the person mask (existing, accurate) AND OKLab hue in skin band (roughly 30-70 degrees hue angle, chroma 0.04-0.14, L 0.3-0.9; values L, tune on corpus) AND optionally face-rect-weighted prior (histogram of the face rect's chroma gives a per-image skin centroid, then distance in a*b). This excludes hair, clothes, background-through-mask. Pure Swift. Weak on: red/orange clothes, very dark or very light skin under coloured light (use the face-rect centroid adaptation to cover this).
- Recommended: colour-in-person-mask with face-sampled centroid; use the matte only as an optional refinement if the probe shows it is delivered with the RAW press.

## 4. Lamp / light-source detection (halation)

No Apple API. Pure Swift on scene-linear thumbnail: threshold on scene-linear luma near clipping (e.g. > 0.9 of saturation or > p99.9 and > some absolute EV over median), connected components, area small (< 2 % of frame) and compact, high local contrast vs neighbours (luma ratio to a blurred ring > 4). Colour is irrelevant (lamps are white/orange). Exclude sky (sun) with the sky mask or keep it (sun halation is wanted; make it a flag). Use the DNG scene-linear data rather than the HEIC, since the HEIC clips earlier. The existing "display clipping" and "p99.9" stats are the global version of this; a mask is just the same threshold kept per pixel with blob filtering. Reference idea: halation model = blur of masked highlight, red-biased, added back; the mask can be soft (smoothstep over scene-linear luma) so no blob detection is strictly needed. Cost: negligible (L).

## 5. Recommendation (value / cost)

1. **Heuristic sky mask (pure Swift) + classifier gate.** Value: fixes the stated skyHold artefact (blue shade whites, blue objects); cost: low, no licence, no model. Build first. Bench: fraction of pixels held vs hand-labelled sky on the corpus (10-20 frames labelled by user), plus a regression check that non-sky pixels have 0 hold.
2. **Soft lamp mask (scene-linear threshold) for halation.** Lowest cost, same code style, uses data HEIC does not have.
3. **Skin = colour in person mask with face-sampled centroid.** Low cost; replaces whole-person `skinProtection` weighting.
4. **Probe capture-time mattes** (skin, hair; `availableSemanticSegmentationMatteTypes` on each device with `rawPhotoPixelFormatType` set, and with RAW+HEIC). One-day probe in the demo app on iPhone 12 and a recent Pro; log availability, matte size, whether the HEIC companion carries it. Only then decide to store it.
5. **Model-based sky/foliage (skyseg U2-Net or SkyWater-Seg to Core ML)** only if the heuristic's benched error is too high. Needs conversion test, licence read in origin repo, on-device timing with camera running (AGENTS: analysis cost must be measured with the camera running).
6. Skip: foreground instance mask (no class), Apple gallery DeepLabV3 (no sky), SegFormer-B0 until licence confirmed.

### Store in capture-time analysis (self-contained, per AGENTS)
- Masks at 256 px or 512 px, 8-bit PNG/R8 next to the DNG: `sky`, `skin`, `lamp` (soft), existing `person`. About 30-130 KB each (L).
- Per mask: algorithm id + version, thresholds, thumbnail size, coverage fraction (%), decoder version/plugin set (existing). Re-run at develop if the mask algorithm version differs.
- Optional if probe passes: raw matte images from AVCapture.

### Plug into DecisionEngine (bounded, logged)
- Inputs become mask coverage fractions, not new tone controls: `skyCoverage`, `skinCoverage`, `lampCoverage`.
- skyHold: replace colour-only `skyWeight(c)` with `skyWeight(c) * skyMask(x,y)` (mask applied in the look cube stage via a per-pixel blend between the held and the full look, outside the cube since cubes are colour-only). Bounded: blend weight in 0...1, held look is the same look with skyHold params; no new parameters outside existing ranges.
- Skin: `skinProtection` = existing 0.5 cap times skin mask; the person mask stays as the gate.
- Halation: amount = base * min(1, lampCoverage / x); radius from image short edge; clamp amount to an upper bound (set in RenderSettings validation).
- Recipe lines (examples): `sky mask v1: coverage 0.31, hold applied to 0.31 of pixels (colour-only would have held 0.44)`; `skin mask v1: 0.04 of frame, protection 0.5 only there`; `lamp mask v1: 3 blobs, 0.2 % area, halation 0.35`. When a mask is missing or coverage < 1 %, log `mask skipped: <reason>` and fall back to colour-only (never silently).
- Plugin rule: if these masks are not in ROADMAP, ship as a `DevelopPlugin` removable with `plugins = []`, listed in EXTRAS; bench runs `auto` and `auto core`.

### Measure with raw-bench / device before it counts
- Sky mask IoU vs labelled corpus frames; held-pixel diff vs current colour-only skyHold; black p1, halo ring, local contrast per Gate 2.
- Heuristic runtime on device (thumbnail) while the camera runs; model runtime if section 5 item 5 happens.
- Matte probe result (availability by model, size, delivered with RAW press or not).
- Core ML conversion success and ANE vs GPU placement for any chosen model.

### Open questions
- Does a sky or skin matte arrive at all with Bayer RAW / ProRAW capture, and per which iPhone? (UNVERIFIED)
- True licence of skyseg weights and of SkyWater-Seg training data (HF listing says MIT; origin repo not read).
- NVIDIA SegFormer licence text (not read).
