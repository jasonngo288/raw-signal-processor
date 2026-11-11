# LUT intake check — 6 files in Sources/RawCore/Looks (2026-11-10)

Checked with `raw-bench lutcheck` (LookContract: required fields, sha256 of the file bytes, supported route, licence /
trademark release blockers) plus a numeric look at each cube. **Result: 0 of 6 usable; none is loaded as a stock.**

```
FAIL polut_vision3_250d  route: —
       ✗ sha256 mismatch: manifest 81726a43d9b0…, file ebbb9d3aabd0…
       ✗ log curve cineon (assumed cineon_log) is not one of appleLog, sLog3, logC3, vLog
       ⚠︎ release: licence GPL-3.0 is not on the allow-list (Apache-2.0, BSD-2-Clause, BSD-3-Clause, CC0, CC0-1.0, MIT, own-work)
FAIL rawtherapee_velvia_50  route: —
       ✗ sha256 mismatch: manifest d4e5f67a8b9c…, file 229c54cebaa6…
       ✗ route displayToDisplay is not supported here (display, sceneToDisplay)
       ⚠︎ release: name rawtherapee_velvia_50 contains the trademark word "velvia"
FAIL spectral_gold_200  route: —
       ✗ sha256 mismatch: manifest 9f8e43b1c67d…, file 667fe75b9985…
       ✗ route sceneToDisplay is implemented for log-encoded input only, got input transfer linear
       ⚠︎ release: name spectral_gold_200 contains the trademark word "gold"
FAIL spectral_trix_400  route: —
       ✗ sha256 mismatch: manifest 7f9a1b3c5e7d…, file 874156f6968f…
       ✗ route sceneToDisplay is implemented for log-encoded input only, got input transfer linear
       ⚠︎ release: name spectral_trix_400 contains the trademark word "trix"
FAIL spektra_portra_400  route: —
       ✗ sha256 mismatch: manifest 3a7b92df801c…, file 9bc6f30a97c9…
       ✗ route sceneToDisplay is implemented for log-encoded input only, got input transfer linear
       ⚠︎ release: licence CC-BY-SA-4.0 is not on the allow-list (Apache-2.0, BSD-2-Clause, BSD-3-Clause, CC0, CC0-1.0, MIT, own-work)
       ⚠︎ release: name spektra_portra_400 contains the trademark word "portra"
FAIL spektra_vision3_500t  route: —
       ✗ sha256 mismatch: manifest e2b4c6d8f01a…, file ec748e391b46…
       ✗ log curve vision3_log (assumed kodakLogD) is not one of appleLog, sLog3, logC3, vLog
       ⚠︎ release: licence CC-BY-SA-4.0 is not on the allow-list (Apache-2.0, BSD-2-Clause, BSD-3-Clause, CC0, CC0-1.0, MIT, own-work)
6 manifests, 0 usable, 6 rejected
```

## What the numbers in the files say (neutral ramp in → out, 33³, all with DOMAIN 0…1)
| file | grey 0 / 0.5 / 1 | observation |
|---|---|---|
| polut_vision3_250d | 0 / 0.50 / (1, 1, 0.94) | grey 0.5 → 0.5: behaves like a display-referred grade, not a Cineon-log print LUT as declared |
| rawtherapee_velvia_50 | 0 / 0.44 / 1 | largest neighbour step 0.185 (others 0.01–0.12): rough grid, banding risk |
| spectral_gold_200 | (0.011, 0.004, 0) / (0.55, 0.50, 0.45) / (1, 0.99, 0.92) | declared linear-sRGB scene input, but 0.25 → 0.26: not a linear-input transform |
| spectral_trix_400 | 0 / 0.48 / 1, r = g = b everywhere | mono as declared; declared linear input contradicted the same way |
| spektra_portra_400 | 0 / 0.50 / 1 | near-identity on grey; declared linear input contradicted |
| spektra_vision3_500t | (0, 0.02, 0.06) / (0.55, 0.49, 0.53) / 1 | magenta-cyan cast on grey; declared "vision3_log" curve does not exist in any tool here |

## Provenance concerns (for the user)
- All six `sha256` fields are wrong, and some look made up (e.g. `…0a1b2c` sequences). The cubes carry a common
  header "# Spectral Film LUT Collection" with Vietnamese category labels and version strings (e.g. "v2.4.1-tungsten-spec",
  "datasheet-rev-4a8e") that the research note did not find upstream. Before any of them is trusted, regenerate each
  file from its named generator at a pinned commit and record the real hash.
- Licences: PoLUT GPL-3.0 and Spektrafilm CC-BY-SA-4.0 are copyleft (not on the allow-list); RawTherapee's collection
  rights were "to inspect" in the research, here declared CC0 without a source text.
- Names contain trademarks (gold, trix, portra, velvia, vision3) — fine as file ids, not as user-facing names.

The SHA values were NOT edited to match: that would erase the provenance gap the contract is there to catch.
