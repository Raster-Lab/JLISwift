# JLISwift

A native-Swift JPEG codec for Apple platforms, with Accelerate-backed DSP.

[![Swift 6.2](https://img.shields.io/badge/Swift-6.2-orange.svg)](https://swift.org)
[![Platforms](https://img.shields.io/badge/Platforms-macOS%20|%20iOS%20|%20tvOS%20|%20watchOS%20|%20visionOS-blue.svg)](#platform-support)
[![License](https://img.shields.io/badge/License-Apache%202.0-green.svg)](LICENSE)

> **Status:** experimental, pre-1.0. Today JLISwift ships a working **baseline (SOF0) JPEG encoder and decoder** in pure Swift, backed by Accelerate (`vDSP_mmul`, `vDSP_vsma`) for hot paths. The long-term goal is feature parity with Google's [jpegli](https://github.com/google/jpegli) — adaptive quantization, distance-driven quality, XYB color space, 10+ bit precision. None of those jpegli-specific features are implemented yet; see [Roadmap](#roadmap) for what's real vs. planned.

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
| RGB / RGBA / grayscale / pre-converted YCbCr input | ✅ |
| `inspect()` — metadata parse without full decode | ✅ |
| Accelerate `vDSP_mmul` DCT, `vDSP_vmul` quant, vectorized BT.601 color conversion | ✅ |
| Round-trip + cross-codec tested (ImageIO, libjpeg-turbo) on synthetic + DICOM | ✅ |
| Adaptive dead-zone quantization | ❌ planned |
| Distance-parameter quantization tuning | ❌ planned (API stub exists; ignored today) |
| 10+ bit input (`.uint16`, `.float32`) | ❌ planned (encoder rejects today) |
| XYB color space JPEG | ❌ planned (XYB transform math exists, encoder doesn't emit XYB) |
| Progressive (SOF2) encode/decode | ❌ planned (SOF2 header parses; no progressive entropy decode) |
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

The configuration fields `progressive`, `optimiseHuffman`, `adaptiveQuantization`, `distance`, and `colorSpace = .xyb` are present on `JLIEncoderConfiguration` but are not yet honored — they exist as the planned API surface.

## Encoder configuration

```swift
var config = JLIEncoderConfiguration.default
config.quality = 85.0                  // 1–100, IJG-compatible scaling
config.chromaSubsampling = .yuv444     // .yuv444, .yuv422, .yuv420, .yuv400
```

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
├── Encoder/              JLIEncoder — SOF0 encode pipeline
├── Decoder/              JLIDecoder — SOF0 decode + inspect()
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

Tests/JLISwiftTests/      89 tests across 7 suites (Swift Testing framework)
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

### DICOM corpus

`JLIBench --dicom` loads a small sample from a clinical DICOM tree
(`Sources/LocalDatasets/medical-dicom-organized/` by default), windows the
16-bit pixels to 8-bit, and runs every codec + cross pair against the
result. Files that hit unsupported transfer syntaxes (compressed-in-DICOM,
RLE) are silently skipped — only uncompressed Little Endian VR (Implicit
and Explicit, the typical CT/MR/DX/MG output) is decoded today. Converted
images are cached at `~/.cache/jlibench/corpus/`; `--rebuild-cache` clears
it.

## Roadmap

JLISwift's long-term direction is feature parity with [jpegli](https://github.com/google/jpegli) — Google's improved JPEG encoder that ships ~35% smaller files at matched visual quality. The current 0.1.x line is the foundation: a working baseline codec with measured benchmarks. Subsequent releases will progressively add the jpegli-specific features.

Next-up candidates (rough order):

1. **Distance parameter** — wire `JLIEncoderConfiguration.distance` to control quantization-table scaling (jpegli/JPEG-XL convention; lower distance = higher quality).
2. **Batched DCT** — process N blocks per `vDSP_mmul` call to amortize per-call overhead; expected 2–3× encode/decode speedup.
3. **Real-image fidelity harness** — Kodak suite + butteraugli/SSIMULACRA2 scores, not just round-trip PSNR.
4. **Adaptive dead-zone quantization** — spatially-varying quantization thresholds; the headline jpegli win.
5. **XYB color-space encoding** — perceptual color space from JPEG XL.
6. **10+ bit input** — accept `.uint16` / `.float32` source images with 8-bit backward-compatible output.
7. **Progressive (SOF2) encode & decode**.
8. **Metal hot path** — actually invoke the existing `JLIMetalPipeline` kernels from the encoder/decoder.

Done since 0.1: spec-compliance fixes (byte-unstuffing, DRI/RST decode), Accelerate-backed batched DCT, and **optimized Huffman tables** (item 8 of the original list — now matches libjpeg-turbo's `-optimize`).

## Requirements

- Swift 6.2+ (strict concurrency)
- Xcode 16.3+ for Apple platforms

## License

Apache License 2.0 — see [LICENSE](LICENSE).

## Acknowledgements

- [Google jpegli](https://github.com/google/jpegli) — the reference JPEG encoder JLISwift aspires to.
- [libjxl](https://github.com/libjxl/libjxl) — host of jpegli, source of the XYB color space and butteraugli metric.
- [libjpeg-turbo](https://github.com/libjpeg-turbo/libjpeg-turbo) — baseline JPEG reference for benchmarking.
