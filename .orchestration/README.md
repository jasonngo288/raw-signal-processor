# Orchestration (adapted from MoodRoll's `.orchestration/` + `.claude/agents/`)

The main agent plans and delegates; agent profiles live in `.claude/agents/`. Rules and gates: `AGENTS.md`.

| Request | Agent |
| --- | --- |
| RawCore / raw-bench code | `raw-core-engineer` |
| CaptureKit, demo app | `capture-engineer` |
| Change across ownership, shared contract, gate, review a diff | `pipeline-tech-lead` (read-only) |
| Tests, bench runs, gate numbers | `bench-qa` |
| Research with sources | `pipeline-research` |
| HDR / tone mapping: tone, contrast, black level, highlights, local tone map, curves, glare/halation (design or review) | `tone-mapping-expert` (read-only; uses skill `hdr-tone-mapping`) |

- One file has one writer at a time; cross-ownership work is planned by the tech lead and done in sequence.
- Only the orchestrator edits `AGENTS.md`, `WORK_LOG.md`, `docs/ROADMAP.md`, `Package.swift`, `.github/**`, and regenerates the xcodeproj.
- Done levels: *Built*, *Tested* (`swift test` green), *Benched* (raw-bench numbers), *CI green*, *Seen on device*. Never call a lower level "verified".
- Notes of one topic stay together in `.orchestration/<topic>/` (e.g. `storage/`). Agents return at most 10-15 lines; the orchestrator summarises for the user.
- Project skills live in `.claude/skills/` (`hdr-tone-mapping`: HDR/tone-mapping knowledge mapped to this code; source PDF kept outside the repo).
