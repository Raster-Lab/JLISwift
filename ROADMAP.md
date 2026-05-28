# JLISwift Roadmap

Living progress tracker — items move from **Remaining** to **Completed** as each
stage lands (CI-green). Each line: **what** · *value* · *risk / how it's validated*.

_Last updated: 2026-05-28 (lossless SOF3 grayscale decode)._

## Completed

### Foundation (prior sessions)
- [x] Baseline (SOF0) + extended-sequential (SOF1, 12-bit) decode & encode
- [x] Progressive (SOF2) **decode** — DC/AC first+refine, EOBRUN, successive approximation
- [x] Optimized per-image Huffman, trellis quantization, distance parameter
- [x] 12-bit **grayscale** encode & decode
- [x] DICOM corpus loader + self/cross-codec + butteraugli + JSON regression bench

### This milestone (2026-05-28)
- [x] Progressive (SOF2) **encode** — spectral selection (default) + successive approximation
- [x] CI / release-prep — Swift 6.2 / Xcode 26, Apple-only (Linux dropped), docs corrected
- [x] Decoder **fuzz-hardening** — throws (never traps) on malformed input; fixed 5 crash classes
- [x] Extended fuzzing — 8/12-bit grayscale decode paths + encoder edge-case matrix
- [x] 12-bit **color** encode & decode — cross-validated vs libjpeg-turbo-12
- [x] **BitWriter** perf — batched 64-bit accumulator, ~14% faster encode (bit-identical)
- [x] Restart-marker (DRI/RST) **encoding** + permanent cross-codec coverage
- [x] **Scaled decode — 1/8 DC-only thumbnails** (gray + color, 8/12-bit) — `config.scale = 8`; validated vs full-decode block averages

## Remaining

> Honest status: the easy, high-confidence wins are done. What's left is either a
> **large effort** (its own mini-project) or **marginal/niche/risky**. Pick
> deliberately — or proceed to release.

### Large efforts (high value, but multi-stage)
- **Lossless JPEG (SOF3)** · true lossless for medical archival (often a hard requirement) — a separate predictive coding mode (no DCT/quant)
  - [x] grayscale **decode** (predictors 1–7) — bit-exact vs libjpeg-turbo lossless fixtures
  - [ ] grayscale **encode** (predictor + lossless Huffman) — round-trip + djpeg cross-validate
  - [ ] color (RGB/YCbCr, no subsampling) decode + encode
- [ ] **jpegli-style quantizer** · quality / jpegli-parity · large — jpegli computes tables from a perceptual model per distance (not a matrix swap); butteraugli-gated, uncertain payoff without XYB

### Marginal / niche (safe, bounded, lower value)
- [ ] **1/2 & 1/4 scaled decode** · either fiddly (partial 2×2/4×4 IDCT, real speedup; validate vs `djpeg -scale`) or trivial-but-no-IDCT-speedup (full IDCT + box-downsample) · 1/8 already covers thumbnails
- [ ] 16-bit / float32 **input** · accept wider source buffers (down-convert) · safe, low value (callers can pre-scale)
- [ ] EXIF / ICC **metadata passthrough** · preserve APP1/APP2 across decode→encode · API addition; niche for medical (DICOM holds metadata)
- [ ] Progressive **+ restart markers** · completeness (restart is baseline-only) · moderate, niche
- [ ] **Multi-threaded encode** of large plates · parallelize trellis / Huffman-per-restart-interval · concurrency risk; must stay bit-identical

### Deferred (high risk / low reward / unvalidatable)
- [ ] XYB color · no jpegli reference available to cross-validate against — high risk of subtly-wrong perceptual color
- [ ] Table-driven Huffman decode · ~2–3 ms · conflicts with the restart decode path (buffered bytes vs byte alignment)
- [ ] Metal hot path · marginal over Accelerate (already AMX/GPU-accelerated GEMM)

### Tier 4 — release (final state)
- [ ] Tag release (Version Bump → Release GitHub Actions; currently `0.1.0`, untagged)
- [ ] DocC API documentation
