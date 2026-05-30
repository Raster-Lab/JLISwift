# JLISwift — Intended Use & Software Safety Classification (DRAFT)

> **Status: DRAFT rationale, not a regulatory determination.**
> This document drafts an intended-use statement and a software safety
> classification rationale in the shape of IEC 62304, to seed the lifecycle
> documentation a SaMD program would require. It is **not** a cleared intended
> use, **not** a manufacturer's classification of record, and confers no
> regulatory status. The actual classification depends on the *finished product's*
> intended use and use environment, which JLISwift (a library) does not fix.
>
> **JLISwift today is experimental, pre-1.0, not a medical device, and not for
> diagnostic use.**

Library version: **0.3.0**.

---

## 1. What JLISwift is

JLISwift is a **software library** (a pure-Swift JPEG codec + a `JLIDICOM`
read/write container layer). It is a *component*, not a finished application. It
has no user interface, makes no clinical claim, performs no diagnosis, and does
not by itself constitute a medical device. Whether a *product built on it* is a
medical device — and at what risk class — is determined by that product's
intended use, not by this library.

## 2. Draft intended-use statement (for a hypothetical product using JLISwift)

> *"To losslessly compress, decompress, store, and retrieve diagnostic medical
> images (DICOM) for archival and transmission, preserving pixel values
> bit-for-bit, as a component of a medical-imaging software system. Lossy
> compression, when offered, is explicitly labeled and gated away from primary
> diagnostic interpretation."*

This is a **drafting aid** for a downstream manufacturer, not JLISwift's own
claim. Key intended-use decisions a manufacturer must make (each changes the
classification):

- **Primary diagnostic display** vs archival/transmission only.
- **Lossless only** vs lossy permitted (and for what).
- **Modalities / body parts** in scope.
- **Autonomy**: does a clinician always view the original, or can the codec's
  output be the sole basis of a read?

## 3. IEC 62304 software safety classification

IEC 62304 classifies software by the **worst-case harm** a software failure
could contribute to, *after* considering risk controls external to the software:

- **Class A** — no injury or damage to health is possible.
- **Class B** — non-serious injury is possible.
- **Class C** — death or serious injury is possible.

### 3.1 Rationale

A diagnostic-image codec sits on the path between acquisition and the clinician's
eye. A failure mode such as **silent pixel corruption** or **lossy-output-treated-
as-lossless** could contribute to a missed or incorrect diagnosis — a serious
injury. Absent external risk controls that guarantee a clinician always reviews
an independent original, the realistic worst case places a codec used in a
diagnostic pathway at **Class B, and plausibly Class C**.

| Intended use of the finished product | Likely 62304 class |
|---|---|
| Lossless archival/transmission only, original always independently available | B (arguably A with strong external controls) |
| Lossy compression in the diagnostic pathway | C |
| Codec output is the basis of primary diagnostic read | C |

**Conservative working assumption for planning: Class B/C.** A manufacturer
should classify formally against IEC 62304 §4.3 with their specific architecture
and risk controls, and may **segregate** the safety-critical items (the
bit-exact lossless path, the fail-safe parser) to bound the Class C surface.

### 3.2 What the class implies (and current status)

For Class B/C, IEC 62304 requires (not exhaustive):

| Requirement | Status in JLISwift |
|---|---|
| Software development plan / lifecycle | **Absent** (git + ROADMAP, not a controlled SDLC) |
| Software requirements specification | **Absent** (behavior implicit in code/tests/README) |
| Software architecture (+ segregation of risk-control items for C) | **Absent** (modular code exists; not documented as architecture) |
| Detailed design | **Absent** |
| Unit/integration/system verification with pass/fail criteria | **Partial** — a real, CI-gated test suite (215 tests) with explicit acceptance criteria exists ([TRACEABILITY.md](TRACEABILITY.md)), but it is not a controlled, signed V&V record |
| Requirements → design → code → test traceability | **Seeded** ([TRACEABILITY.md](TRACEABILITY.md)) — covers the safety-critical claims only |
| SOUP / third-party management | **Absent** — Apple Accelerate/Foundation, the Swift runtime, and (in tooling) libjxl/libjpeg-turbo are unmanaged |
| Problem resolution (clause 9) + change control | **Absent** (git is not change control under a QMS) |

## 4. SOUP inventory (starting point)

A 62304 SOUP (Software Of Unknown Provenance) list a manufacturer must complete:

| Item | Use | Notes |
|---|---|---|
| Apple Accelerate / vDSP / vImage | DSP (DCT, color, quant) | OS-bundled; version tied to OS; no source |
| Apple Foundation / Swift stdlib + runtime | language/runtime | OS/toolchain-bundled |
| CryptoKit | test corpus hashing (test target only) | not in shipping library path |
| libjpeg-turbo `cjpeg`/`djpeg` | **test/bench tooling only** | cross-validation fixtures are pre-baked; not a runtime dependency |
| libjxl (butteraugli / jpegli ref) | **bench tooling only** | not in the library |

Note: the *shipping library* (`JLISwift` + `JLIDICOM`) has **no third-party
package dependencies** — only Apple system frameworks. That materially shrinks
the SOUP surface a manufacturer must manage.

## 5. Regulatory pathway pointers (informational)

- **India (CDSCO, primary for Raster Lab):** Medical Device Rules 2017 +
  software/SaMD guidance; standalone diagnostic-imaging software is commonly
  Class B or C; licensing via the CDSCO MD Online portal; an ISO 13485-based QMS
  is effectively required for higher classes. **No "medical grade" / device
  claim may be made pre-license.**
- **US FDA (if marketed there):** SaMD; 510(k) if a predicate exists (image
  storage/communication / image-processing product codes) or De Novo; FDA
  premarket software + cybersecurity documentation; consider a Predetermined
  Change Control Plan for codec/algorithm updates.
- **EU (if marketed there):** MDR 2017/745, Rule 11 (decision/diagnostic
  software typically Class IIa+), Notified Body conformity assessment, CE mark.

---

*Draft. See [MEDICAL_GRADE_ASSESSMENT.md](../../MEDICAL_GRADE_ASSESSMENT.md) §8–10 for the full framework gap analysis and safe-vs-unsafe claim language.*
