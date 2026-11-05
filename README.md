# raw-signal-processor

RAW "film development" engine for an iPhone camera app, built on Apple's **Core Image `CIRAWFilter`**
(pinned decoder, explicit parameters, recipe per render), Vision context analysis and Core Image looks.

- Rules and architecture: [AGENTS.md](AGENTS.md)
- Plan and gates: [docs/PLANNING.md](docs/PLANNING.md)
- Metrics: [docs/METRICS.md](docs/METRICS.md)
- History and evidence: [WORK_LOG.md](WORK_LOG.md)

```
swift build -c release && swift test
.build/release/raw-bench bench originals --out bench-out --full
```
CI (macos-15) runs the bench on `originals/` and posts `summary.md` to the job summary; the
`bench-out` artifact holds JPEG previews, full-res HEIC10 and recipes.
