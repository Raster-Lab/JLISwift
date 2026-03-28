# JLISwift

A hardware-accelerated, native Swift implementation of Google's [jpegli](https://github.com/google/jpegli) JPEG compression algorithm.

[![Swift 6.0](https://img.shields.io/badge/Swift-6.0-orange.svg)](https://swift.org)
[![Platforms](https://img.shields.io/badge/Platforms-macOS%20|%20iOS%20|%20tvOS%20|%20watchOS%20|%20visionOS%20|%20Linux-blue.svg)](#platform-support)
[![License](https://img.shields.io/badge/License-Apache%202.0-green.svg)](LICENSE)

JLISwift provides encoding and decoding of JPEG images using the jpegli algorithm, achieving up to **35% better compression ratios** compared to traditional JPEG encoders while maintaining **full backward compatibility** with every standard JPEG decoder. The library supports advanced features including **10+ bit per component encoding** and **XYB color space JPEG**.

## Features

| Feature | Description |
|---|---|
| **jpegli-compatible encoding** | Adaptive quantization, optimised quantization matrices, floating-point precision pipeline |
| **jpegli-compatible decoding** | Auto-detects 10+ bit precision, XYB color space, progressive scans |
| **10+ bit per component** | Encode 16-bit and float32 sources; backward-compatible output viewable as standard 8-bit JPEG |
| **XYB color space JPEG** | Perceptual color space from JPEG XL for superior quality at low bitrates |
| **Hardware acceleration** | Accelerate (vDSP/vImage), ARM NEON, Apple AMX, Intel SSE/AVX, Metal GPU compute |
| **Swift 6 strict concurrency** | `Sendable` types throughout, data-race safe by design |
| **Cross-platform** | macOS, iOS, tvOS, watchOS, visionOS, and Swift on Linux |
| **Universal Binary** | Separately optimised paths for Apple Silicon (arm64) and Intel (x86\_64) |

## Quick Start

Add JLISwift to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/Raster-Lab/JLISwift.git", from: "0.1.0"),
]
```

```swift
import JLISwift

// Encode an image
let encoder = JLIEncoder()
let jpegData = try encoder.encode(image, configuration: .default)

// Decode a JPEG
let decoder = JLIDecoder()
let image = try decoder.decode(from: jpegData)

// Inspect a JPEG for advanced features
let info = try decoder.inspect(data: jpegData)
if info.isExtendedPrecision {
    print("This JPEG uses 10+ bit precision")
}
if info.isXYB {
    print("This JPEG uses XYB color space")
}
```

### Encoder Configuration

```swift
var config = JLIEncoderConfiguration.default

// Standard quality-based encoding
config.quality = 85.0

// Or use jpegli's distance parameter (overrides quality)
config.distance = 1.0  // visually lossless

// XYB color space for perceptual quality
config.colorSpace = .xyb

// Control chroma subsampling
config.chromaSubsampling = .yuv444  // no subsampling

// Enable adaptive quantization (default)
config.adaptiveQuantization = true
```

### Pixel Formats

JLISwift supports multiple input/output precisions:

| Format | Description | Use case |
|---|---|---|
| `.uint8` | 8-bit unsigned integer | Standard JPEG, maximum compatibility |
| `.uint16` | 16-bit unsigned integer | 10+ bit encoding, medical/scientific imaging |
| `.float32` | 32-bit floating point | HDR workflows, linear light processing |

## Platform Support

| Platform | Architecture | Acceleration |
|---|---|---|
| macOS 14+ | Apple Silicon (arm64) | Accelerate, NEON, AMX, Metal |
| macOS 14+ | Intel (x86\_64) | Accelerate, SSE/AVX, Metal |
| iOS 17+ | arm64 | Accelerate, NEON, Metal |
| tvOS 17+ | arm64 | Accelerate, NEON, Metal |
| watchOS 10+ | arm64 | Accelerate, NEON |
| visionOS 1+ | arm64 | Accelerate, NEON, Metal |
| Linux | x86\_64 | SSE/AVX |
| Linux | arm64 | NEON |

Universal Binaries are supported — `swift build` produces a fat binary with separately optimised code paths for each architecture, selected at compile time via `#if arch(arm64)` / `#if arch(x86_64)`.

## Architecture

```
JLISwift
├── Core/                  Types, errors, configuration
│   ├── JLIImage           Pixel buffer container (8/16/32-bit)
│   ├── JLIError           Typed error enum
│   ├── JLIConfiguration   Encoder & decoder settings
│   └── JLIJPEGInfo        Decoded JPEG metadata
├── Encoder/               JPEG compression pipeline
│   └── JLIEncoder         jpegli-compatible encoder
├── Decoder/               JPEG decompression pipeline
│   └── JLIDecoder         jpegli-compatible decoder (auto-detects features)
└── Platform/              Compile-time platform detection
    └── PlatformDetection  CPU architecture & acceleration capabilities
```

## Progressive Roadmap

JLISwift follows a multi-stage progressive roadmap. External C library dependencies are used initially for correctness and compatibility, then progressively replaced with native Swift implementations optimised for each platform.

---

### Milestone 1 — Foundation & Project Setup ✅

> *Establish the Swift Package, core types, public API surface, and platform detection.*

- [x] Swift Package with strict concurrency enabled
- [x] Core types: `JLIImage`, `JLIPixelFormat`, `JLIColorModel`
- [x] Error handling: `JLIError` enum
- [x] Configuration: `JLIEncoderConfiguration`, `JLIDecoderConfiguration`
- [x] JPEG metadata: `JLIJPEGInfo` (width, height, bits, XYB detection, progressive)
- [x] Encoder/decoder API surface: `JLIEncoder`, `JLIDecoder`
- [x] Platform detection: `JLIPlatformCapabilities` (architecture, Accelerate, NEON, SSE, Metal)
- [x] Test scaffolding with Swift Testing framework
- [x] CI-ready package (builds and tests on Linux x86\_64)

---

### Milestone 2 — Baseline JPEG Codec (libjpeg-turbo)

> *Functional encode/decode via libjpeg-turbo C interop. Validates the API surface and provides a correctness reference for later native implementations.*

- [ ] Integrate libjpeg-turbo as a SwiftPM system library or vendored C target
- [ ] Implement `JLIEncoder.encode()` via `jpeg_compress_struct`
- [ ] Implement `JLIDecoder.decode()` via `jpeg_decompress_struct`
- [ ] Implement `JLIDecoder.inspect()` — parse SOF marker for dimensions, components, precision
- [ ] Support all `JLIPixelFormat` variants (uint8 I/O through libjpeg)
- [ ] Support progressive JPEG encoding/decoding
- [ ] Support all `JLIChromaSubsampling` modes
- [ ] Integration tests: round-trip encode → decode with pixel-level validation
- [ ] Benchmark harness (wall-clock time, peak memory, output size)

---

### Milestone 3 — jpegli C Library Integration

> *Integrate Google's jpegli via C interop to unlock adaptive quantization, 10+ bit encoding, and XYB JPEG. This is the "feature-complete via C" milestone.*

- [ ] Integrate jpegli (libjpegli) as a C dependency alongside libjpeg-turbo
- [ ] Adaptive quantization via jpegli's `jpegli_set_distance()` and AQ heuristics
- [ ] 10+ bit encoding: 16-bit / float32 input buffers through jpegli API extensions
- [ ] XYB color space JPEG: ICC-tagged encoding via jpegli's XYB mode
- [ ] Decoder: auto-detect 10+ bit precision from JPEG markers
- [ ] Decoder: auto-detect XYB ICC profile and apply correct inverse transform
- [ ] `JLIJPEGInfo.isExtendedPrecision` and `JLIJPEGInfo.isXYB` detection
- [ ] Distance parameter support (`JLIEncoderConfiguration.distance`)
- [ ] Compatibility tests: encode with JLISwift, decode with Google `djpegli` and vice versa
- [ ] Benchmark: JLISwift (via jpegli C) vs Google `cjpegli`/`djpegli` baseline

---

### Milestone 4 — Native Swift DCT & Quantization

> *Replace the C library's DCT and quantization with native Swift, using Accelerate on Apple platforms and SIMD intrinsics elsewhere.*

- [ ] Forward DCT (FDCT) — pure Swift reference implementation
- [ ] Inverse DCT (IDCT) — pure Swift reference implementation
- [ ] Accelerate-optimised FDCT/IDCT via `vDSP_DCT_Execute`
- [ ] ARM NEON SIMD FDCT/IDCT (arm64 targets)
- [ ] Intel SSE/AVX FDCT/IDCT (x86\_64 targets)
- [ ] Quantization table generation (jpegli-compatible matrices)
- [ ] Adaptive dead-zone quantization (spatial variance-based thresholds)
- [ ] Floating-point precision pipeline (convert to integer only at final quantization)
- [ ] Unit tests: FDCT/IDCT correctness against reference (bit-exact or within tolerance)
- [ ] Benchmark: native DCT vs C library DCT across platforms

---

### Milestone 5 — Native Swift Entropy Coding

> *Huffman and optional arithmetic entropy coding, fully in Swift.*

- [ ] Huffman table parsing (decode)
- [ ] Huffman encoding with optimised table generation
- [ ] Huffman decoding (bitstream reader)
- [ ] Progressive scan ordering and coefficient grouping
- [ ] Arithmetic coding support (encode + decode)
- [ ] Bit writer with buffered output
- [ ] Unit tests: round-trip Huffman encode → decode
- [ ] Benchmark: entropy coding throughput

---

### Milestone 6 — Native Swift Color Space & Sampling

> *Color space conversion and chroma subsampling, hardware-accelerated.*

- [ ] RGB → YCbCr conversion (floating-point precision, as per jpegli)
- [ ] YCbCr → RGB inverse conversion
- [ ] XYB → linear RGB and RGB → XYB transforms
- [ ] ICC profile parsing for XYB detection
- [ ] Chroma downsampling (4:2:0, 4:2:2, 4:4:4)
- [ ] Chroma upsampling (smooth interpolation)
- [ ] Accelerate-optimised transforms (`vImage`, `vDSP`)
- [ ] ARM NEON SIMD color conversion
- [ ] Intel SSE/AVX color conversion
- [ ] Metal compute shader color conversion (Apple platforms)
- [ ] Unit tests: color space round-trip accuracy
- [ ] Benchmark: color conversion throughput

---

### Milestone 7 — Full Native Encoder

> *Assemble the complete encoding pipeline in native Swift, removing the C encoder dependency.*

- [ ] JPEG marker writing (SOI, SOF, SOS, DHT, DQT, DRI, EOI, APP0/APP1)
- [ ] MCU (Minimum Coded Unit) block processing
- [ ] Full encode pipeline: color convert → downsample → DCT → quantize → entropy code → bitstream
- [ ] Progressive JPEG scan generation
- [ ] 10+ bit encoding (16-bit/float32 input → extended precision quantization)
- [ ] XYB JPEG encoding (ICC profile embedding + XYB quantization tables)
- [ ] Streaming/incremental encoding support
- [ ] Memory pooling and arena allocation for zero-copy pipeline
- [ ] Compatibility validation: output matches jpegli C library bit-for-bit (or within tolerance)
- [ ] Remove C encoder dependency (retain as optional reference)

---

### Milestone 8 — Full Native Decoder

> *Assemble the complete decoding pipeline in native Swift, removing the C decoder dependency.*

- [ ] JPEG marker parsing (SOF, SOS, DHT, DQT, DRI, APP segments)
- [ ] MCU block reconstruction
- [ ] Full decode pipeline: bitstream → entropy decode → dequantize → IDCT → upsample → color convert
- [ ] Auto-detect advanced features: 10+ bit, XYB, progressive
- [ ] Smooth dequantization (Laplacian expectation value, as per jpegli)
- [ ] Progressive JPEG incremental decode
- [ ] 16-bit / float32 output support
- [ ] Streaming/incremental decoding support
- [ ] Compatibility validation: decode jpegli-encoded and standard JPEGs identically
- [ ] Remove C decoder dependency (retain as optional reference)

---

### Milestone 9 — GPU Acceleration (Metal)

> *Metal compute shaders for the heaviest pipeline stages on Apple platforms.*

- [ ] Metal compute kernel: forward DCT (8×8 block batches)
- [ ] Metal compute kernel: inverse DCT
- [ ] Metal compute kernel: RGB ↔ YCbCr conversion
- [ ] Metal compute kernel: RGB ↔ XYB conversion
- [ ] Metal compute kernel: chroma downsampling/upsampling
- [ ] Metal compute kernel: adaptive quantization map generation
- [ ] GPU ↔ CPU pipeline orchestration (avoid round-trips)
- [ ] Automatic fallback to CPU when Metal is unavailable
- [ ] Benchmark: GPU vs CPU pipeline (images of varying sizes)

---

### Milestone 10 — Optimisation, Benchmarking & Production Readiness

> *Final performance tuning, comprehensive benchmarks against Google jpegli, and production hardening.*

- [ ] Apple AMX utilisation for matrix operations (where exposed via Accelerate)
- [ ] Memory optimisation: peak memory profiling and reduction
- [ ] Thread pool for concurrent MCU block processing (structured concurrency)
- [ ] Comprehensive benchmark suite:
  - [ ] Encode speed vs Google `cjpegli`, libjpeg-turbo, MozJPEG
  - [ ] Decode speed vs Google `djpegli`, libjpeg-turbo
  - [ ] Compression ratio at matched quality (SSIM/PSNR)
  - [ ] Peak memory comparison
  - [ ] Per-platform results (Apple Silicon, Intel, Linux)
- [ ] DICOMkit integration guidance and example
- [ ] Full API documentation (DocC)
- [ ] CONTRIBUTING guide
- [ ] Release 1.0.0

---

## Relationship to Google jpegli

JLISwift is a **clean-room native Swift implementation** that targets compatibility with Google's [jpegli](https://github.com/google/jpegli). The progressive roadmap begins by wrapping the C library to ensure correctness and API compatibility, then replaces each pipeline stage with hardware-accelerated Swift code. The goal is to produce output that is compatible with — and benchmarked against — the reference implementation.

Key jpegli innovations reproduced in JLISwift:

- **Floating-point precision pipeline** — color conversion, chroma subsampling, and DCT all performed in floating point; integer quantization only at the final step
- **Adaptive dead-zone quantization** — spatially varying quantization thresholds based on image content
- **Optimised quantization matrices** — tables tuned per distance/quality and subsampling mode
- **XYB color space JPEG** — ICC-tagged JPEG using JPEG XL's perceptual color space
- **10+ bit encoding** — 16-bit/float32 input with backward-compatible 8-bit JPEG output

## Requirements

- **Swift 6.0+** (strict concurrency mode)
- **macOS 14+** / **iOS 17+** / **tvOS 17+** / **watchOS 10+** / **visionOS 1+** / **Linux**
- **Xcode 16+** (for Apple platforms)

## License

JLISwift is licensed under the [Apache License 2.0](LICENSE).

## Acknowledgements

- [Google jpegli](https://github.com/google/jpegli) — the reference C implementation
- [JPEG XL](https://github.com/libjxl/libjxl) — origin of the XYB color space and adaptive quantization heuristics
- [libjpeg-turbo](https://github.com/libjpeg-turbo/libjpeg-turbo) — baseline JPEG codec used in early milestones
