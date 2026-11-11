# Storage between capture and develop (2026-11-09)

Question (user): a roll keeps Bayer DNG + HEIC per frame until the whole roll develops. HEIC is small and can stay.
Can the DNG go to Core Data, or be decoded and deleted right after capture, so develop no longer needs it?

## Short answer
- **Core Data / SwiftData does not save space.** External storage only moves the same bytes next to the store
  (no compression), and adds migration and faulting cost. Keep media as files, paths in the database.
- **The analysis alone is not enough to develop.** It is statistics (KB); develop needs pixels. Deleting the DNG
  means storing a decoded **base render** (decode + DecisionEngine + plugins.afterDecode, no look) and running only
  look → skin protection → finish → export at develop time. That split matches the pipeline: the look already works
  on the display-referred base.
- **Lossless intermediates are 2–9× larger than the DNG.** Only HEIC 10-bit makes it smaller.
- **Bayer DNG is already losslessly compressed** (TIFF compression 7) and AVFoundation has no option to make it
  smaller. Bit depth / lossy / JPEG-XL options exist for ProRAW only (`rawFileFormat`, iOS 18+).

## Measured (`raw-bench storage`, macOS 15.2 encoders, full resolution, stock slide100)
"final" = look + halation → JPEG 8-bit as MoodRoll ships, stored base vs in-memory base (grain off: seeded, same on both).

| file | DNG | heic10 q0.92 | final ΔE00 mean / p95 | EXR half (lossless) | PNG16 | TIFF16 LZW |
|---|---|---|---|---|---|---|
| 14 Pro Bayer (docs capture) | 10.4 MB | 7.1 MB (68 %) | 0.44 / 1.50 | 43.7 MB | 71.2 MB | 99.6 MB |
| 15 Pro ProRAW (docs capture) | 17.3 MB | 5.3 MB (31 %) | 0.43 / 1.47 | 37.8 MB | 65.3 MB | 77.1 MB |
| IMG_1901 (stage, Bayer) | 16.4 MB | 5.7 MB (35 %) | 0.49 / 1.73 | 34.3 MB | 61.6 MB | 84.7 MB |
| USER_mooncake (Bayer) | 10.4 MB | 7.3 MB (70 %) | 0.44 / 1.51 | 44.9 MB | 70.8 MB | 98.4 MB |

- The final JPEG alone costs ≈ 0.10 ΔE00 (the PNG16 path); HEIC10 q0.92 adds ≈ 0.33 mean, p95 stays < 2.
- heic10 q1.0 is not lossless (final 0.38–0.46) and 1.6–1.8× bigger than q0.92: no reason to use it.
- Encode time 0.3–1.0 s per frame on the Mac (HEIC10).

## What each option costs per frame (Bayer default, HEIC kept as the user wants)
| option | per frame | 36-frame roll | loses |
|---|---|---|---|
| A. keep DNG until develop (today) | 10.4 + 1.6 = 12.0 MB | ≈ 430 MB | nothing; re-decode possible |
| B. base HEIC10 at capture, delete DNG | 7.1 + 1.6 = 8.7 MB (−28 %) | ≈ 310 MB | re-decode (new CCM, decoder, rules); ≈ 0.4 ΔE00 |
| B on ProRAW | 5.3 + 1.6 = 6.9 MB vs 18.9 (−63 %) | ≈ 250 MB vs 680 MB | same |

Option B also moves the full-resolution decode (and an encode) to capture time, with the camera running, on top of
the ≈ 2.5 s analysis: thermal and GPU contention with the viewfinder, not measured yet.

## Decision (user, 2026-11-09): keep the DNG until develop (Bayer). ProRAW still open.

## Recommendation (as given)
1. **Bayer (default): keep the DNG until develop** in Application Support (not Caches/tmp, which iOS purges),
   `isExcludedFromBackup` on the roll folder, check free space for the whole roll before it starts. Option B saves
   only ≈ 28 % and gives up re-decoding — which matters here, because the CCM table is still empty (Gate 3): frames
   shot before calibration could never get it.
2. **ProRAW: option B is worth it** (−63 %), or first test JPEG-XL lossless ProRAW capture (iOS 18+, smaller DNG,
   still a DNG for CIRAWFilter).
3. The pipeline split (stage A base / stage B look) is useful either way: it lets a stored base be re-looked with
   another stock without decoding again.

## Not verified
iOS hardware HEVC encoder vs macOS (sizes and ΔE may differ); banding in smooth gradients after a contrasty look
(only ΔE measured); one stock only; EXR write on iOS; JPEG-XL ProRAW decode with every parameter we set.

Sources (research agent): developer.apple.com "Capturing photos in RAW and Apple ProRAW formats";
support.apple.com/119916 (ProRAW sizes); WWDC21 10160; Core Data `allowsExternalBinaryDataStorage`;
"Optimizing your app's data for iCloud backup"; "Using the file system effectively".
