# JLISwift Roadmap

Living progress tracker — items move from **Remaining** to **Completed** as each
stage lands (CI-green). Each line: **what** · *value* · *risk / how it's validated*.

_Last updated: 2026-05-30 — **Project pivot: medical imaging is now the primary use case.** A multi-agent **medical-grade readiness audit** ([MEDICAL_GRADE_ASSESSMENT.md](MEDICAL_GRADE_ASSESSMENT.md)) found a genuinely strong codec but real engineering gaps + zero regulatory artifacts. The `feat/medical-foundations` branch closed the engineering gaps (193 tests green, verified on the real corpus): decoder fail-safe guards (decompression bomb, lossless shift), DICOM reader hardening (undefined-length SQ skip, bitsStored/HighBit masking + signed sign-extension, planar config), signed-pixel provenance end-to-end, ISO/IEC 10918-2 IDCT conformance, and a **DICOM writer + JPEG-encapsulation** path joining the codec to the container (real compressed clinical DICOMs now decode). **0.4.0's theme is medical foundations** (below). The old jpegli-parity / perf / XYB work is **re-prioritized to P2** — still tracked, no longer the headline._

_Earlier: **0.3.0 RELEASED** (tagged `v0.3.0`): jpegli adaptive-quant field opt-in + JLILab distribution scaffolding. **0.2.0**: perceptual-quant default (CT q90 ba 1.20 vs 1.82 at equal bytes), ~15–16% faster encode / ~26–43% faster decode (byte-identical), the JLILab macOS lab._

## 0.3.0 — Plan (active, 2026-05-29)

**Theme: turn JLILab into a real, distributable signed app; ship the adaptive-quant field opt-in.**
**Goals:** a **signed/notarized JLILab.app (+ DMG)** is the headline deliverable, with the jpegli **adaptive-quant field landed as an opt-in/experimental path** (no medical regression — default stays `perceptual-420`). Matching jpegli on butteraugli-at-matched-bytes (the residual **MR gap**) proved to need a field oracle, so it's **moved to 0.4.0**. Discipline unchanged: RD-validated quality, byte-identical (or explicitly re-validated) perf, CI-green.

**Release gate:** code is ready now; the only blocker is the signed DMG, which needs an Apple Developer identity + a stored `notarytool` keychain profile (see WS-B). Tag `v0.3.0` once the DMG is produced.

### WS-A — Full jpegli adaptive-quant field (P1, headline quality)
- [x] **Ported** libjxl `adaptive_quantization.cc` (faithful scalar): pre-erosion → fuzzy erosion → mask/HF/gamma per-block modulations → `aq_strength`. Operates on the block-padded luma grid (edge-replicated). Sanity-tested.
- [x] **Per-coefficient zero-bias (dead-zone)** + opt-in quant path `jpegliAdaptiveQuant` (replaces trellis for 8-bit YCbCr when set; decode unaffected). Zero-bias tables ported from `quant.cc`.
- [~] **RD-measured (`--rd-matrix`, butteraugli) — first cut does NOT close the gap.** vs `perceptual-420` (the 0.2.0 default) it makes files *smaller* but butteraugli is mixed (CT q90 1.16 vs 1.20 slightly better; MR 1.59 vs 1.25 worse; XA ~wash) and still well behind jpegli (CT 0.95). The "smaller-but-worse" pattern points to a **quantized-value scale mismatch** (jpegli's DCT normalization differs → the 0.59-ish thresholds are mis-scaled) plus a **per-component field on chroma** (jpegli uses the luma-derived field for all channels). **Default stays `perceptual-420`; the path ships opt-in/experimental.**
- [~] **Calibration attempted (aq_strength scale sweep) — image-dependent, not a uniform win.** `dctMatrix` is orthonormal, so the threshold *offset* (0.59) is correctly scaled; the over-aggression is `aq_strength` magnitude. Sweeping aq×{1.0, 0.5}: at **4:4:4** jpegliAQ matches/beats both perceptual *and* jpegli on **CT** (×1.0: ba 0.94 ≈ jpegli 0.95, < perceptual 1.07) and **XA** (×0.5: 1.33 < perceptual 1.50), but stays worse on **MR** (≈1.22 vs perceptual 0.99) at *every* scale. No single global scale wins → the field's *response shape* (luma input-scaling vs jpegli's `input_buffer` range), not its magnitude, is the likely culprit. Default stays `perceptual-420`; path remains opt-in/experimental at the faithful aq (×1.0).
- [x] **Luma-derived field for chroma** (faithful — jpegli computes the masking field once on luma and maps it to every channel; box-averaged for subsampled chroma). Correct for color input. **Medical results unchanged** (CT/MR/XA are grayscale → chroma≈0, so they're luma-dominated). After it: **jpegliAQ-444 matches jpegli on CT (0.944 ≈ 0.946) and beats the perceptual default on CT (1.07) and XA (1.50→1.26)** — but still **loses on MR (1.24 vs perceptual 0.99)**. So the residual gap is the **luma field over-quantizing MR-type (smooth-with-subtle-detail) content**, not chroma.
- [ ] **Close the MR gap — moved to 0.4.0 (needs an oracle):** the luma field diverges from jpegli's on smooth content; debugging it principledly needs a **jpegli field oracle** (instrument `cjpegli` to dump its `quant_field`) to diff against — blind tuning is image-dependent (a global aq scale helps MR but hurts CT). The 0.2.0 perceptual default already banked the headline medical win, so this is upside, not a 0.3.0 blocker. Residual gap may also be partly XYB → WS-E.

### WS-B — JLILab distribution (P1)
- [x] **Sign/notarize/DMG scaffolding**: `JLILab/scripts/package.sh` (archive → Developer-ID export → `notarytool --wait` → staple → DMG) + `ExportOptions.plist`; hardened runtime already on, non-sandboxed (so it reads user files + shells out to butteraugli/cjpeg). *The notarize step needs your Apple Developer identity + a stored `notarytool` keychain profile — everything else is ready.*
- [x] **Batch metrics**: `JLIBench --batch <dir> [out.csv]` recursively round-trips every `.dcm` (JLISwift default) → CSV (path, dims, bytes, bpp, ratio, PSNR, butteraugli, enc/dec ms). Validated on the corpus.
- [x] **Interactive DICOM window/level**: library API (`DICOMImage.render8bit/render12bit(windowCenter:windowWidth:)`, `windowDefaults()`, `intensityRange()`, + parsed `modality`) with unit tests; JLILab sidebar sliders re-window the 8-/12-bit source and re-run the round-trip live, with **CT Hounsfield presets** (Soft/Lung/Bone/Brain — gated on `modality == "CT"`). Also added a launch-arg file-open so the app can be scripted/pointed at a file. Validated on real CT + MR corpus files (modality parse, slider ranges, luma response).
- [ ] Remaining QoL (in-app): save/load presets, export comparison report.

### WS-C — Targeted performance (P2, diminishing returns)
- [ ] Parallelize inverse color conversion + per-component decode (byte-identical, `concurrentPerform`).
- [ ] Parallel entropy emit via restart-interval segmentation — **opt-in only** (adds RST markers → not bit-identical).
- [ ] Fuse dequant+IDCT.

### WS-D — Features / robustness (P2)
- [ ] float32 **decode output** (currently input-only); DocC catalog; expand fuzz/conformance corpus.

### WS-E — Re-evaluate XYB with the mature perceptual machinery (P3).

### Sequencing
WS-A's opt-in field has landed; the remaining 0.3.0 work is **WS-B** (ship the signed app). **Tag `v0.3.0` once the notarized DMG is produced.** Closing the jpegli/MR gap (needs a field oracle) + WS-C/D/E move to **0.4.0**.

## 0.4.0 — Plan (active, 2026-05-30)

**Theme: medical foundations.** Make JLISwift a codec a medical-imaging product can *defensibly* build on: land the safety/correctness fixes, close the highest-value remaining codec gaps for real clinical data, build the **verification-evidence** pack, and draft the **regulatory scaffolding**. This is the work that converts "a strong codec" into "a strong codec with the evidence trail a SaMD needs." Codec quality (jpegli MR gap) and perf drop to **P2** this cycle.

**North star:** by 0.4.0 we can hand a regulatory/clinical partner (a) a frozen, content-addressed regression corpus with pass/fail acceptance criteria, (b) a draft DICOM Conformance Statement that matches the code, (c) a risk-file skeleton (ISO 14971) enumerating codec hazards + the controls already in code, and (d) a green CI gate that proves bit-exact lossless + IDCT conformance + fuzz-safety on every commit. **We still cannot call it "medical grade"** — that needs the full IEC 62304 / ISO 13485 / CDSCO process (0.5.0+) — but a partner can see exactly how far along it is.

**Foundation (DONE — `feat/medical-foundations` branch, 193 tests green):**
- [x] **Decoder fail-safe guards** — decompression-bomb cap (`maxDecodablePixels`) on baseline/lossless + DICOM reader; lossless point-transform validated (no negative-shift trap).
- [x] **DICOM reader hardening** — undefined-length SQ skip; `bitsStored`/HighBit masking + signed sign-extension; PlanarConfiguration; truncated-PixelData throws (no silent under-fill). Verified on real CT/DX/MG/MR/XA.
- [x] **Signedness end-to-end** — `JLIImage.isSigned`; lossless preserves it bit-exactly; lossy path rejects signed input (no silent corruption).
- [x] **ISO/IEC 10918-2 IDCT conformance** — Annex A statistical test, 3 ranges, passes with ~400× margin.
- [x] **DICOM writer + JPEG-encapsulation** — produce native + encapsulated DICOM; reader extracts encapsulated JPEG; real compressed clinical US DICOMs decode through the codec.

### WS-M1 — Verification evidence pack (P0 — the highest-value medical work) ✅ DONE
- [x] **Frozen regression corpus** with explicit acceptance criteria (`RegressionCorpusTests`): 9 content-addressed (SHA-256) cases spanning modality × bit-depth (8/12/16) × signedness × photometric (MONO1/2, RGB) × transfer-syntax (native + encapsulated). Per-case acceptance: lossless bit-exact / near-lossless 2^Pt−1 bound / encapsulated bit-exact / native read-back / expected-reject. A **drift guard** (hash mismatch ⇒ CI fail) keeps it frozen; no PHI (deterministic generation).
- [x] **CI cross-validation gate** — a dedicated, hard **"Medical conformance evidence"** CI step (`ci.yml`) runs the safety-critical suites un-parallelized and surfaces the `CONFORMANCE`/`MANIFEST`/`IDCT-CONFORMANCE` records to the log + uploads `medical-evidence.log` as an artifact. `ConformanceEvidenceTests` asserts the claims (C1–C7) as named criteria with margins; the libjpeg-turbo `cjpeg` cross-checks run unconditionally (embedded fixtures). Green CI now *proves* lossless bit-exactness, not just "doesn't throw."
- [x] **DICOM-parser fuzz** (`DICOMFuzzTests`) — SplitMix64-seeded, `try?`-probed (a trap crashes the process): truncation (native + encapsulated), single-byte mutations, hostile element lengths, decompression-bomb / zero / overflow geometry, random + random-behind-DICM, corrupted encapsulated fragment framing, unterminated nested sequences. Reader fails safe over the explored space.
- [x] **Signed sample-stat report** (`JLIBench --signed-stats <dir> [out.csv]`) — per-file census of bitsAllocated/bitsStored/signed/photometric/SPP/transfer-syntax/encapsulated + native lossless round-trip result; rejected files recorded *with reason*. Validated on a real corpus mix: **15/15 native single-frame images bit-exact** (CT 16-bit, DX/MG/MR/XA 12-bit); encapsulated US flagged; SR/metadata-only recorded as rejected-with-reason.

*Result: full suite 208 tests / 24 suites green; the medical evidence trail is CI-gated and self-documenting.*

### WS-M2 — Codec gaps that matter for real clinical data (P1) ✅ mostly DONE
- [x] **YBR_FULL / YBR_FULL_422 → RGB** color conversion on read — `render8bit` was treating any 3-sample 8-bit image as RGB and copying YCbCr through verbatim (wrong color). Now YBR variants are converted with the full-range BT.601 inverse after de-interleave; true RGB still passes through. (`DICOMColorTests`; encapsulated US decodes to correct RGB.)
- [x] **Multi-frame** (NumberOfFrames) — parsed; reader exposes `numberOfFrames` + `frame(_:)`, bounds native `pixelData` to frame 0, clamps a lying count. **Verified on real 47- and 64-frame US cine**: each frame splits + decodes independently to 1016×758 RGB.
- [x] **MONOCHROME1 end-to-end test** — explicit assertion that MONO1 renders as the photometric inverse of MONO2 at the endpoints + per-pel (`DICOMColorTests`).
- [x] **Encapsulated multi-fragment + Basic Offset Table** — reader maps fragments→frames via the BOT (one-fragment-per-frame fallback, full concat for single frame); writer emits a populated BOT with one fragment per frame (`writeEncapsulatedFrames`). (`DICOMWriterTests`.)
- [ ] *(stretch, deferred)* **Signed lossy** done right — instead of rejecting, offset-to-unsigned + record the offset so signed CT can use the DCT path losslessly-reversibly. Only if a use case needs it.

*Result: full suite 215 tests / 25 suites green; single-frame real files still bit-exact (no regression). The one remaining WS-M2 item is the optional signed-lossy stretch.*

### WS-M3 — Regulatory scaffolding (P1 — draft, not certification)
- [ ] **Intended-use / indications statement** + **software safety classification** rationale (codec feeding a diagnostic viewer ≈ IEC 62304 Class B/C) — a short controlled doc.
- [ ] **DICOM Conformance Statement (draft, PS3.2 shape)** — transfer syntaxes actually supported (read/write), SOP classes, pixel-module attributes honored, explicit list of what is *not* supported. Must match the code (CI could even check the claimed TS list against `encapsulatedTransferSyntaxes`).
- [ ] **ISO 14971 risk-file skeleton** — hazard table for codec-specific harms (silent pixel corruption, lossy-as-lossless, photometric inversion, signed/unsigned confusion, dropped frames, decompression-bomb DoS) mapped to the controls **already in code** (provenance flags, bomb cap, fail-safe guards, bit-exact tests) + the residual gaps.
- [ ] **Traceability seed** — a lightweight requirements→test matrix for the safety-critical claims (bit-exact lossless, fail-safe decode, IDCT conformance), so the existing tests become *traced* evidence.

### WS-M4 — Quality & perf (P2 — re-prioritized, still tracked)
- [ ] **jpegli MR gap** (was the 0.4.0 headline): build a **field oracle** (instrument `cjpegli` to dump `quant_field`), diff vs ours, fix the luma field's response shape on smooth content. *Upside, not a blocker — the perceptual default already banked the headline medical quality win.*
- [ ] **WS-C perf** — parallel inverse color/decode, parallel entropy emit (opt-in), fused dequant+IDCT.
- [ ] **WS-D** — float32 decode output; DocC catalog; **WS-E** — re-evaluate XYB with the mature perceptual machinery.

### Sequencing & gate
**WS-M1 ✅ + WS-M2 ✅ landed.** Next is **WS-M3** (regulatory drafts — DICOM Conformance Statement, ISO 14971 risk-file skeleton, intended-use/classification, traceability seed), with **WS-M4** as fill-in. **Tag `v0.4.0`** is now unblocked on the code side (WS-M1 CI-green + WS-M2 YBR + multi-frame landed) — it can ship once WS-M3's draft docs are in or be tagged now with WS-M3 following in a doc-only point release. Discipline unchanged: bit-exact gates, fuzz throws, CI-green, every claim corpus-measured.

**Hard line:** nothing in 0.4.0 lets us market "medical grade," "medical device," "for diagnostic use," or "clinically validated." Those need the full QMS + risk file + CDSCO/FDA pathway (**0.5.0+**, a multi-quarter process program). See [MEDICAL_GRADE_ASSESSMENT.md](MEDICAL_GRADE_ASSESSMENT.md) §10 for safe vs unsafe claim language.

## 0.5.0+ — Regulatory pathway (future, process-led)
Out of scope for code milestones, tracked here so the direction is explicit: full **IEC 62304** lifecycle docs + traceability, **ISO 14971** risk management file (not just the skeleton), **ISO 13485**-aligned QMS / Design History File, a **published DICOM Conformance Statement**, and the **India CDSCO** (Medical Device Rules 2017) classification + licensing pathway (with US FDA SaMD / EU MDR if those markets are targeted). This is a process + evidence program measured in quarters, not a coding task — but the 0.4.0 scaffolding (WS-M3) is its on-ramp.

## 0.2.0 — Optimization release (shipped v0.2.0, 2026-05-29)

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
- [x] **Parallelized chroma upsample** across output-row ranges via `concurrentPerform` (each row independent → **bit-identical**, same `@unchecked Sendable` pointer-carrier pattern as the encoder's trellis; gated by image size). 164 tests + cross-codec green. Another ~25% off decode; **cumulative WS3 decode ~26–43% faster** vs the 0.1.x baseline @1024² (gradient 26.1→14.9, checker 24.6→14.2, noise 47.4→34.9 ms).
- [ ] Fuse dequant + IDCT; ensure the batched Accelerate IDCT path for all block counts
- [ ] Parallelize MCU decode / inverse-color across cores (next lever); fuse passes
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
