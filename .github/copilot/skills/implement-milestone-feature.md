# Skill: Implement Milestone Feature

You are implementing a feature for the JLISwift JPEG codec library. JLISwift follows a strict 10-milestone progressive roadmap where each milestone builds upon the previous one.

## Context

Before writing any code, determine which milestone the requested feature belongs to:

| Milestone | Focus |
|-----------|-------|
| 1 | Foundation & Project Setup (✅ Complete) |
| 2 | Baseline JPEG Codec — libjpeg-turbo C interop |
| 3 | jpegli C Library Integration — adaptive quantization, 10+ bit, XYB |
| 4 | Native Swift DCT & Quantization |
| 5 | Native Swift Entropy Coding |
| 6 | Native Swift Color Space & Sampling |
| 7 | Full Native Encoder — assemble complete native pipeline |
| 8 | Full Native Decoder — assemble complete native pipeline |
| 9 | GPU Acceleration — Metal compute shaders |
| 10 | Optimisation & Production Readiness |

## Rules

1. **Never skip milestones.** If implementing a Milestone 4 feature, all Milestone 2 and 3 features must already exist.
2. **Verify prerequisite code exists** before implementing. Check that the prior milestone's types, tests, and pipelines are in place.
3. **Keep all existing tests passing.** Run `swift test` to validate before and after changes.
4. **Stub unreached features** with `throw JLIError.notImplemented("description — available from Milestone N")`.
5. **Add tests for every new feature** using Swift Testing (`@Suite`, `@Test`, `#expect`).

## Implementation Checklist

For each feature:

- [ ] Identify the target milestone and verify prerequisites are complete
- [ ] Create or modify source files in the correct directory (`Core/`, `Encoder/`, `Decoder/`, `Platform/`)
- [ ] Add `/// ` doc comments to all public symbols
- [ ] Ensure all new public types are `Sendable`
- [ ] Add `// SPDX-License-Identifier: Apache-2.0` and `// Copyright 2024 Raster Lab. All rights reserved.` header
- [ ] Prefix all public types with `JLI`
- [ ] Write tests in `Tests/JLISwiftTests/`
- [ ] Validate with `swift build` and `swift test`

## Milestone 2 Specifics (Baseline JPEG Codec)

When implementing Milestone 2 features:

- Integrate libjpeg-turbo as a SwiftPM system library or vendored C target
- Add a C shim target in `Package.swift` if needed
- Wrap C API calls (`jpeg_compress_struct`, `jpeg_decompress_struct`) in Swift types
- Map C errors to `JLIError` cases
- Implement `JLIEncoder.encode()` and `JLIDecoder.decode()` through the C library
- Implement `JLIDecoder.inspect()` — parse SOF marker for metadata
- Support all `JLIPixelFormat` variants
- Add unit tests for each encoder/decoder function in isolation

## Milestone 3 Specifics (jpegli Integration)

When implementing Milestone 3 features:

- Add jpegli (libjpegli) as a C dependency alongside libjpeg-turbo
- Expose `jpegli_set_distance()` for the distance parameter
- Wire up adaptive quantization heuristics
- Support 16-bit and float32 input buffers through jpegli API extensions
- Enable XYB color space encoding with ICC profile embedding
- Detect 10+ bit precision and XYB in the decoder
- Add unit tests for each jpegli feature in isolation

## Milestone 4–8 Specifics (Native Swift Pipeline)

When replacing C code with native Swift:

- Create the native implementation alongside the C version first
- Add comparison tests: native output vs C output (bit-exact or within tolerance)
- Add benchmarks comparing native vs C performance
- Use `#if canImport(Accelerate)` for Apple platform optimizations
- Use `#if arch(arm64)` / `#if arch(x86_64)` for SIMD paths
- Always provide a pure-Swift fallback
- Only remove C dependency after native passes all compatibility tests

## Milestone 9 Specifics (Metal GPU)

When implementing Metal compute shaders:

- Place shader source in a `Metal/` subdirectory
- Use `#if canImport(Metal)` guards
- Implement CPU fallback for non-Metal platforms
- Minimize GPU ↔ CPU round-trips
- Batch 8×8 block operations for GPU efficiency

## Milestone 10 Specifics (Production Readiness)

When doing final optimization:

- Profile with Instruments (Time Profiler, Allocations)
- Use structured concurrency (`TaskGroup`) for parallel MCU processing
- Generate DocC documentation for all public API
- Create comprehensive benchmark suite vs Google cjpegli/djpegli
