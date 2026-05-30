# JLISwift — DICOM Conformance Statement (DRAFT)

> **Status: DRAFT / engineering reference, not a released conformance claim.**
> This document describes, in the shape of a DICOM PS3.2 Conformance Statement,
> the DICOM behavior of the `JLIDICOM` module as implemented today. It is a
> working engineering artifact produced to make the supported/unsupported
> surface explicit and to seed a future formal statement. It has **not** been
> reviewed, validated against a DICOM validator (dciodvfy / dcmtk), or approved
> as a product conformance claim. Do not cite it as evidence of conformance.
>
> Scope note: JLISwift is **experimental, pre-1.0, not a medical device, and not
> for diagnostic use.** See [MEDICAL_GRADE_ASSESSMENT.md](../../MEDICAL_GRADE_ASSESSMENT.md).

Library version at time of writing: **0.3.0** (`JLISwift.version`).
Implementation: `Sources/JLIDICOM/DICOMReader.swift`, `Sources/JLIDICOM/DICOMWriter.swift`.

---

## 0. Conformance overview

JLISwift's DICOM layer is a **file-level (PS3.10) read/write library for the
Image Pixel module**, paired with the JLISwift JPEG codec for the encapsulated
(compressed) transfer syntaxes. It is **not** a networked application — there is
no DIMSE / DICOM Upper Layer / SCU / SCP role, no association negotiation, and no
storage/query/retrieve services. The tables below therefore cover media
(file) interchange only.

| Capability | Supported |
|---|---|
| Read DICOM Part-10 files (preamble + DICM + File Meta + dataset) | Yes |
| Write DICOM Part-10 files | Yes (Secondary Capture) |
| Native (uncompressed) pixel data | Read + Write |
| Encapsulated (JPEG-compressed) pixel data | Read + Write |
| Multi-frame | Read + Write |
| Networked DICOM (DIMSE / C-STORE / Q-R / MPPS …) | **No** |
| Structured Reports, Presentation States, Waveforms, RT, SEG | **No** |

---

## 1. Transfer syntaxes

### 1.1 Read (decode)

| Transfer Syntax UID | Name | Status |
|---|---|---|
| `1.2.840.10008.1.2` | Implicit VR Little Endian | **Supported** |
| `1.2.840.10008.1.2.1` | Explicit VR Little Endian | **Supported** |
| `1.2.840.10008.1.2.4.50` | JPEG Baseline (Process 1) | **Supported** (codec-decoded) |
| `1.2.840.10008.1.2.4.51` | JPEG Extended (Process 2 & 4) | **Supported** (codec-decoded) |
| `1.2.840.10008.1.2.4.57` | JPEG Lossless (Process 14) | **Supported** (codec-decoded) |
| `1.2.840.10008.1.2.4.70` | JPEG Lossless, First-Order Prediction (Process 14 SV1) | **Supported** (codec-decoded) |
| `1.2.840.10008.1.2.2` | Explicit VR Big Endian (retired) | Not supported — throws |
| `1.2.840.10008.1.2.5` | RLE Lossless | Not supported — throws |
| `1.2.840.10008.1.2.4.80/.81` | JPEG-LS | Not supported — throws |
| `1.2.840.10008.1.2.4.90/.91` | JPEG 2000 | Not supported — throws |

For the encapsulated JPEG syntaxes the reader extracts the compressed stream(s);
the caller decodes them with the JLISwift codec (the `JLIDICOM` module is
codec-agnostic by design). Encapsulated framing is parsed per PS3.5 §A.4 (Basic
Offset Table + fragment items + Sequence Delimitation Item).
*Evidence:* `DICOMReader.encapsulatedTransferSyntaxes`; `DICOMReader.read` transfer-syntax switch; `DICOMWriterTests`, `ConformanceEvidenceTests` (C5).

An unsupported transfer syntax **fails loud** — `DICOMReader.read` throws
`DICOMError.unsupportedTransferSyntax`; it never silently mis-decodes.

### 1.2 Write (encode)

| Transfer Syntax UID | Name | Status |
|---|---|---|
| `1.2.840.10008.1.2.1` | Explicit VR Little Endian | **Supported** (native pixel data) |
| `1.2.840.10008.1.2.4.50` | JPEG Baseline | **Supported** (encapsulated, caller-provided stream) |
| `1.2.840.10008.1.2.4.70` | JPEG Lossless SV1 | **Supported** (encapsulated, caller-provided stream) |
| Implicit VR LE | — | Not produced (reader-only) |

The writer always emits the dataset as Explicit VR Little Endian; the chosen
transfer syntax in File Meta selects native vs encapsulated PixelData framing.

---

## 2. SOP classes

The writer produces **Secondary Capture Image Storage**
(`1.2.840.10008.5.1.4.1.1.7`) — the appropriate generic class for pixel data the
library synthesizes/transcodes rather than acquires from a modality. The reader
does **not** validate or branch on SOP Class UID; it reads any dataset that
carries a supported transfer syntax and a parseable Image Pixel module.

| Role | SOP Class |
|---|---|
| Write | Secondary Capture Image Storage `1.2.840.10008.5.1.4.1.1.7` |
| Read | SOP-Class-agnostic (reads the pixel module of any object) |

**Limitation:** modality-specific IOD attributes (CT/MR/US/XA acquisition
parameters, frame-of-reference, etc.) are **not** parsed or written. Files
produced are valid Secondary Capture pixel containers, not modality IODs.

---

## 3. Image Pixel module — attributes honored

### 3.1 Read

| Tag | Attribute | Behavior |
|---|---|---|
| (0028,0010) | Rows | Parsed; validated 1…65535 |
| (0028,0011) | Columns | Parsed; validated 1…65535 |
| (0028,0100) | BitsAllocated | Parsed; 8 or 16 paths (other values mishandled — see §5) |
| (0028,0101) | BitsStored | Parsed; **masked** to significant bits |
| (0028,0102) | HighBit | Parsed; used to sign-extend signed data |
| (0028,0103) | PixelRepresentation | Parsed; 0 unsigned / 1 signed two's-complement, sign-extended from the stored sign bit |
| (0028,0002) | SamplesPerPixel | Parsed; 1 (mono) or 3 (color) |
| (0028,0006) | PlanarConfiguration | Parsed; 0 interleaved / 1 planar (color), reassembled on render |
| (0028,0004) | PhotometricInterpretation | Parsed; MONOCHROME1 (inverted), MONOCHROME2, RGB, YBR_FULL/YBR_FULL_422 (→RGB) |
| (0028,0008) | NumberOfFrames | Parsed; multi-frame exposed via `frame(_:)`; lying count clamped to data present |
| (0028,1052) | RescaleIntercept | Parsed; applied as Modality LUT before windowing |
| (0028,1053) | RescaleSlope | Parsed; applied as Modality LUT before windowing |
| (0028,1050) | WindowCenter | Parsed (first value); used for default display window |
| (0028,1051) | WindowWidth | Parsed (first value); used for default display window |
| (0008,0060) | Modality | Parsed (informational; e.g. CT window presets) |
| (7FE0,0010) | PixelData | Parsed; native or encapsulated (BOT + fragments) |

*Evidence:* `DICOMReader` tag constants + parse loop; `DICOMReaderTests`, `DICOMColorTests`, `DICOMWriterTests`.

### 3.2 Write

The writer emits the attributes above that are set on the `DICOMWriter.PixelModule`
(SamplesPerPixel, PhotometricInterpretation, PlanarConfiguration [color],
NumberOfFrames [>1], Rows, Columns, BitsAllocated, BitsStored, HighBit,
PixelRepresentation, optional Rescale/Window, Modality) plus the minimum
identifying UIDs (SOP Class/Instance, Study/Series Instance). Placeholder UIDs
under the example root `1.2.826.0.1.3680043.*` are generated when not supplied —
**these are not globally unique; supply registered UIDs for production use.**

---

## 4. Safety / robustness behavior (fail-safe)

The reader is hardened to **fail safe** (throw a clean `DICOMError`, never trap)
on malformed input — relevant because the DICOM file is the untrusted front door
for clinical data.

| Condition | Behavior |
|---|---|
| Missing DICM magic / too short | throws `.notDICOM` / `.truncated` |
| Unsupported transfer syntax | throws `.unsupportedTransferSyntax` |
| Rows×Columns×Samples beyond 268 MP (decompression bomb) | throws `.imageTooLarge` |
| Per-dimension > 65535 | throws `.invalidGeometry` |
| Native PixelData shorter than declared geometry | throws `.truncatedPixelData` |
| Malformed encapsulated framing | throws `.invalidPixelData` |
| Undefined-length sequences, lying element lengths, byte corruption | parsed/skipped safely; never traps |

*Evidence:* `DICOMFuzzTests` (truncation, byte mutation, hostile lengths, bomb geometry, fragment corruption, nested sequences — all `try?`-probed so a trap would crash CI).

---

## 5. Explicit limitations (NOT supported)

This list is part of the conformance claim — what is **out of scope today**:

- **Networking**: no DIMSE / association / SCU / SCP / Storage / Q-R / MPPS.
- **Transfer syntaxes**: Explicit VR Big Endian, RLE, JPEG-LS, JPEG 2000.
- **SOP classes other than Secondary Capture** on write; no modality-IOD attribute set.
- **BitsAllocated other than 8 or 16** (e.g. 1-bit overlays, 32-bit float pixels).
- **12-bit *packed* pixel data** (the rare bit-packed encoding) — only 8/16-bit containers.
- **PALETTE COLOR** photometric (no color LUT application); **YBR_PARTIAL_*** (video-range) not auto-converted; **YBR_ICT/RCT** (JPEG-2000-internal) N/A.
- **Multi-valued VOI / VOI LUT Sequence**, modality LUT *sequence* (only linear Rescale Slope/Intercept), Presentation LUT.
- **Overlays, ICC profiles in the DICOM object, private attributes, sequences** (sequences are skipped, not interpreted).
- **Pixel Padding Value, Smallest/Largest Pixel Value** — not applied.
- **DICOMDIR / media directories**, character-set handling beyond ASCII for the parsed string attributes.

---

## 6. Validation status

- **Not** run through `dciodvfy` / `dcmtk dcmdump` / a commercial validator.
- Read path exercised on a real multi-modality corpus (CT/DX/MG/MR/US/XA) via
  `JLIBench --signed-stats` (native single-frame lossless round-trips bit-exact)
  and on real encapsulated + multi-frame US studies.
- Write path validated only by **round-trip** against this library's own reader
  (`DICOMWriterTests`), **not** by an independent DICOM toolkit.

A formal conformance statement requires: independent validator confirmation,
interoperability testing against at least one third-party DICOM toolkit (read
*and* write), and registered UID roots.

---

*This is a draft engineering reference. For the honest overall readiness picture
see [MEDICAL_GRADE_ASSESSMENT.md](../../MEDICAL_GRADE_ASSESSMENT.md).*
