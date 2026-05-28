# JLISwift

A native-Swift JPEG codec for Apple platforms, with Accelerate-backed DSP.

[![Swift 6.2](https://img.shields.io/badge/Swift-6.2-orange.svg)](https://swift.org)
[![Platforms](https://img.shields.io/badge/Platforms-macOS%20|%20iOS%20|%20tvOS%20|%20watchOS%20|%20visionOS-blue.svg)](#platform-support)
[![License](https://img.shields.io/badge/License-Apache%202.0-green.svg)](LICENSE)

> **Status:** experimental, pre-1.0, Apple-only. JLISwift is a pure-Swift JPEG codec (Accelerate-backed DSP) that encodes and decodes **baseline (SOF0)**, **extended-sequential (SOF1, 12-bit)**, and **progressive (SOF2)** JPEG, with **optimized per-image Huffman tables**, **trellis (rate-distortion) quantization**, and **jpegli/JPEG-XL distance-driven quality**. It targets feature parity with Google's [jpegli](https://github.com/google/jpegli); the main feature still missing is **XYB color JPEG**. See [What's actually implemented](#whats-actually-implemented) for the full matrix.

## Quick start

```swift
dependencies: [
    .package(url: "https://github.com/Raster-Lab/JLISwift.git", from: "0.1.0"),
]
```

```swift
import JLISwift

// Encode
let image = try JLIImage(
    width: 256, height: 256,
    pixelFormat: .uint8, colorModel: .rgb,
    data: rgbBytes
)
let jpegData = try JLIEncoder().encode(image, configuration: .default)

// Decode
let decoded = try JLIDecoder().decode(from: jpegData)

// Metadata-only parse (skips entropy decode)
let info = try JLIDecoder().inspect(data: jpegData)
print(info.width, info.height, info.componentCount, info.chromaSubsampling)
```

## What's actually implemented

| Capability | Status |
|---|---|
| Baseline sequential JPEG (SOF0) encode | ✅ |
| Baseline sequential JPEG (SOF0) decode | ✅ |
| Chroma subsampling: 4:4:4, 4:2:2, 4:2:0, 4:0:0 (grayscale) | ✅ |
| Standard ITU-T T.81 Annex K Huffman tables | ✅ |
| **Optimized (per-image) Huffman tables** (Annex K.2, `optimiseHuffman`, default on) | ✅ |
| Restart marker (DRI / RST) decode — interop with ImageIO/libjpeg output | ✅ |
| Quality-scaled standard quantization tables (IJG formula) | ✅ |
| Distance parameter (jpegli/JXL convention; maps to IJG quality) | ✅ |
| RGB / RGBA / grayscale / pre-converted YCbCr input (8-bit) | ✅ |
| **12-bit grayscale** encode + decode (`.uint16` → SOF1 precision-12 JPEG) | ✅ |
| **12-bit color** encode + decode (`.uint16` RGB ↔ SOF1 precision-12 YCbCr) | ✅ |
| SOF1 (extended sequential) decode — reads 12-bit JPEGs from libjpeg/ImageIO | ✅ |
| **Progressive (SOF2) decode** — multi-scan, spectral selection, successive approximation | ✅ |
| **Progressive (SOF2) encode** — spectral-selection *and* successive-approximation scan scripts (`progressive` + `progressiveMode`, opt-in) | ✅ |
| `inspect()` — metadata parse without full decode | ✅ |
| Accelerate `vDSP_mmul` DCT, `vDSP_vmul` quant, vectorized BT.601 color conversion | ✅ |
| Round-trip + cross-codec tested (ImageIO, libjpeg-turbo, mozjpeg) on synthetic + DICOM | ✅ |
| Trellis quantization — keep/drop + HF magnitude reduction (`adaptiveQuantization`, 8-bit, default on) | ✅ |
| 16-bit / float32 input | ❌ planned (8- and 12-bit integer paths work) |
| XYB color space JPEG | ❌ planned (XYB transform math exists, encoder doesn't emit XYB) |
| Metal GPU pipeline | ⚠️ kernels compile but are not wired into encode/decode |

### Optimized Huffman tables

With `optimiseHuffman` (on by default) the encoder runs a counting pass over the
quantized coefficients, builds per-image DC/AC tables via the ITU-T T.81 Annex K.2
procedure, and embeds them in the DHT markers. Output stays fully baseline-compatible.

On the DICOM corpus this matches libjpeg-turbo's `-optimize` byte-for-byte to within
~0.5% at identical PSNR — a 21–54% size reduction over the fixed Annex K tables:

| Image @ q=50 | fixed tables | optimized | libjpeg-turbo `-optimize` |
|---|---|---|---|
| CT  | 5190 B | **2368 B** | 2383 B |
| MR  | 22982 B | **16541 B** | 16581 B |
| XA  | 35001 B | **27571 B** | 27719 B |

### Trellis quantization

With `adaptiveQuantization` (default on, 8-bit only) the encoder runs a Viterbi
rate-distortion pass per block, minimizing `D + λ·R` — DCT-domain squared error
(= pixel² by Parseval) against run-length-coded bits, λ ∝ mean AC quant step² so
truncation stays gentle at high quality. For each nonzero AC coefficient the DP
chooses to **drop** it (→0), **reduce** its magnitude one step (q→q∓1), or keep
it:

- dropping *interior* coefficients (an isolated nonzero costing a ZRL + symbol
  but barely reducing distortion) merges the surrounding zero runs;
- magnitude reduction trims a coefficient's size category + magnitude bits,
  restricted to higher frequencies (zigzag ≥ 6) — reducing the lowest AC
  frequencies costs visible quality for negligible rate;
- the EOB position falls out as "which kept coefficient is last."

Magnitudes are only reduced, never grown, so output stays standard baseline
JPEG. The rate model uses fixed Annex K table lengths, sidestepping the
chicken-and-egg with optimized Huffman (built afterward on the result).

On the DICOM corpus it trims 0.3–14.5% with butteraugli flat or better
(validated via `--butteraugli`) — keep/drop does most of that on smooth scans;
magnitude reduction adds a further ~0.1–0.5% and contributes more on
mid-magnitude (photographic) content. 12-bit stays exact round-to-nearest
(medical precision is not traded for bytes). High-entropy blocks (>32 nonzero AC
coeffs) skip the O(m²) DP, bounding worst-case encode time.
`optimiseHuffman`, `adaptiveQuantization` (trellis), `distance`, and `progressive`
are all honored. `colorSpace = .xyb` is still a stub (the XYB transform math
exists but the encoder doesn't emit XYB JPEGs yet).

On the DICOM corpus, **spectral-selection** progressive 4:4:4 is ~5% smaller
than baseline 4:4:4 at identical PSNR — the AC-scan EOBRUN codes the long runs
of DC-only blocks in flat medical regions more compactly than baseline's
per-block EOB. **Successive-approximation** progressive (opt in via
`progressiveMode = .successiveApproximation`) is only ~2% on the same corpus:
its extra scans fragment those EOB runs, so it pulls ahead only on textured /
photographic content where the finer multi-pass refinement pays off. Both are
validated on the bench against ImageIO / libjpeg-turbo / mozjpeg, which all
decode JLISwift's progressive output.

## Encoder configuration

```swift
var config = JLIEncoderConfiguration.default
config.quality = 85.0                  // 1–100, IJG-compatible scaling
config.chromaSubsampling = .yuv444     // .yuv444, .yuv422, .yuv420, .yuv400

// Or drive quality by jpegli/JPEG-XL distance (overrides quality when set).
// ~1.0 is visually lossless; larger compresses harder.
config.distance = 1.0

// Opt into progressive (SOF2) output — DC then per-component AC scans.
config.progressive = true
```

`distance` maps to an effective IJG quality (libjxl's `JpegQualityToDistance`
curve, inverted) that scales the standard quant tables — same monotonic
rate/distance behavior as jpegli, but not byte-identical since JLISwift scales
the standard tables rather than jpegli's perceptual base matrices.

## Platform support

| Platform | Acceleration |
|---|---|
| macOS 14+ | Accelerate (vDSP/vImage), Metal* |
| iOS 17+ | Accelerate, Metal* |
| tvOS 17+ | Accelerate, Metal* |
| watchOS 10+ | Accelerate |
| visionOS 1+ | Accelerate, Metal* |

\* Metal compute pipeline (`JLIMetalPipeline`) exists but is not currently invoked from the encode/decode hot path.

Universal Binary supported — `swift build` produces fat output with `#if arch(arm64)` / `#if arch(x86_64)` selection.

## Performance

Numbers from `swift run -c release JLIBench` on Apple Silicon (M-series), median of 5 runs, synthetic 512×512 inputs:

| Test | JLISwift (4:4:4, q=90) | Apple ImageIO (q=90) |
|---|---|---|
| gradient — encode | 9.7 ms | 1.0 ms |
| gradient — decode | 14.4 ms | 0.9 ms |
| noise — encode | 24.9 ms | 3.3 ms |
| noise — decode | 33.0 ms | 2.7 ms |

ImageIO is ~10× faster today. The remaining headroom is mostly batched DCT (currently one `vDSP_mmul` per 8×8 block; per-call overhead dominates), an AAN/LLM fast DCT, and SIMD-friendly Huffman encoding. Compression ratios are within a few percent of ImageIO at matched quality.

Run the benchmark yourself:

```
swift run -c release JLIBench
```

## Architecture

```
Sources/JLISwift/
├── Core/                 JLIImage, JLIError, JLIConfiguration, JLIJPEGInfo
├── Encoder/              JLIEncoder (SOF0/SOF1/SOF2 encode) + JLIProgressiveEncoder
├── Decoder/              JLIDecoder (SOF0/SOF1/SOF2 decode + inspect()) + JLIProgressiveDecoder
├── DSP/                  JLIDCT (Accelerate façade), JLIQuantization
├── Entropy/              BitWriter/BitReader (incl. JPEG byte stuffing), Huffman tables + encode/decode
├── Markers/              SOI/APP0/SOF0/DHT/DQT/SOS/EOI writer + parser
├── ColorSpace/           BT.601 RGB↔YCbCr (vDSP-vectorized), XYB transforms, chroma sub/upsampling
├── Metal/                JLIMetalPipeline — compiles MSL kernels at runtime (not yet wired)
└── Platform/             AccelerateBackend (vDSP DSP primitives), JLIPlatformCapabilities

Sources/JLIBench/
├── Codecs/               Codec protocol, JLISwift adapter, ImageIO adapter,
│                         CLICodec shell-out base + reference adapters
│                         (libjpeg-turbo / mozjpeg / jpegli), PPM IO
├── Dataset/              DICOMReader (uncompressed VR LE), DICOMCorpus loader+cache
├── Regression/           Save/load JSON baseline, diff with tolerances, exit 1 on drift
├── Harness.swift         Median-of-N timing, PSNR, self/cross runners
└── main.swift            CLI: synthetic + DICOM modes, regression flags

Tests/JLISwiftTests/      116 tests across 10 suites (Swift Testing framework)
```

## Bench: cross-codec + regression

The `JLIBench` target benchmarks JLISwift against system codecs and tracks
regressions across runs.

```bash
swift run -c release JLIBench                           # synthetic corpus
swift run -c release JLIBench --dicom                   # + DICOM corpus
swift run -c release JLIBench --save-baseline b.json    # snapshot
swift run -c release JLIBench --check-baseline b.json   # exit 1 on regression
```

### Reference codecs (auto-detected)

The bench probes for these external encoders and includes any that are
installed. Cross-codec pairs are generated automatically: `JLISwift →
each-reference` and `each-reference → JLISwift`.

| Codec | Install | Probed path |
|---|---|---|
| **libjpeg-turbo** | `brew install jpeg-turbo` | `/opt/homebrew/opt/jpeg-turbo/bin/{cjpeg,djpeg}` |
| **mozjpeg** | `brew install mozjpeg` | `/opt/homebrew/opt/mozjpeg/bin/{cjpeg,djpeg}` |
| **jpegli** | `brew install jpegli` or build libjxl with `JPEGXL_ENABLE_TOOLS=ON` | `/opt/homebrew/opt/jpegli/bin/cjpegli` |

The bench prints active vs inactive codecs at startup. Per-codec binary
paths can also be overridden via env vars (`JLIBENCH_LIBJPEG_TURBO_BIN`,
`JLIBENCH_MOZJPEG_BIN`, `JLIBENCH_JPEGLI_BIN`).

External codecs spawn a process per encode/decode (~70 ms overhead each on
macOS) so the harness times them with a single sample rather than the
median-of-5 it uses for native codecs. Bytes and PSNR are unaffected.

### Perceptual metric (butteraugli)

`--butteraugli` adds a butteraugli perceptual-distance column to self-codec
rows (lower is better; ~1.0 = just-noticeable-difference). It shells out to
libjxl's `butteraugli_main` (Homebrew `jpeg-xl`), comparing the original and
round-tripped images. This is the right metric for perceptually-tuned
techniques — PSNR can't see them. Slow (a process per row), so it's opt-in.

### DICOM corpus

`JLIBench --dicom` loads a small sample from a clinical DICOM tree
(`Sources/LocalDatasets/medical-dicom-organized/` by default), windows the
16-bit pixels to 8-bit, and runs every codec + cross pair against the
result. Files that hit unsupported transfer syntaxes (compressed-in-DICOM,
RLE) are silently skipped — only uncompressed Little Endian VR (Implicit
and Explicit, the typical CT/MR/DX/MG output) is decoded today. Converted
images are cached at `~/.cache/jlibench/corpus/`; `--rebuild-cache` clears
it.

`--dicom12` runs the corpus at **native 12-bit precision** instead of
window/leveling to 8-bit: each image is rendered to 12-bit grayscale
(0–4095) and round-tripped through JLISwift and libjpeg-turbo's 12-bit
mode (`cjpeg -precision 12`), with PSNR measured against the 4095 peak.
This is the medically-relevant path — it preserves the tonal resolution
8-bit discards. On the corpus JLISwift matches libjpeg-turbo-12 within
~0.1% bytes at 67–83 dB PSNR (vs 44–59 dB for the 8-bit path), and
JLISwift ↔ libjpeg-turbo-12 cross-decode passes both directions.

## Roadmap

JLISwift's long-term direction is feature parity with [jpegli](https://github.com/google/jpegli) — Google's improved JPEG encoder that ships ~35% smaller files at matched visual quality. The 0.1.x line already covers baseline, extended-sequential (12-bit), and progressive JPEG with optimized Huffman, trellis quantization, and distance-driven quality; subsequent releases add the remaining jpegli-specific features.

Next-up candidates (rough order):

Remaining:

1. **XYB color-space encoding** — perceptual color space from JPEG XL; the transform math exists but the encoder doesn't emit XYB JPEGs.
2. **16-bit / float32 input** — wider source formats (8- and 12-bit integer paths work).
3. **Metal hot path** — actually invoke the existing `JLIMetalPipeline` kernels (marginal over the Accelerate CPU path).

Done since 0.1 — all cross-validated against libjpeg-turbo, mozjpeg, and ImageIO with PSNR + butteraugli, regression-tracked: spec-compliance fixes (byte-unstuffing, DRI/RST, SOF1), Accelerate-backed batched DCT, **optimized Huffman tables** (≈ libjpeg-turbo `-optimize`), **12-bit grayscale and color** encode/decode, **distance parameter**, **trellis quantization** (keep/drop + HF magnitude reduction), **progressive (SOF2) decode and encode** (spectral selection + successive approximation), and **fuzz-hardened decoding** (throws, never traps, on malformed input).

## Requirements

- Swift 6.2+ (strict concurrency)
- Xcode 26+ for Apple platforms

## License

Apache License 2.0 — see [LICENSE](LICENSE).

## Acknowledgements

- [Google jpegli](https://github.com/google/jpegli) — the reference JPEG encoder JLISwift aspires to.
- [libjxl](https://github.com/libjxl/libjxl) — host of jpegli, source of the XYB color space and butteraugli metric.
- [libjpeg-turbo](https://github.com/libjpeg-turbo/libjpeg-turbo) — baseline JPEG reference for benchmarking.
