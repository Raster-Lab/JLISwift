# JLISwift Roadmap

Living progress tracker — items move from **Remaining** to **Completed** as each
stage lands (CI-green). Each line: **what** · *value* · *risk / how it's validated*.

_Last updated: 2026-05-28 (scaled 1/8 decode)._

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

### Tier 1 — high value, validatable, do next
- [ ] **jpegli perceptual quant tables** · quality / jpegli-parity on 8-bit photographic content · medium risk (λ-tuned trellis interaction); butteraugli-gated — ship only if measurably better, else revert

### Tier 2 — useful, lower value / more niche
- [ ] **1/2 & 1/4 scaled decode** · partial (2×2 / 4×4) IDCT for intermediate preview sizes · moderate (1/8 already covers thumbnails)
- [ ] 16-bit / float32 **input** · accept wider source buffers (down-convert to 12/8-bit) · safe, low value
- [ ] EXIF / ICC **metadata passthrough** · preserve APP1/APP2 across decode→encode · niche for medical (DICOM holds metadata separately)
- [ ] Progressive **+ restart markers** · completeness (restart is baseline-only today) · moderate
- [ ] **Multi-threaded encode** of large plates · parallelize trellis across blocks / Huffman across restart intervals · concurrency risk; must stay bit-identical

### Tier 3 — deferred (high risk / low reward / unvalidatable)
- [ ] XYB color · no jpegli reference available to cross-validate against — high risk of subtly-wrong perceptual color
- [ ] Table-driven Huffman decode · ~2–3 ms · conflicts with the restart decode path (buffered bytes vs byte alignment)
- [ ] Metal hot path · marginal over Accelerate (already AMX/GPU-accelerated GEMM)

### Tier 4 — release (final state)
- [ ] Tag release (Version Bump → Release GitHub Actions; currently `0.1.0`, untagged)
- [ ] DocC API documentation
