# JLISwift Roadmap

Living progress tracker — items move from **Remaining** to **Completed** as each
stage lands (CI-green). Each line: **what** · *value* · *risk / how it's validated*.

_Last updated: 2026-05-28 (lossless SOF3 + near-lossless; 1/2 & 1/4 scaled decode; multi-threaded trellis; jpegli perceptual quantizer; ICC/Exif metadata)._

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

### Completed large efforts
- [x] **Lossless JPEG (SOF3)** — true lossless (predictive, no DCT/quant), the medical-archival item
  - grayscale + RGB color (stored direct, Adobe APP14 transform=0), predictors 1–7
  - **8 / 12 / 16-bit precision** (`losslessPrecision`; 16-bit for 16-bit medical sources)
  - **near-lossless** via point transform (`losslessPointTransform`; bounded error 2^Pt−1, smaller files)
  - bit-exact (and bounded-exact for near-lossless), cross-validated vs libjpeg-turbo both directions (we read theirs; djpeg reads ours)

### Large efforts (high value, but multi-stage)
- [x] **jpegli-style quantizer** · `perceptualQuantTables` (opt-in, 8-bit YCbCr) — faithful port of libjxl jpegli's perceptual model: per-coefficient base matrices + non-linear distance scaling (`DistanceToScale`), not a matrix swap. **Validated** (butteraugli, out-of-band): distance calibration tracks target (d=1.0→ba≈1.19, d=1.9→ba≈1.86); better quality-per-byte at high-quality 4:4:4, mixed at low quality / 4:2:0 — the "uncertain payoff without XYB" prediction, now quantified. Default stays Annex-K; 12-bit/lossless unaffected.

### Marginal / niche (safe, bounded, lower value)
- [x] **1/2 & 1/4 scaled decode** · `config.scale = 2/4` — each output sample is the *exact* mean of its scale×scale box, formed straight from the dequantized coefficients via a separable `A·F·Aᵀ` contraction (no full IDCT, so faster). Validated == box-average of the full decode (gray/color, 8/12-bit) and within ≤6 of `djpeg -scale` (embedded CI-safe fixtures)
- [x] 16-bit **input** (via lossless `losslessPrecision`) · float32 input still TODO (DCT modes stay 8/12-bit)
- [x] EXIF / ICC **metadata** · `JLIImage.iccProfile` / `.exif` — decode extracts (APP2 `ICC_PROFILE` reassembled across segments, APP1 `Exif`), encode embeds (ICC chunked into ≤65519-byte APP2 segments) on baseline/progressive/lossless. Bit-exact round-trip; cross-validated both ways vs libjpeg-turbo (we read cjpeg's ICC; `djpeg -icc` extracts ours byte-exact, incl. a 140 KB multi-segment profile)
- [ ] Progressive **+ restart markers** · completeness (restart is baseline-only) · moderate, niche
- [x] **Multi-threaded encode** · trellis quantization (the largest parallelizable stage, ~22% of a big encode) is partitioned across cores via `concurrentPerform` over disjoint block ranges, each worker with private scratch — **byte-identical** to serial (verified by FNV checksum), ~15% faster on 8 cores for a 2048² plate. (Huffman-per-restart-interval emit not parallelized — separate, smaller win.)

### Deferred (high risk / low reward / unvalidatable)
- [ ] XYB color · no jpegli reference available to cross-validate against — high risk of subtly-wrong perceptual color
- [ ] Table-driven Huffman decode · ~2–3 ms · conflicts with the restart decode path (buffered bytes vs byte alignment)
- [ ] Metal hot path · marginal over Accelerate (already AMX/GPU-accelerated GEMM)

### Tier 4 — release (final state)
- [ ] Tag release (Version Bump → Release GitHub Actions; currently `0.1.0`, untagged)
- [ ] DocC API documentation
