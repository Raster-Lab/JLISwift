# JLISwift Roadmap

Living progress tracker — items move from **Remaining** to **Completed** as each
stage lands (CI-green). Each line: **what** · *value* · *risk / how it's validated*.

_Last updated: 2026-05-28 (lossless SOF3 + near-lossless; 1/2 & 1/4 scaled decode; multi-threaded trellis + AC-count; jpegli perceptual quantizer; ICC/Exif metadata; progressive+restart; restartInterval validation; new-path fuzzing). All large/marginal items done — only deferred-risky + release remain._

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

> Honest status (2026-05-28): **every large-effort and marginal/niche item below
> is now done and CI-green** — lossless+near-lossless, jpegli perceptual
> quantizer, 1/2 & 1/4 scaled decode, ICC/Exif metadata, progressive+restart,
> multi-threaded encode. What remains is only the **Deferred** tier (genuinely
> risky / unvalidatable without a reference — best left for a supervised session),
> `float32` *input* (needs an API decision on what range it represents), and
> **Tier 4 release**. The codec is feature-complete; next deliberate step is
> release prep when you're ready.

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
- [x] Progressive **+ restart markers** · `restartInterval` now applies to progressive scans too (was baseline-only) — DRI + RSTn with DC-predictor reset (DC scan) and EOBRUN flush (AC first/refine) at boundaries, mirrored in the optimal-Huffman counting pass; interval counts interleaved MCUs (DC) / data units (AC) to match the decoder (which already handled restart). Validated: restart decode is pixel-identical to no-restart, and djpeg decodes our output (spectral + SA, 4:4:4/4:2:0/gray)
- [x] **Multi-threaded encode** · trellis quantization (~22% of a big encode) **and** optimized-Huffman AC-frequency counting (~9%) are partitioned across cores via `concurrentPerform`: trellis over disjoint block ranges (private scratch), AC counting over a flat block range with summed partial histograms (order-independent → trivially correct). Both **byte-identical** to serial (FNV-checksum verified, serial==parallel==pre-change); DC counting stays serial (cheap, order-dependent chain). ~20% faster on 8 cores for a 2048² plate (100.8→81.0 ms). (Entropy *emit* is still serial — would need per-restart-interval segmentation.)

### Deferred (high risk / low reward / unvalidatable)
- [ ] XYB color · no jpegli reference available to cross-validate against — high risk of subtly-wrong perceptual color
- [ ] Table-driven Huffman decode · ~2–3 ms · conflicts with the restart decode path (buffered bytes vs byte alignment)
- [ ] Metal hot path · marginal over Accelerate (already AMX/GPU-accelerated GEMM)

### Tier 4 — release (final state)
- [ ] Tag release (Version Bump → Release GitHub Actions; currently `0.1.0`, untagged)
- [ ] DocC API documentation
