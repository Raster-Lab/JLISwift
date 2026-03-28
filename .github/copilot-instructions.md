# Copilot Instructions — JLISwift

## Project Overview

JLISwift is a hardware-accelerated, native Swift implementation of Google's [jpegli](https://github.com/google/jpegli) JPEG compression algorithm. It provides encoding and decoding of JPEG images achieving up to 35% better compression ratios while maintaining full backward compatibility with standard JPEG decoders. Advanced features include 10+ bit per component encoding and XYB color space JPEG.

## Repository & Conventions

- **Language:** Swift 6.2+ with strict concurrency (enabled by default in Swift 6).
- **License:** Apache 2.0 — every source file begins with `// SPDX-License-Identifier: Apache-2.0` and `// Copyright 2024 Raster Lab. All rights reserved.`
- **Package manager:** Swift Package Manager (SPM). Package definition lives in `Package.swift`.
- **Testing framework:** Swift Testing (`import Testing`, `@Suite`, `@Test`, `#expect`). **Do not** use XCTest.
- **Minimum platforms:** macOS 14, iOS 17, tvOS 17, watchOS 10, visionOS 1, Linux.
- **All public types must be `Sendable`.** This is non-negotiable — the entire API is data-race safe.

## Architecture

```
Sources/JLISwift/
├── JLISwift.swift              # Library entry point & version
├── Core/                       # Types, errors, configuration
│   ├── JLIImage.swift          # Pixel buffer container (8/16/32-bit)
│   ├── JLIError.swift          # Typed error enum
│   ├── JLIConfiguration.swift  # Encoder & decoder settings
│   └── JLIJPEGInfo.swift       # Decoded JPEG metadata
├── DSP/                        # Signal processing pipeline
│   ├── JLIDCT.swift            # Forward & inverse 8×8 DCT
│   └── JLIQuantization.swift   # Quantization tables, zigzag, quantize/dequantize
├── ColorSpace/                 # Color conversion & sampling
│   ├── JLIColorConversion.swift # RGB↔YCbCr, RGB↔XYB
│   └── JLIChromaSampling.swift  # Chroma downsampling/upsampling
├── Entropy/                    # Entropy coding
│   ├── JLIBitStream.swift      # Bit-level reader/writer
│   └── JLIHuffman.swift        # Huffman tables, encoding, decoding
├── Markers/                    # JPEG bitstream markers
│   ├── JLIMarkerWriter.swift   # Write JPEG markers
│   └── JLIMarkerReader.swift   # Parse JPEG markers
├── Encoder/                    # JPEG compression pipeline
│   └── JLIEncoder.swift        # Full native encoder
├── Decoder/                    # JPEG decompression pipeline
│   └── JLIDecoder.swift        # Full native decoder
├── Platform/                   # Platform-specific optimisation
│   ├── PlatformDetection.swift # CPU arch & acceleration capabilities
│   └── AccelerateBackend.swift # Accelerate-optimised DCT & color
└── Metal/                      # GPU acceleration
    └── JLIMetalPipeline.swift  # Metal compute pipeline
```

## Coding Standards

### Naming

- All public types are prefixed with `JLI` (e.g., `JLIImage`, `JLIEncoder`).
- Use full descriptive names, not abbreviations (except `DCT`, `IDCT`, `MCU`, `RGB`, `YCbCr`, `XYB`, `ICC` which are domain-standard).
- Configuration structs use the pattern `JLI<Thing>Configuration`.
- Enums use the pattern `JLI<Concept>` (e.g., `JLIPixelFormat`, `JLIChromaSubsampling`).

### Error Handling

- All errors are expressed through the `JLIError` enum.
- Features not yet implemented throw `JLIError.notImplemented("description — available from Milestone N")`.
- Validate inputs at API boundaries; never crash on bad input.

### Platform-Specific Code

- Use `#if arch(arm64)` / `#if arch(x86_64)` for architecture branching.
- Use `#if canImport(Accelerate)` for Apple-framework detection.
- Use `#if canImport(Metal)` for Metal availability.
- Always provide a pure-Swift fallback path.
- Query `JLIPlatformCapabilities.current` at runtime when needed.

### Documentation

- Every public symbol must have a `///` doc comment.
- Use DocC-style markup (`## Usage`, code fences, parameter docs).
- Reference related types with double-backtick links: `` ``JLIError/notImplemented(_:)`` ``.

### Testing

- Tests live in `Tests/JLISwiftTests/`.
- Use `@Suite("Description")` to group related tests.
- Use `@Test("Human-readable description")` for each test.
- Use `#expect(...)` and `#expect(throws:)` for assertions.
- Name test functions descriptively: `func imageRejectsZeroWidth()`.
- **Minimum 80% unit test coverage** is required for all code.
- **Unit tests only.** Do not write integration tests or end-to-end tests. Test each component in isolation.

## Progressive Roadmap Awareness

JLISwift follows a 10-milestone progressive roadmap. When generating code, be aware of:

| Milestone | Focus | Status |
|-----------|-------|--------|
| 1 | Foundation & Project Setup | ✅ Complete |
| 2 | Baseline JPEG Codec | ✅ Complete |
| 3 | jpegli Feature Parity | ✅ Complete |
| 4 | Native Swift DCT & Quantization | ✅ Complete |
| 5 | Native Swift Entropy Coding | ✅ Complete |
| 6 | Native Swift Color Space & Sampling | ✅ Complete |
| 7 | Full Native Encoder | ✅ Complete |
| 8 | Full Native Decoder | ✅ Complete |
| 9 | GPU Acceleration (Metal) | ✅ Complete |
| 10 | Optimisation & Production Readiness | ✅ Complete |

### Key Rules for Milestone Work

1. **Never skip milestones.** Each milestone builds on the previous one.
2. **C interop first, then native.** Milestones 2–3 wrap C libraries; Milestones 4–8 replace them with native Swift.
3. **Keep existing tests passing.** New features add tests; they never break existing ones.
4. **Benchmark everything.** Every pipeline stage should have benchmarks comparing C vs native implementations.
5. **Feature-gated stubs.** Unimplemented features throw `JLIError.notImplemented` with the milestone where they become available.

## Key Domain Concepts

- **jpegli** — Google's improved JPEG encoder/decoder with adaptive quantization, floating-point pipeline, 10+ bit support.
- **DCT** — Discrete Cosine Transform, the core of JPEG compression (8×8 blocks).
- **Quantization** — Reduces DCT coefficient precision to achieve compression.
- **Adaptive dead-zone quantization** — Spatially varying thresholds based on image content (core jpegli innovation).
- **Entropy coding** — Huffman or arithmetic coding of quantized coefficients.
- **MCU** — Minimum Coded Unit, the basic processing block in JPEG.
- **XYB** — Perceptual color space from JPEG XL; ICC-tagged in JPEG for backward compatibility.
- **Progressive JPEG** — Multiple scans of increasing detail (vs. baseline sequential).
- **Chroma subsampling** — 4:4:4 (none), 4:2:2 (horizontal), 4:2:0 (both), 4:0:0 (grayscale).

## Dependencies

- **Milestone 1:** No external dependencies (current state).
- **Milestone 2:** libjpeg-turbo (SwiftPM system library or vendored C target).
- **Milestone 3:** jpegli/libjpegli C library alongside libjpeg-turbo.
- **Milestones 4+:** Progressive removal of C dependencies; Accelerate and Metal on Apple platforms.
