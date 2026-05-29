# JLISwift Roadmap

Living progress tracker — items move from **Remaining** to **Completed** as each
stage lands (CI-green). Each line: **what** · *value* · *risk / how it's validated*.

_Last updated: 2026-05-29 (table-driven 8-bit-lookahead Huffman decode — ~15–19% faster decode on entropy-heavy content, bit-identical, A/B-proven; float32 input; DocC overview rewrite; adaptive-quant field `adaptiveQuantField`, opt-in — ~5–8% butteraugli win on 4:4:4; XYB color implemented end-to-end & validated — transform + CoreGraphics-validated ICC + encode/decode; experimental/opt-in, honest caveats below). Earlier 2026-05-28: lossless+near-lossless, scaled decode, multi-threaded trellis+AC-count, jpegli quantizer, ICC/Exif, progressive+restart, fuzzing._

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

> Honest status (2026-05-29): **every large-effort, marginal/niche, and
> formerly-deferred item below is now done and CI-green** — lossless+near-lossless,
> jpegli perceptual quantizer, 1/2 & 1/4 scaled decode, ICC/Exif metadata,
> progressive+restart, multi-threaded encode, float32 input, XYB color
> (experimental), and now **table-driven 8-bit-lookahead Huffman decode**. The
> only non-release item left is the **Metal hot path** — and that stays deferred
> on purpose: it's marginal over the Accelerate AMX/GPU GEMM and can't be
> validated bit-exactly. The codec is feature-complete; the next deliberate step
> is **Tier 4 release** prep when you're ready.

### Completed large efforts
- [x] **Lossless JPEG (SOF3)** — true lossless (predictive, no DCT/quant), the medical-archival item
  - grayscale + RGB color (stored direct, Adobe APP14 transform=0), predictors 1–7
  - **8 / 12 / 16-bit precision** (`losslessPrecision`; 16-bit for 16-bit medical sources)
  - **near-lossless** via point transform (`losslessPointTransform`; bounded error 2^Pt−1, smaller files)
  - bit-exact (and bounded-exact for near-lossless), cross-validated vs libjpeg-turbo both directions (we read theirs; djpeg reads ours)

### Large efforts (high value, but multi-stage)
- [x] **Adaptive quantization field** · `adaptiveQuantField` (opt-in, default off) — spatially varies the trellis RDO λ per 8×8 **luma** block by a visual-masking proxy (block AC energy): busy/masked blocks quantized harder, smooth blocks (banding-prone) preserved. **Validated** (butteraugli): ~5–8% lower distance at matched bytes on detailed **4:4:4** content; slightly *worse* on 4:2:0 at low quality (chroma loss dominates), hence opt-in. (Full jpegli parity would need its ~560-line psychovisual field + per-block zero-bias application — much larger; this captures the core lever decodably with a single quant table.)
- [x] **jpegli-style quantizer** · `perceptualQuantTables` (opt-in, 8-bit YCbCr) — faithful port of libjxl jpegli's perceptual model: per-coefficient base matrices + non-linear distance scaling (`DistanceToScale`), not a matrix swap. **Validated** (butteraugli, out-of-band): distance calibration tracks target (d=1.0→ba≈1.19, d=1.9→ba≈1.86); better quality-per-byte at high-quality 4:4:4, mixed at low quality / 4:2:0 — the "uncertain payoff without XYB" prediction, now quantified. Default stays Annex-K; 12-bit/lossless unaffected.

### Marginal / niche (safe, bounded, lower value)
- [x] **1/2 & 1/4 scaled decode** · `config.scale = 2/4` — each output sample is the *exact* mean of its scale×scale box, formed straight from the dequantized coefficients via a separable `A·F·Aᵀ` contraction (no full IDCT, so faster). Validated == box-average of the full decode (gray/color, 8/12-bit) and within ≤6 of `djpeg -scale` (embedded CI-safe fixtures)
- [x] 16-bit **input** (via lossless `losslessPrecision`) · **float32 input** done — treated as normalised [0,1], clamped + quantised to 8-bit up front, then the normal path (use `.uint16` for 12-bit). Encodes identically to the equivalent 8-bit image (validated).
- [x] EXIF / ICC **metadata** · `JLIImage.iccProfile` / `.exif` — decode extracts (APP2 `ICC_PROFILE` reassembled across segments, APP1 `Exif`), encode embeds (ICC chunked into ≤65519-byte APP2 segments) on baseline/progressive/lossless. Bit-exact round-trip; cross-validated both ways vs libjpeg-turbo (we read cjpeg's ICC; `djpeg -icc` extracts ours byte-exact, incl. a 140 KB multi-segment profile)
- [x] Progressive **+ restart markers** · `restartInterval` now applies to progressive scans too (was baseline-only) — DRI + RSTn with DC-predictor reset (DC scan) and EOBRUN flush (AC first/refine) at boundaries, mirrored in the optimal-Huffman counting pass; interval counts interleaved MCUs (DC) / data units (AC) to match the decoder (which already handled restart). Validated: restart decode is pixel-identical to no-restart, and djpeg decodes our output (spectral + SA, 4:4:4/4:2:0/gray)
- [x] **Multi-threaded encode** · trellis quantization (~22% of a big encode) **and** optimized-Huffman AC-frequency counting (~9%) are partitioned across cores via `concurrentPerform`: trellis over disjoint block ranges (private scratch), AC counting over a flat block range with summed partial histograms (order-independent → trivially correct). Both **byte-identical** to serial (FNV-checksum verified, serial==parallel==pre-change); DC counting stays serial (cheap, order-dependent chain). ~20% faster on 8 cores for a 2048² plate (100.8→81.0 ms). (Entropy *emit* is still serial — would need per-restart-interval segmentation.)

### Formerly deferred — now addressed
- [x] XYB color · **implemented & validated end-to-end (experimental).** (1) Correct XYB transform (faithful libjxl opsin port), round-trips <0.5/255. (2) XYB **ICC generator** (libjxl `MaybeCreateProfileImpl` port: mAB tag w/ 2×2×2 CLUT + cube-root curves + matrix) — `CGColorSpace` accepts it and Apple's CMS transforms XYB→sRGB matching our inverse to **0.28/255**. (3) **Encode** (`colorSpace = .xyb`): RGB→XYB 3 planes, `kBaseQuantMatrixXYB`+`kGlobalScaleXYB` tables, 4:4:4, APP2 ICC + APP14; **decode** detects the ICC and inverts XYB. YCbCr path byte-identical. **Honest findings (the "uncertain payoff" was real):** color is provably correct, but (a) Apple's *image-render* CMS (Preview/CGContext/sips) doesn't apply CLUT-A2B profiles, so it misrenders XYB JPEGs even though the profile is correct — on Apple, decode with this library; (b) ImageIO *does* decode the right samples + attach the ICC (verified), so spec-compliant CLUT-aware decoders render correctly; (c) size/quality ≈ parity with tuned 4:4:4 YCbCr in current tuning, not a clear win. Shipped opt-in/experimental; default stays YCbCr.
- [x] **Table-driven Huffman decode** · 8-bit lookahead (libjpeg's `HUFF_LOOKAHEAD`) added to `HuffmanTable`; `decodeSymbol` resolves ≤8-bit codes from the table in O(1) and **falls back to the bit-by-bit walk** for >8-bit codes and any byte near a marker/EOF. That fallback is what dissolves the old "conflicts with the restart path" worry — the lookahead never buffers across a marker (`fillBuffer` stops at `0xFF`-not-`00`), so restart/align handling is untouched. **Bit-identical by construction** (prefix-free property) and **proven** by a direct fast-vs-slow A/B over 1000 random streams (incl. injected stuffing + marker-like bytes) plus the full round-trip/cross-codec/fuzz suite. **Measured (release, 1024²):** ~15–19% faster *total* decode on entropy-heavy content (texture 45.4→38.4 ms, noise 56.2→45.8 ms; the entropy stage itself ~40% faster), ~0% change on trivially-compressible images where IDCT/color dominate. No regression, no new error surface.
- [ ] Metal hot path · marginal over Accelerate (already AMX/GPU-accelerated GEMM)

### Tier 4 — release (final state)
- [ ] Tag release (Version Bump → Release GitHub Actions; currently `0.1.0`, untagged)
- [~] DocC API documentation — library overview rewritten accurately (real feature set, DocC `## Topics`, usage examples; dropped the old overstated "35% / NEON-SSE / Metal" claims) and stale public-API doc/defaults corrected. Remaining: a `.docc` catalog + `swift-docc-plugin` for `swift package generate-documentation` (couldn't add it here — this machine's git `safe.bareRepository=explicit` blocks SwiftPM fetching the plugin; add in an unrestricted env / Xcode).
