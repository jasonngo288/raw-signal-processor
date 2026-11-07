# Public RAW test corpus

`corpus.json` lists public RAW files by scene category, following `RAW_TEST_CORPUS.md` (2026-11-05).
CI downloads them with `scripts/fetch_corpus.py` into `corpus-cache/` (cached, **never committed**) and
benches them together with `originals/`.

Rules carried over from the corpus plan:
- Split **by scene**: `tuning` files may guide DecisionEngine thresholds; `holdout` files are only reported.
  Do not change rules because of a holdout result and then report it as a new test.
- Keep provenance honest: DNGs converted by someone else are marked DERIVED; the tavern NEFs are a
  *proxy* for "restaurant at night", not the real case. Do not relabel scenes.
- CC-BY-NC files (Branscombe Beach) and research-only sets (MIT-Adobe FiveK) are excluded.
- Native NEF/ARW/RW2 are decoded directly by CIRAWFilter (Apple's camera support list), unlike the earlier
  custom core. An unsupported file is reported in the bench summary, not hidden.

Coverage against the 36 target cases (6 categories × 6 conditions): see the WORK_LOG entry of 2026-11-07.
The main gap remains iPhone Bayer DNGs captured by the app itself for each category.
