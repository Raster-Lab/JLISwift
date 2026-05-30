# JLISwift — Risk Management File Skeleton (ISO 14971, DRAFT)

> **Status: DRAFT skeleton, not a completed risk management file.**
> This is a starting-point hazard analysis in the shape of ISO 14971, produced to
> map the codec-specific hazards identified in the medical-grade audit to the
> risk controls **already implemented in code**, and to make the residual gaps
> explicit. A real risk management file requires: a risk management plan, defined
> severity/probability scales with acceptance criteria, quantified pre- and
> post-mitigation risk estimates, residual-risk and benefit-risk evaluation,
> management sign-off, and a production/post-production feedback loop. **None of
> those are present here.** Probabilities below are intentionally omitted — they
> cannot be estimated without an intended use, a use environment, and field data.
>
> JLISwift is **experimental, not a medical device, not for diagnostic use.**

Scope: the JLISwift JPEG codec + `JLIDICOM` container layer, as a software item
that could become part of, or be used by, diagnostic-imaging software (SaMD).
Library version: **0.3.0**.

---

## 1. How to read this table

Each hazard lists: the **harm** (what could reach a patient), the **cause** in
the software, the **risk controls already in code** (with evidence), and the
**residual gap** (what is not yet controlled). Severity is the *potential*
clinical severity of the harm if unmitigated; it is **not** a risk rating
(no probability is assigned). "Control verified" means a test in the suite
exercises the control.

Severity key (qualitative, illustrative): **S3** could contribute to a
missed/incorrect diagnosis (serious); **S2** degraded but recoverable;
**S1** nuisance.

---

## 2. Hazard analysis (codec / container)

### H-01 — Lossy output mistaken for diagnostic-lossless  · Severity S3
- **Harm:** a perceptually-compressed image is archived or read as if it were a
  faithful (lossless) copy; subtle findings altered by quantization are trusted.
- **Cause:** the default encode path is *lossy* perceptual; nothing previously
  distinguished lossy from lossless output.
- **Controls in code:** `JLIEncoderConfiguration.isNumericallyLossless` /
  `isLossy` flags and the `diagnosticLossless` preset make provenance explicit;
  near-lossless (point transform > 0) reports as lossy. *Verified:*
  `MedicalSafetyTests`, `ConformanceEvidenceTests` (C4-adjacent).
- **Residual gap:** the flag is advisory — nothing forces a consuming
  application/UI to honor it; there is no provenance marker embedded *in the
  output file*. A consuming product must enforce the lossy/lossless gate at its
  display/archive boundary.

### H-02 — Silent pixel corruption on decode  · Severity S3
- **Harm:** decoded pixels differ from the source without error, presenting a
  wrong image as correct.
- **Cause:** codec defects in entropy/predictor/IDCT/color paths.
- **Controls in code:** bit-exact lossless verified for predictors 1–7 at
  8/12/16-bit and cross-validated against libjpeg-turbo fixtures; IDCT meets
  ISO/IEC 10918-2 Annex A accuracy; frozen content-addressed regression corpus
  with a drift guard. *Verified:* `LosslessTests`, `ConformanceEvidenceTests`
  (C1/C2/C7), `IDCTConformanceTests`, `RegressionCorpusTests`.
- **Residual gap:** lossy DCT decode is conformance-bounded (Annex A) but not
  bit-exact by nature; cross-validation is against one reference (libjpeg-turbo),
  not a panel.

### H-03 — Decoder crash / denial of service on malformed input  · Severity S2/S3
- **Harm:** a corrupt/adversarial DICOM or JPEG crashes the reading application
  (loss of availability; in a diagnostic workflow, a crash mid-read can hide that
  an image was never shown).
- **Cause:** unvalidated header sizes, lengths, shifts → trap/OOM.
- **Controls in code:** decompression-bomb cap (`maxDecodablePixels`, 268 MP) on
  JPEG + DICOM paths; lossless point-transform validated (no negative-shift
  trap); truncated-PixelData throws; no `fatalError`/`try!` in the decode path;
  fuzz harnesses for both parsers (`try?`-probed → a trap crashes CI). *Verified:*
  `FuzzTests`, `DICOMFuzzTests`, `MedicalSafetyTests`.
- **Residual gap:** in-process fuzzing only (no ASAN / coverage-guided / out-of-
  process harness); the 268 MP ceiling is a fixed policy, not configurable per
  deployment.

### H-04 — Signed/unsigned confusion (e.g. CT Hounsfield)  · Severity S3
- **Harm:** signed pixel values (PixelRepresentation = 1) read as unsigned shift
  the intensity scale — e.g. negative Hounsfield units become large positives,
  changing tissue appearance / window behavior.
- **Cause:** treating the stored bit pattern as unsigned, or not sign-extending
  from the stored sign bit when bitsStored < bitsAllocated.
- **Controls in code:** the DICOM reader masks to `bitsStored` and sign-extends
  from the stored sign bit; the codec carries `JLIImage.isSigned`; signed data
  round-trips bit-exactly through the lossless path and is **rejected** on the
  lossy path rather than silently corrupted. *Verified:* `DICOMReaderTests`,
  `MedicalSafetyTests`, `ConformanceEvidenceTests` (C4).
- **Residual gap:** signed data on the lossy DCT path is rejected (not
  supported); a product needing lossy signed CT must offset-to-unsigned itself.

### H-05 — Photometric inversion (MONOCHROME1 vs MONOCHROME2)  · Severity S3
- **Harm:** an image displayed with inverted grayscale polarity (black↔white) can
  reverse the visual impression of dense vs lucent structures.
- **Cause:** ignoring PhotometricInterpretation on render.
- **Controls in code:** MONOCHROME1 is inverted on render; asserted as the
  photometric inverse of MONOCHROME2 end to end. *Verified:* `DICOMColorTests`.
- **Residual gap:** inversion is applied in this library's render helpers; a
  product using raw samples + its own renderer must replicate it.

### H-06 — Wrong color (YBR rendered as RGB)  · Severity S2
- **Harm:** a color (e.g. Doppler US) image shown with shifted/false colors.
- **Cause:** treating YCbCr (YBR_FULL/_422) samples as RGB.
- **Controls in code:** YBR variants converted to RGB with the full-range BT.601
  inverse on render; true RGB passes through. *Verified:* `DICOMColorTests`,
  real encapsulated US decodes to correct RGB.
- **Residual gap:** YBR_PARTIAL (video-range) and PALETTE COLOR not handled.

### H-07 — Dropped / duplicated / mis-ordered frames (cine)  · Severity S3
- **Harm:** in multi-frame US/XA cine, a missing or mis-ordered frame can hide a
  transient finding or misrepresent motion.
- **Cause:** mishandling NumberOfFrames / encapsulated fragment→frame mapping.
- **Controls in code:** NumberOfFrames parsed; encapsulated frames split via the
  Basic Offset Table (one-fragment-per-frame fallback); a lying frame count is
  clamped to the data present; verified on real 47/64-frame US cine. *Verified:*
  `DICOMWriterTests`.
- **Residual gap:** only the BOT and one-fragment-per-frame conventions are
  handled; an object with multiple fragments per frame and an *empty* BOT falls
  back to best-effort (each fragment as a frame). Frame *timing* (frame-time
  vectors) is not parsed.

### H-08 — Truncated / under-filled image read as complete  · Severity S2/S3
- **Harm:** a partially-received image displayed as if whole, with the missing
  region showing stale/zero data.
- **Cause:** silent under-fill when PixelData is shorter than the geometry.
- **Controls in code:** native short-PixelData throws `truncatedPixelData`
  instead of under-filling. *Verified:* `DICOMReaderTests`, `DICOMFuzzTests`.
- **Residual gap:** for encapsulated data the compressed length cannot be checked
  against geometry up front; a truncated compressed stream surfaces as a codec
  decode error (thrown), which is acceptable but not a geometry check.

### H-09 — Wrong window/level or rescale (display intensity)  · Severity S2
- **Harm:** a CT shown with un-rescaled values blows out to white, or a wrong
  default window hides low-contrast findings.
- **Cause:** applying window before the Modality LUT, or mis-parsing slope/intercept.
- **Controls in code:** RescaleSlope/Intercept applied *before* windowing; a
  dedicated "CT not blown white" test. *Verified:* `DICOMReaderTests`.
- **Residual gap:** only linear Rescale + first WindowCenter/Width value;
  VOI LUT Sequence and multi-valued windows not applied.

### H-10 — Non-unique identifiers on written objects  · Severity S2
- **Harm:** generated DICOM with placeholder UIDs could collide in an archive,
  causing one study to overwrite/alias another.
- **Cause:** auto-generated, non-registered UIDs.
- **Controls in code:** documented as placeholders; the writer accepts
  caller-supplied SOP/Study/Series UIDs.
- **Residual gap:** the default placeholder UIDs are *not* globally unique — a
  product must supply registered UIDs. (Documented in the Conformance Statement.)

---

## 3. Risk controls summary (what the code already gives you)

| Control | Mechanism | Evidence |
|---|---|---|
| Lossless integrity | bit-exact tests + cross-validation + frozen corpus | C1/C2, LosslessTests, RegressionCorpus |
| IDCT accuracy | ISO/IEC 10918-2 Annex A statistical bound | IDCTConformanceTests |
| Fail-safe parsing | bomb cap, length/shift validation, no traps | FuzzTests, DICOMFuzzTests |
| Signedness | mask + sign-extend; lossy rejects signed | DICOMReaderTests, MedicalSafetyTests |
| Photometric correctness | MONO1 inversion, YBR→RGB | DICOMColorTests |
| Frame integrity | NumberOfFrames + BOT, count clamp | DICOMWriterTests |
| Provenance | lossy/lossless flags + diagnostic preset | MedicalSafetyTests |
| Display correctness | rescale-before-window | DICOMReaderTests |

---

## 4. What a completed ISO 14971 file additionally requires

1. Risk management **plan** + defined severity/probability scales + acceptance criteria.
2. **Quantified** pre-/post-mitigation risk for each hazard (probability needs an intended use + field data).
3. **Residual-risk** evaluation and **benefit-risk** determination per hazard and overall.
4. Verification that each risk control is **effective** (the tests above are control verification, but must be *traced* to the risk file — see [TRACEABILITY.md](TRACEABILITY.md)).
5. **New-hazard** review of the risk controls themselves (e.g. does rejecting signed-lossy create a new hazard of refusing a valid clinical workflow?).
6. **Production / post-production** information loop (field complaints → risk re-evaluation).
7. Management review and sign-off under a QMS (ISO 13485).

---

*Draft skeleton. See [MEDICAL_GRADE_ASSESSMENT.md](../../MEDICAL_GRADE_ASSESSMENT.md) for the honest overall picture and [SOFTWARE_SAFETY_CLASSIFICATION.md](SOFTWARE_SAFETY_CLASSIFICATION.md) for intended use + IEC 62304 class rationale.*
