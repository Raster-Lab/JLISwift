# JLISwift — Medical-Grade Readiness Assessment

*Independent audit, 2026-05-29. Multi-agent static review + adversarial verification + empirical round-trip on the real clinical DICOM corpus (CT/DX/MG/MR/US/XA, ~30k files). Evidence cited as `file:line`.*

---

## 1. Bottom line

**JLISwift is a genuinely well-engineered, well-tested, fuzz-hardened JPEG codec — but it cannot honestly be called "medical grade" today.** Not because the code is weak (it is largely strong), but because **"medical grade" is a regulatory + evidence designation, not a code-quality label.** No code review, test pass-rate, or benchmark can confer it. The project currently has **none** of the mandatory medical-device artifacts (safety classification, risk file, design controls, V&V records, QMS, DICOM Conformance Statement, regulatory registration), and a small number of **real safety defects** remain that a diagnostic product must close first.

The honest one-liner: *"A capable, bit-exact-tested research codec at the engineering level; at the regulatory level it is at the **early/pre-readiness** stage."*

---

## 1a. Remediation log (engineering gaps closed since the audit)

The code-level defects this audit surfaced have since been fixed and regression-tested (full suite **193 tests, 0 failures**; each item verified on the real corpus where applicable). This does **not** change the regulatory verdict in §1 — "medical grade" still requires the process + evidence work in §8–9 — but the engineering substrate is materially stronger:

| Audit finding | Status | Fix + evidence |
|---|---|---|
| 🔴 Decompression bomb (no pixel cap) | **Fixed** | `maxDecodablePixels = 1<<28` cap in `JLIDecoder` (baseline/lossless) and `DICOMReader`; truncated-PixelData now throws instead of silent under-fill. Tests in `DICOMReaderTests`. |
| 🔴 Lossless negative-shift trap | **Fixed** | `guard pt >= 0, pt < precision` in `JLIDecoder.decodeLossless`. |
| 🔴 No lossy/lossless provenance | **Fixed** | `JLIEncoderConfiguration.diagnosticLossless` + `isNumericallyLossless`/`isLossy`. `MedicalSafetyTests`. |
| 🟠 Undefined-length SQ derails parsing | **Fixed** | `skipUntilDelimiter` steps over sequences; verified on real implicit-VR MR images (which contain SQs). |
| 🟠 `bitsStored`/HighBit not masked; signed narrow data wrong | **Fixed** | `decodeIntensities` masks to `bitsStored` and sign-extends from the stored sign bit; verified signed 12-in-16 → correct negatives on real CT/DX/MG. |
| 🟠 PlanarConfiguration / color mishandled | **Fixed** | Plane-interleaved RGB reassembled; `planarConfiguration` parsed. |
| 🟠 Signedness not end-to-end | **Fixed** | `JLIImage.isSigned`; lossless preserves it bit-exactly, lossy path **rejects** signed input instead of corrupting it. `MedicalSafetyTests`. |
| 🟠 No ISO/IEC 10918-2 IDCT conformance | **Fixed** | `IDCTConformanceTests` runs Annex A over 3 ranges; passes with large margins (MSE ≈ 5e-5 vs 0.02 limit). |
| 🟠 No DICOM writer; codec not joined to container | **Fixed** | New `DICOMWriter` (native + encapsulated JPEG); reader now extracts encapsulated JPEG fragments. End-to-end pixels→encode→encapsulate→read→decode is bit-exact, and real JPEG-compressed US DICOMs now decode through the codec. `DICOMWriterTests`. |

Still open (process/evidence, not code): DICOM Conformance Statement, IEC 62304 lifecycle, ISO 14971 risk file, ISO 13485 QMS, CDSCO/FDA pathway — see §8–9. Also still codec-level: signed data is *rejected* (not supported) on the lossy path; encapsulated multi-frame is single-frame only; Big-Endian and JPEG-2000/RLE-in-DICOM remain unsupported.

---

## 2. What "medical grade" actually means

A good codec ≠ a medical device. For diagnostic-imaging software (Software as a Medical Device, SaMD), "medical grade" requires a **process + documented evidence** stack on top of correct code:

- **IEC 62304** — a documented software lifecycle: safety classification (A/B/C), requirements → design → code → test traceability, signed V&V records, SOUP/third-party control, problem-resolution & change control.
- **ISO 14971** — a risk-management file: hazard analysis specific to a codec, risk controls *with verification*, residual-risk evaluation.
- **ISO 13485** — a quality management system (design history file, document/record control, CAPA).
- **DICOM PS3.5 conformance** + a published **DICOM Conformance Statement (PS3.2)**.
- **Regulatory clearance/registration** for the market: **India CDSCO** (Medical Device Rules 2017), US FDA (510(k)/De Novo SaMD), EU MDR/CE.

None of these are in the repository. That is the gap — and it is a multi-quarter program, not a coding task.

---

## 3. Scorecard

| Dimension | Rating | One-line justification |
|---|---|---|
| **Lossless bit-exactness** | **Strong** | `LosslessTests.swift:20-199` asserts true `img.data == src` for predictors 1–7 at 8/12/16-bit, color, vs libjpeg-turbo/djpeg fixtures. Empirically reproduced on 4 real DICOMs. |
| **Bit-depth & signed correctness** | **Weak** | DICOM layer reads signed pixels correctly for display (`DICOMImage.swift:144-160`), but the codec (`JLIImage`) has **no signed concept**; lossy paths shift signed data; no signed round-trip test. |
| **Decoder conformance (incl. IDCT)** | **Adequate** | SOF0/1/2/3 implemented; reduced-scale bounded vs djpeg. **No ISO/IEC 10918-2 IDCT-accuracy procedure** — DCTTests are internal sanity checks, not the standard's error bounds. |
| **Encoder & determinism** | **Adequate** | Determinism **confirmed by code inspection** — both `concurrentPerform` sites use disjoint indexed writes + fixed-order integer merge (`JLIEncoder.swift:1011-1087`); but the test pins it only at a *fixed* thread count (`EncoderDecoderTests.swift:611-615`), not across counts. |
| **Color / photometric safety** | **Weak** | Grayscale safe from chroma loss (4:0:0), **but perceptual quant is DEFAULT-ON (lossy luma) and there is no lossy-vs-lossless provenance flag** — lossy output can be mistaken for diagnostic-lossless. |
| **DICOM container conformance** | **Weak** | Reader-only, narrow scope: uncompressed Implicit/Explicit VR LE only; **fails loud** (good) on others; no Big-Endian, no multi-frame, no encapsulated/compressed, no writer, no Conformance Statement. |
| **Robustness / fail-safe** | **Adequate** | Real fuzz suite; parse/entropy layers throw, never trap. **But two reachable trap vectors remain** (decompression-bomb; lossless negative-shift). |
| **Test rigor & cross-validation** | **Adequate** | Lossless/scaled-decode **cross-validated in CI** against embedded libjpeg-turbo `cjpeg`/`djpeg` fixtures (runs unconditionally, no tool needed — `ScaledDecodeConformanceTests.swift:7-91`, verdict *confirmed*). Live cross-codec PSNR is **opt-in tooling, skipped when binaries absent** — not a CI gate. No ISO/IEC 10918-2 IDCT conformance vectors. |
| **Regulatory / process** | **Weak (Unknown→none)** | Zero medical-device process artifacts exist. |

---

## 4. Confirmed strengths (with evidence)

- **Bit-exact lossless is real and tested**, not a tolerance: `#expect(img.data == src)` for predictors 1–7, 8/12/16-bit, grayscale + RGB, near-lossless Pt=1/2 — `LosslessTests.swift:20-199`, impl `JLIDecoder.swift:507-602`. **Empirically reproduced** on 4 real clinical files (below).
- **No hard-trap primitives**: zero `fatalError`/`try!`/`as!`/`assertionFailure` across `Sources/JLISwift` + `Sources/JLIDICOM`. The only `precondition`s are internal SIMD buffer contracts, satisfied by construction.
- **Validation-before-allocation gate**: `validateDecodable` (`JLIDecoder.swift:651-683`, called at `:86`) rejects bad precision/dimensions/components/sampling/quant-index **before** any allocation or DSP.
- **Throwing parse/entropy layers**: marker/DQT/DHT bounds-checked (`JLIMarkerReader.swift:277-399`); DHT rejects oversubscribed tables; Huffman decoder bounds-checks and throws (`JLIHuffman.swift:386-393`); BitReader caps width & throws on EOF (`JLIBitStream.swift:134-136`).
- **DICOM reader is more correct than the README implies**: it **throws** `unsupportedTransferSyntax` (not a silent skip — that's only in the *bench* corpus loader); applies RescaleSlope/Intercept **before** Window/Level and handles MONOCHROME1 inversion + signed pixels for display (`DICOMReaderTests` asserts the CT-not-blown-white case).
- **A real fuzz harness exists** (`FuzzTests.swift:77-209`): truncations, byte mutations, random + SOI-prefixed random, marker-length & metadata corruption, also under scaled decode.

---

## 5. Confirmed gaps (severity-ranked)

| # | Sev | Gap | Evidence | Diagnostic-use impact |
|---|---|---|---|---|
| 1 | **HIGH** | **DICOM decompression bomb** — no upper bound on Rows×Columns; allocates `width*height` from header before checking pixel-data length. A ~200-byte crafted header (60000×60000) → tens-of-GB alloc → **uncatchable OOM trap**. Untested. | `DICOMReader.swift:304`, `DICOMImage.swift:139-140,82`; no test | Silent crash on adversarial/corrupt clinical input — the exact fail-unsafe behavior medical software must avoid. |
| 2 | **HIGH** | **Lossless negative-shift trap** — point transform `pt = successiveApproxLow` is **never validated** (predictor next to it *is*). `Int32(1 << (precision-1-pt))` with crafted `precision=2, Pt=15` → negative-shift **runtime trap**. Unfuzzed (no SOF3 in fuzz corpus). | `JLIDecoder.swift:528,540` | Crash on a malformed lossless JPEG. |
| 3 | **HIGH (clinical)** | **No lossy/lossless provenance flag, and perceptual quant is DEFAULT-ON.** Default encode is lossy; nothing marks output as lossy vs diagnostic-lossless. | `JLIConfiguration.swift` (perceptualQuantTables default on) | **Lossy image mistaken for lossless** — a primary radiology hazard. |
| 4 | **MED** | **Signed pixels not codec-aware.** `JLIImage` is UInt8/UInt16 only. Lossless preserves the bit pattern (survives), but any lossy/DCT path shifts signed CT Hounsfield values; no signed round-trip test. | `JLIImage.swift`; no test | Wrong HU values if signed CT ever goes through the lossy path. |
| 5 | **MED** | **JPEG path has no absolute pixel ceiling** (only the 65535/dim cap); a large-but-legal SOF OOMs before entropy is read; not fuzzed. | `JLIDecoder.swift:116-120,215-222` | DoS / crash. |
| 6 | **MED** | **`bitsStored`/HighBit parsed but not range-validated**; 12-bit-packed DICOM ignored. | `DICOMReader.swift:286,311` | Future sign/mask bugs; some valid objects unreadable. |
| 7 | **MED** | **Architecture: codec not wired to DICOM-encapsulated pixel data; DICOM layer is read-only** (no writer). | `Sources/JLIDICOM/DICOMReader.swift` | "JLISwift as a DICOM codec" is two good halves not yet joined; can't produce DICOM, so no DICOM→codec→DICOM bit-exact round-trip can even be tested. |
| 8 | **MED (real files)** | **Undefined-length Sequences (SQ) are not skipped** — a nested/undefined-length SQ before group 0028 can derail pixel-module parsing on genuine clinical files (not just adversarial input). | `DICOMReader.swift:351-353,377-379` | Real clinical DICOMs with SQ items before the pixel module may misparse → wrong geometry/pixels. |
| 9 | **MED** | **Silent under-fill on short/corrupt PixelData** — reader uses `min(declared, available)` instead of throwing; also no IDCT validation vs ISO/IEC 10918-2 for the lossy path. | `DICOMReader.swift:92,121,144`; `DCTTests.swift:34-50` | Truncated pixel data yields a partial image with no error; lossy IDCT accuracy unproven. |
| 10 | **MED** | **Color DICOM mishandled**: PlanarConfiguration, PALETTE COLOR, YBR not handled; non-8/16 BitsAllocated silently mishandled. | `DICOMReader.swift:81-86,143-161` | US/XA color or palette objects render incorrectly. |
| 11 | **LOW** | Encoder determinism not pinned across thread counts; live cross-codec validation not a CI gate; fuzzer in-process only (no ASAN/coverage-guided); 16-bit/RGB lossless round-trip omits predictors 2,3,5,6. | `FuzzTests.swift:78-81`; `LosslessTests.swift:62,93` | Verification-evidence gaps. |

---

## 6. Adversarial claim verdicts

| Claim | Verdict | Conf | Why |
|---|---|---|---|
| Lossless reconstructs **bit-exactly** at 8/12/16-bit | ✅ **Confirmed** | High | True equality asserted + cross-validated + empirically reproduced. |
| Near-lossless bounds error to 2^Pt−1 | ✅ **Confirmed** | Med | Structural by construction; Pt=1/2 fixtures. (Coarse — no per-pixel NEAR=k mode.) |
| Encoder output byte-for-byte **deterministic** across threads | ✅ **Confirmed** (by inspection) | High | Disjoint indexed writes + fixed-order integer merge; **but test pins only fixed thread count.** |
| Decoder **fails safe / "throws, never traps"** | ⚠️ **Partial** | High | True for the mainstream surface; **2 reachable trap counterexamples** (gaps #1, #2). |
| **Signed** pixels handled end-to-end | ❌ **Refuted** | High | Reader recovers signed *intensities*, but `render8bit/12bit` clamp negatives to 0 and the codec has no signed type — not end-to-end. |
| **Real** cross-validation vs reference codec | ✅ **Confirmed** | High | Embedded cjpeg/djpeg fixtures run unconditionally in CI (`ScaledDecodeConformanceTests`, `LosslessTests`). (Live PSNR cross-codec is the part that's opt-in/skipped.) |
| Grayscale never silently degraded | ⚠️ **Partial** | High | Safe from chroma loss; **not** from default-on lossy luma quant (gap #3). |

---

## 7. Empirical results (actually run on the real corpus)

Release build succeeded (`swift build -c release` → "Build complete!", `JLIBench` produced). A temporary XCTest round-tripped **real clinical DICOMs** through the lossless path (`DICOMReader.read → JLIImage → JLIEncoder lossless → JLIDecoder`, asserting `dec.data == src`):

| File | Geometry / depth | Lossless round-trip |
|---|---|---|
| CT IM-0004-0039 | 771×512, 16-bit, MONO2 | ✅ **bit-exact** (0 mismatches) |
| DX IM-0004-0001 | 2140×1760, 12-bit | ✅ **bit-exact** |
| MG IM-0028-0001 | 2294×1914, 12-bit | ✅ **bit-exact** |
| US IM-0008-0011 | 600×800, 8-bit (luma plane) | ✅ **bit-exact** |
| MR IM-0196-0003 | metadata-only, no PixelData | reader **threw `missingPixelData`** (no crash) — *these are the "files without an image" you mentioned* |
| XA IM-0747-0001 | multi-frame cine (~150 frames) | **skipped** — single-frame reader (no crash) |

**Robustness probe** (corrupt/truncated/garbage fed to decoder + reader): **survived every case with thrown Swift errors, no crash/trap** — empty/garbage/truncated JPEG → `invalidJPEGData` / "Unexpected end of entropy-coded data"; XOR-corrupted entropy → "Invalid Huffman code" (detected, not silently wrong); empty/truncated DICOM → clean DICOMError. *(Note: the synthetic 60000×60000 bomb of gap #1 was not exercised here — that vector remains open.)*

**Limits:** 4 real files proven (not the full 30k); multi-frame & true raw-16-bit-stored paths not validated; lossy PSNR claims not re-verified.

---

## 8. Regulatory readiness

**Overall: early.** Per framework, what's missing:

- **DICOM PS3.5 + Conformance Statement** — narrow scope (uncompressed LE VR only); no published statement, no Big-Endian/multi-frame/encapsulated/RLE, no writer, no validation vs dcmtk/dciodvfy.
- **IEC 62304** — *not started.* No safety classification (a diagnostic-feeding codec is realistically Class B/C), no SDLC/requirements/traceability/V&V records, no SOUP inventory (Accelerate, libjxl tools), no problem-resolution/change-control.
- **ISO 14971** — *not started.* Controls exist (fuzzing, fail-loud DICOM, bit-exact tests) but no risk file, hazard analysis, or residual-risk evaluation. Top hazards: lossy-as-lossless (gap #3), silent corruption, signed confusion, decompression-bomb (gap #1), multi-frame mishandling.
- **ISO 13485** — *not started.* No QMS / design history file.
- **India CDSCO (primary)** — classify (likely Class B/C), license via MD Online (MD-5/MD-9 manufacture, MD-15 import), ISO 13485 QMS, Device Master File + Essential Principles, **no "medical grade" claims pre-license.**
- **US FDA / EU MDR** — only if marketing there; 510(k)/De Novo SaMD + PCCP / MDR Rule 11 Class IIa+ respectively.

---

## 9. Roadmap to a defensible medical claim

**(a) Code & test — do now**
1. Add an **absolute pixel/byte allocation ceiling + pixel-data-length consistency check** on both DICOM and JPEG paths (closes gaps #1, #5). *Highest priority.*
2. **Validate the lossless point transform** `pt` (closes gap #2); validate `bitsStored ≤ bitsAllocated` (gap #6).
3. Add a **lossy/lossless provenance flag** to output + a hard "diagnostic-lossless" encode gate that refuses perceptual/trellis/subsampling (gap #3).
4. Make `JLIImage` **signedness-aware** and add a signed-DICOM round-trip test (gap #4).
5. Add fuzz cases for giant SOF / decompression bomb; add a **determinism test** (pin bytes across thread counts); add an **ASAN / coverage-guided** out-of-process fuzz build.

**(b) Verification evidence to produce**
6. **ISO/IEC 10918-2 IDCT accuracy** procedure with recorded PASS margins.
7. Freeze a **content-addressed regression corpus** (modalities × bit-depths × photometric) with explicit acceptance criteria (lossless = bit-exact; lossy = bounded metric), gating release.
8. Promote cross-validation to a **CI gate** with documented tolerances; produce a signed verification report.

**(c) Regulatory / process**
9. Write an **intended-use statement** + **software safety classification** rationale.
10. Stand up **IEC 62304** lifecycle docs + traceability, an **ISO 14971** risk file, and an **ISO 13485**-aligned QMS.
11. Publish a **DICOM Conformance Statement**; engage **CDSCO** for classification & licensing.

---

## 10. Safe vs unsafe claims (use this language)

**DO NOT say:** "medical grade" · "medical device" · "for diagnostic use" · "clinically validated" · "FDA/CE/CDSCO approved" · "guaranteed lossless for clinical images" — all are false/unlicensed today.

**You MAY say:** "pure-Swift JPEG codec with **bit-exact lossless** (SOF3) verified for 8/12/16-bit, cross-validated against libjpeg-turbo" · "fuzz-hardened decoder (throws, does not trap, on the tested surface)" · "reads uncompressed Little-Endian DICOM pixel data" · **"experimental; not a medical device; not for diagnostic use."**

---

*Method note: produced by a fan-out of subsystem readers + adversarial verifiers + an empirical phase that built the project and round-tripped real corpus files. Several first-pass agent findings (e.g. "lossless is dead code") were **retracted** after reading the actual source — the findings above are the reconciled, code-grounded conclusions.*
