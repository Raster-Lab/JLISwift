# JLISwift — Regulatory Scaffolding (DRAFT)

> **These are draft engineering artifacts, not regulatory records.** They exist
> to make the project's medical-readiness surface explicit and to seed the
> documentation a Software-as-a-Medical-Device (SaMD) program would require. None
> has been reviewed, validated, or approved as a regulatory deliverable, and none
> confers any regulatory status.
>
> **JLISwift is experimental, pre-1.0, not a medical device, and not for
> diagnostic use.**

This directory is the **WS-M3** deliverable of the 0.4.0 "medical foundations"
roadmap. It is the *on-ramp* to a regulatory pathway, deliberately grounded in
the actual code so the claims match the implementation rather than aspiration.

## Documents

| Document | What it is | Maturity |
|---|---|---|
| [DICOM_CONFORMANCE_STATEMENT.md](DICOM_CONFORMANCE_STATEMENT.md) | PS3.2-shaped statement of the supported/unsupported DICOM surface (transfer syntaxes, SOP, pixel module), read + write, with explicit limitations | Draft; not validator-confirmed |
| [RISK_MANAGEMENT_SKELETON.md](RISK_MANAGEMENT_SKELETON.md) | ISO 14971-shaped hazard analysis: 10 codec/container hazards mapped to the risk controls **already in code**, with residual gaps | Draft skeleton; no probabilities / sign-off |
| [SOFTWARE_SAFETY_CLASSIFICATION.md](SOFTWARE_SAFETY_CLASSIFICATION.md) | Draft intended-use statement + IEC 62304 software-safety-class (A/B/C) rationale + SOUP inventory | Draft rationale; not a determination |
| [TRACEABILITY.md](TRACEABILITY.md) | Requirements (SR-01…SR-17) → verifying test → risk control matrix, turning the CI suite into traced evidence | Draft seed; safety-critical surface only |

## How these fit together

```
Intended use ──► Safety classification (62304 A/B/C)
       │
       ▼
   Hazards (ISO 14971 skeleton) ──┐
       │                          │ risk controls
       ▼                          ▼
 Requirements (SR-xx) ──────► Verifying tests (CI-gated)
       (TRACEABILITY.md)        (ConformanceEvidence, Fuzz, IDCT, …)
       │
       ▼
 DICOM Conformance Statement (what the code actually does)
```

## What is still required for an actual claim

These drafts are a fraction of a regulatory submission. Still needed (0.5.0+,
process-led — see the [ROADMAP](../../ROADMAP.md) "0.5.0+ — Regulatory pathway"):

- A controlled **IEC 62304** lifecycle: SDLC plan, numbered SRS, architecture
  with risk-control segregation, signed V&V records, problem-resolution & change
  control under a QMS.
- A completed **ISO 14971** risk file: plan, severity/probability scales,
  quantified pre-/post-mitigation risk, residual-risk & benefit-risk evaluation,
  management sign-off, post-production loop.
- An **ISO 13485** QMS / Design History File.
- **Validator-confirmed** DICOM conformance + third-party interoperability testing
  (read *and* write) and registered UID roots.
- A market regulatory pathway: **India CDSCO** (Medical Device Rules 2017)
  classification + licensing, and/or US FDA SaMD / EU MDR as applicable.

For the honest overall readiness picture and safe-vs-unsafe claim language, see
[MEDICAL_GRADE_ASSESSMENT.md](../../MEDICAL_GRADE_ASSESSMENT.md).
