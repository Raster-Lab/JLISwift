# JLISwift — Requirements → Verification Traceability (DRAFT seed)

> **Status: DRAFT seed, not a controlled traceability matrix.**
> This maps the **safety-critical software requirements** (derived from the
> medical-grade audit and the risk-file skeleton) to the automated tests that
> verify them, so the existing CI suite becomes *traced* evidence rather than
> ad-hoc tests. It covers the safety-critical surface only — not every feature.
> A controlled IEC 62304 traceability matrix additionally requires: a numbered,
> version-controlled Software Requirements Specification; design elements linked
> in; signed verification records; and bidirectional trace (requirement ↔ design
> ↔ code ↔ test ↔ risk control). This seed has requirement ↔ test ↔ risk only.

Library version: **0.3.0**. All cited tests run in CI (`.github/workflows/ci.yml`
"Medical conformance evidence" step) and in the full `swift test` suite
(215 tests / 25 suites green at time of writing).

---

## Safety-critical requirements & verification

| Req ID | Requirement (shall) | Verifying test(s) | Risk control |
|---|---|---|---|
| **SR-01** | Lossless (SOF3) encode→decode shall reconstruct pixels **bit-exactly** at 8/12/16-bit for predictors 1–7 (gray + RGB). | `ConformanceEvidenceTests.c1LosslessBitExact`; `LosslessTests.losslessEncodeRoundTrip`, `.color*`, `.bit16*` | H-02 |
| **SR-02** | Lossless decode shall match an **independent reference codec** (libjpeg-turbo `cjpeg`) bit-exactly on fixed fixtures, with no external tool at test time. | `ConformanceEvidenceTests.c2CrossValidation`; `LosslessTests.losslessPredictor1/7`; `ScaledDecodeConformanceTests` | H-02 |
| **SR-03** | Near-lossless shall bound the maximum per-pixel error to **2^Pt − 1**. | `ConformanceEvidenceTests.c3NearLosslessBound`; `RegressionCorpusTests` (`mr-12u` case) | H-01, H-02 |
| **SR-04** | Signed pixel data shall round-trip **bit-exactly** through the lossless path; the lossy path shall **reject** signed input (no silent corruption). | `ConformanceEvidenceTests.c4Signed`; `MedicalSafetyTests.signedLosslessRoundTrip`, `.signedLossyIsRejected` | H-04 |
| **SR-05** | Encapsulated JPEG-in-DICOM shall reconstruct pixels **bit-exactly** end to end (encode → encapsulate → read → decode). | `ConformanceEvidenceTests.c5Encapsulation`; `DICOMWriterTests.encapsulatedLosslessRoundTrip` | H-02 |
| **SR-06** | The inverse DCT shall meet the **ISO/IEC 10918-2 Annex A** accuracy bounds over the three specified input ranges. | `IDCTConformanceTests.fullRange`, `.smallRange`, `.overRange` | H-02 |
| **SR-07** | The JPEG decoder shall **fail safe** (throw, never trap) on malformed/truncated/adversarial input. | `FuzzTests.*` (truncations, mutations, marker-length, metadata, scaled) | H-03 |
| **SR-08** | The DICOM reader shall **fail safe** on malformed input (bad headers, lying lengths, sequences, encapsulated framing, bomb geometry). | `DICOMFuzzTests.truncations`, `.singleByteMutations`, `.lengthFieldFuzz`, `.hostileGeometry`, `.randomBytes`, `.encapsulatedFragmentFuzz`, `.sequenceFuzz` | H-03 |
| **SR-09** | The decoder shall reject **decompression-bomb** geometry before allocation (≤ 268 MP cap). | `DICOMFuzzTests.hostileGeometry`; `DICOMReaderTests` (image-too-large); `MedicalSafetyTests` | H-03 |
| **SR-10** | Signed/narrow stored values shall be **masked to bitsStored and sign-extended** from the stored sign bit. | `DICOMReaderTests` (signed 12-in-16, masking); `ConformanceEvidenceTests.c4Signed` | H-04 |
| **SR-11** | MONOCHROME1 shall render as the **photometric inverse** of MONOCHROME2. | `DICOMColorTests.monochrome1Inversion` | H-05 |
| **SR-12** | YBR_FULL / YBR_FULL_422 shall be **converted to RGB**; true RGB shall pass through unchanged. | `DICOMColorTests.ybrFullToRGB`, `.ybr422IsConverted`, `.rgbPassthrough` | H-06 |
| **SR-13** | Multi-frame data shall expose the correct **frame count** and per-frame pixels; a lying NumberOfFrames shall be **clamped** to the data present. | `DICOMWriterTests.encapsulatedMultiFrame`, `.nativeMultiFrame`, `.lyingFrameCountClamped` | H-07 |
| **SR-14** | Native PixelData shorter than the declared geometry shall be **rejected**, not silently under-filled. | `DICOMReaderTests` (truncated PixelData); `DICOMFuzzTests` | H-08 |
| **SR-15** | RescaleSlope/Intercept shall be applied **before** windowing (Modality LUT order). | `DICOMReaderTests` (rescale-before-window / CT-not-blown-white) | H-09 |
| **SR-16** | Encode configuration shall expose **lossy vs lossless provenance** (`isNumericallyLossless` / `isLossy`); the default shall report lossy. | `MedicalSafetyTests.defaultConfigurationIsLossy`, `.diagnosticLosslessIsNumericallyLossless`, `.nearLosslessIsReportedLossy`, `.plainLosslessConfigurationIsLossless` | H-01 |
| **SR-17** | The frozen regression corpus shall be **content-addressed** (SHA-256 drift guard) and each case shall meet its acceptance criterion. | `RegressionCorpusTests.runCorpus`, `.corpusManifest` | H-02 |

---

## Coverage notes & gaps

- **Covered:** the safety-critical claims above each have at least one automated,
  CI-gated test. SR-01…SR-06 and SR-16…SR-17 print machine-readable
  `CONFORMANCE` / `MANIFEST` records (archived as a CI artifact).
- **Not yet traced:** general feature requirements (progressive, XYB, metadata,
  scaled decode) are tested but not in this safety matrix; they are not
  safety-critical for the lossless-archival intended use.
- **Missing for a controlled matrix:** a numbered SRS document, design-element
  links, signed verification records, and the reverse trace (test → requirement →
  risk control → residual risk). The risk-control column links to
  [RISK_MANAGEMENT_SKELETON.md](RISK_MANAGEMENT_SKELETON.md) hazard IDs as the
  forward half of that trace.

---

*Draft seed. Regenerate the test-name references if tests are renamed (they are
asserted to exist at the cited names as of 0.3.0 / this branch).*
