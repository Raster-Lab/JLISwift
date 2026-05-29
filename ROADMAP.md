# JLISwift Roadmap

Living progress tracker — items move from **Remaining** to **Completed** as each
stage lands (CI-green). Each line: **what** · *value* · *risk / how it's validated*.

_Last updated: 2026-05-29 — **0.1.0 released** (tagged `v0.1.0`, GitHub Release live) + **JLILab** macOS round-trip/cross-codec lab shipped. Focus is now the **0.2.0 optimization release** (plan below). Earlier this milestone: table-driven 8-bit-lookahead Huffman decode (~15–19% faster, bit-identical, A/B-proven); float32 input; adaptive-quant field (opt-in); XYB color (experimental); and 2026-05-28: lossless+near-lossless, scaled decode, multi-threaded trellis+AC-count, jpegli quantizer, ICC/Exif, progressive+restart, fuzzing._

## 0.2.0 — Optimization release plan (active, 2026-05-29)

**Reframe first — the "570 ms encode" seen in JLILab was a Debug-build artifact, not the codec.**
Re-measured in **release** via JLIBench (512×512 @ q90, in-process):

| Codec | Encode | Decode | Note |
|---|---|---|---|
| JLISwift 4:4:4 | **5.7 ms** | 6.8 ms | Debug build ≈ 570 ms (~100× penalty) |
| JLISwift 4:2:0 | 6.9 ms | 6.7 ms | |
| ImageIO (libjpeg-turbo) | 0.95 ms | 0.88 ms | the fair in-process reference |
| libjpeg-turbo / mozjpeg / jpegli | ~70–100 ms | ~70 ms | **shell-out: dominated by process-spawn overhead, not encode** |

Only ImageIO is a fair in-process timing; CLI codecs are overhead-dominated; JLILab's JLISwift
row is Debug. **Quality** columns are valid, though: default JLISwift ≈ libjpeg-turbo (30 KB /
46.2 dB / ba 1.328), while **jpegli leads (28 KB / 47.8 dB / ba 1.060)**. Real gaps for 0.2.0:
**~6× encode + ~7× decode vs ImageIO (release)**, and **quality-per-byte vs jpegli**.

**Goals:** encode ≤ ~2× ImageIO (≤ ~2 ms @ 512² q90); decode ≤ ~2×; default config matches/beats
jpegli on butteraugli-at-matched-bytes across the DICOM corpus + standard images; every claim
release-measured + regression-baselined; byte/bit-identical gates; fuzz still throws; CI-green.

### WS1 — Honest measurement (P0 — do first, or everything mis-prioritizes)
- [ ] Build/measure JLISwift in **Release** in JLILab (or a "Debug — timings not representative" banner)
- [ ] Separate encode time from **process-spawn overhead** for CLI codecs (subtract / warm / label)
- [ ] **RD-curve view** — sweep q50–95, plot bytes vs butteraugli per codec (compare at matched rate, not one point)
- [ ] Wire **SSIMULACRA2** (already installed via jpeg-xl) alongside butteraugli

### WS2 — Encode speed (P1; real ~6× gap)
- [x] **Profiled** (`JLIBench --profile-encode` + `sample`, release, 1024²). Baseline ms/encode: gradient 17.6, checker 16.7, **noise 51**. Self-time leaders: **allocation churn dominates the non-compute cost** — `memmove` + `bzero` + `madvise` + `Array.init` ≈ 1238 samples, > any single compute stage; then `quantizePlane` 455, `countAC` 295, `encodeAC` 276, `trellisBlocks` 196; DCT (BLAS/vDSP) is comparatively small (already a GEMM).
- [x] **Color-conversion alloc/COW fix** (first allocation win): `imageRGBToYCbCr`/`imageYCbCrToRGB` rewritten to use one *uninitialized* scratch block + raw pointers — kills the zero-fill of fully-overwritten buffers and the per-call copy-on-write the in-place `vDSP_vsma` chain triggered. **Byte-identical** (same vDSP ops; 164 tests + cross-codec green). ~12% faster checker / ~6% gradient encode (negligible on noise, where entropy coding dominates); decode gets the same fix.
- [x] **Uninitialized quantize-pipeline buffers**: `quantizePlane`'s three n·64 buffers (`blockBuf`/`dctBuf`/`quant`) are fully overwritten downstream, so they now allocate without the zero-fill (the dominant `bzero`). Byte-identical (164 tests). **Cumulative WS2 so far: ~15–16% faster encode** on smooth/textured (gradient 17.6→15.0, checker 16.7→14.0 ms @1024²), ~5% on noise.
- [ ] Parallelize the **entropy emit** via restart-interval segmentation (the remaining serial stage)
- [ ] **Fuse** forward-DCT → quantize → symbol-count into one cache-resident sweep
- [ ] Remaining hot-loop allocations (DCT-batch internals, Huffman freq arrays) + decode-side scratch (WS3)
- [ ] SIMD scalar stages (level-shift, RGB→YCbCr, zig-zag, quantize) via Accelerate/SIMD
- [ ] Optional **"fast" preset** (skip trellis + optimized-Huffman) for latency-critical use (~trellis is 22%)
- *Validate:* FNV byte-identical vs serial; bench timing regression baseline (`--save-baseline`)

### WS3 — Decode speed (P1; table-driven Huffman already landed)
- [x] **Profiled** (`JLIBench --profile-decode` + `sample`, release 1024²). Dominant cost: **`ChromaSampling.upsample` (1134 samples, ~3× the next item)** — per-pixel array subscripting (copy-on-write checks on every write) + recomputing the x-mapping per pixel. Then inverse color (already optimized) + `Array.init`/COW churn.
- [x] **Optimized chroma upsample**: precompute the column x-mapping once (identical every row) + raw-pointer source/dest planes (no per-element COW) + uninitialized output. **Byte-identical** (same bilinear formula/order; 164 tests + cross-codec). **~12–19% faster decode** @1024² (gradient 26.1→21.1, checker 24.6→20.6, noise 47.4→41.6 ms).
- [x] **Killed decode COW + scratch zero-fill**: the scan loop wrote coefficients via nested-array subscript (`componentZigzag[c][dst+i]` → 64 uniqueness checks/block) — now one buffer-pointer write per block; and the four reused per-component scratch buffers (`natural`/`dctBuf`/`pixelsBuf`/`idctScratch`) allocate uninitialized. Byte-identical (164 tests). **Cumulative WS3 decode: ~18–23% faster** @1024² (gradient 26.1→20.0, checker 24.6→19.3, noise 47.4→38.9 ms).
- [ ] Fuse dequant + IDCT; ensure the batched Accelerate IDCT path for all block counts
- [ ] Parallelize MCU decode across restart intervals (independent segments)
- *Validate:* bit-identical across suite + cross-codec + fuzz

### WS4 — Quality-per-byte / jpegli parity (P1; biggest user-visible win)
- [x] **RD-curve the corpus → new default = perceptual quant tables.** `JLIBench --rd-matrix` (butteraugli × config × quality on the DICOM corpus) showed perceptual-420 clearly beats Annex-K-420 on every medical image at matched bytes — **CT q90: ba 1.20 vs 1.82** (equal size); **XA q90: 58 KB/1.56 vs 76 KB/2.02** (smaller *and* better); **MR q90: 30.6 KB/1.25 vs 30.9 KB/1.50**. Flipped `perceptualQuantTables` default → `true` (4:2:0 kept; adaptive-field kept opt-in — the sweep showed it's **near-inert under perceptual tables**). Only the synthetic gradient regressed (degenerate). Full suite green (2 default-assuming tests updated). Still behind jpegli (CT q90 ba 0.95) — closes most of the Annex-K→jpegli gap.
- [ ] Complete the jpegli **adaptive-quant field** (~560-line psychovisual model + per-block **zero-bias / dead-zone**) — now the main remaining jpegli gap (the current simplified λ-field barely moves output once perceptual tables are on)
- [ ] jpegli **4:2:0 chroma** handling (`k420Rescale`) so 4:2:0 stops being the weak spot
- [ ] Re-evaluate **XYB** now the perceptual machinery is mature
- *Validate:* RD curves vs jpegli/mozjpeg across DICOM + standard; per-modality medical check; gate default change on no perceptual regression

### WS5 — Stretch / deferred
- [ ] **Metal hot path** — only if profiling shows a GPU-amenable bottleneck Accelerate misses (still hard to validate bit-exactly)
- [ ] DocC catalog; sign + notarize JLILab as a distributable, double-clickable `.app`

### Sequencing & risks
M1 WS1 (trustworthy baselines) → M2 WS4 (quality, highest value) → M3 WS2 + WS3 (speed, profile-guided) → M4 lock regression baselines + docs + tag 0.2.0.
Top risk: **measurement** — fix WS1 first (a 100× phantom was just observed). Quality-default changes can regress specific medical modalities (gate per-modality). Perf refactors risk bit-exactness (FNV/checksum gates every change).

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

> Honest status (2026-05-29): the 0.1.x feature set below is **all done, CI-green,
> and shipped in 0.1.0**. Forward work now lives in the **0.2.0 optimization plan
> above** (encode/decode speed + jpegli-parity quality). The Metal hot path stays
> deferred unless profiling justifies it (WS5).

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
- [x] **Tag release — `v0.1.0` shipped** (2026-05-29): annotated tag on the CI-green HEAD → `release.yml` validated (build+test on macos-26), created the GitHub Release with auto-changelog, notified Swift Package Index. All jobs green.
- [~] DocC API documentation — library overview rewritten accurately (real feature set, DocC `## Topics`, usage examples; dropped the old overstated "35% / NEON-SSE / Metal" claims) and stale public-API doc/defaults corrected. Remaining: a `.docc` catalog + `swift-docc-plugin` for `swift package generate-documentation` (couldn't add it here — this machine's git `safe.bareRepository=explicit` blocks SwiftPM fetching the plugin; add in an unrestricted env / Xcode).
