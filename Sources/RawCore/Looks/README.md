# Bundled looks

Declared LUT files: `<name>.cube` plus `<name>.manifest.json`, checked by `LookContract` (`raw-bench lutcheck`).
Only files that pass load as stocks.

The 6 LUTs the user added on 2026-11-10 are **not committed**. All 6 failed the contract: sha256 mismatch, route
issues, GPL / CC-BY-SA licences and trademark names (`.orchestration/looks/LUT_INTAKE_2026-11-10.md`). They stay
local only. This README keeps the resource folder in git, so `Package.swift`'s `.copy("Looks")` builds on a clean
checkout.
