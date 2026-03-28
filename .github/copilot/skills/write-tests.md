# Skill: Write Tests for JLISwift

You are writing tests for the JLISwift JPEG codec library. JLISwift uses the Swift Testing framework exclusively — **never use XCTest**.

## Framework

```swift
import Testing
@testable import JLISwift
```

## Patterns

### Grouping Tests

```swift
@Suite("Human-readable group description")
struct FeatureTests {
    @Test("Human-readable test description")
    func descriptiveFunctionName() throws {
        // ...
    }
}
```

### Assertions

```swift
// Value equality
#expect(result == expected)

// Boolean conditions
#expect(image.width > 0)

// Error throwing
#expect(throws: JLIError.self) {
    try riskyOperation()
}

// Specific error case
#expect {
    try JLIImage(width: 0, height: 10, pixelFormat: .uint8, colorModel: .rgb, data: [])
} throws: { error in
    guard case JLIError.invalidImageDimensions = error else { return false }
    return true
}
```

### Test Naming

- Name test functions descriptively: `func encoderRejectsInvalidQuality()`
- Describe behavior, not implementation: "rejects", "accepts", "produces", "detects"
- Group related tests under a `@Suite`

## Test Categories by Milestone

### Milestone 1 — Core Types (Complete)
- `JLIImage` creation, validation, rejection of bad input
- `JLIPixelFormat` properties
- `JLIColorModel` component counts
- `JLIEncoderConfiguration` / `JLIDecoderConfiguration` defaults and validation
- `JLIPlatformCapabilities` detection
- Encoder/Decoder throw `notImplemented`

### Milestone 2 — Baseline Codec
- Encoder unit tests: validate encode output is non-empty, starts with JPEG SOI marker
- Decoder unit tests: validate decode produces correct dimensions and pixel format
- Format support: test all `JLIPixelFormat` (uint8, uint16, float32) in isolation
- Subsampling: test each `JLIChromaSubsampling` mode configuration
- `inspect()`: verify returned `JLIJPEGInfo` matches expected metadata
- Edge cases: 1×1 image, maximum dimensions, grayscale, CMYK
- Invalid input: corrupt JPEG data, truncated data, empty data

### Milestone 3 — jpegli Features
- Adaptive quantization: enabled vs disabled produces different output sizes
- Distance parameter: `distance` overrides `quality`
- 10+ bit: encode 16-bit input → verify correct format markers
- XYB: encode XYB → `inspect()` reports `isXYB == true`
- Each jpegli API wrapper tested in isolation

### Milestone 4 — DCT & Quantization
- FDCT: verify output for known input blocks against reference values
- IDCT: verify output for known input blocks against reference values
- FDCT → IDCT: verify reconstruction preserves values (within tolerance)
- Quantization table generation: verify against jpegli reference tables
- Native vs C comparison: outputs within specified tolerance

### Milestone 5 — Entropy Coding
- Huffman encoding: verify output for known coefficient inputs
- Huffman decoding: verify output for known encoded inputs
- Progressive scan ordering: verify correct coefficient grouping
- Bit writer: verify correct byte output for known bit sequences
- Bit reader: verify correct bit extraction from known byte sequences

### Milestone 6 — Color Space
- RGB → YCbCr: verify output for known input values
- YCbCr → RGB: verify output for known input values
- RGB → XYB: verify output for known input values
- XYB → RGB: verify output for known input values
- ICC profile detection: verify parsing of known profiles
- Chroma downsampling: verify output dimensions and values
- Chroma upsampling: verify interpolation accuracy

### Milestone 7–8 — Native Pipeline
- Each pipeline stage tested in isolation against reference output
- Marker writing: verify correct byte sequences for each marker type
- Marker parsing: verify correct metadata extraction from known bytes
- MCU processing: verify block layout for each subsampling mode
- Streaming: verify incremental state management
- Native vs C per-stage comparison: outputs within specified tolerance

### Milestone 9 — Metal GPU
- GPU output matches CPU output (within tolerance)
- Fallback: still works when Metal unavailable
- Batch processing: multiple images produce correct results

### Milestone 10 — Production
- Performance benchmarks as tests (ensure no regression)
- Concurrent encoding/decoding safety
- Large image handling

## Test File Structure

```
Tests/JLISwiftTests/
├── JLISwiftTests.swift          # Core type unit tests (Milestone 1)
├── EncoderTests.swift           # Encoder unit tests (Milestone 2+)
├── DecoderTests.swift           # Decoder unit tests (Milestone 2+)
├── JPEGInfoTests.swift          # Inspection/metadata unit tests (Milestone 2+)
├── JpegliFeatureTests.swift     # jpegli-specific unit tests (Milestone 3+)
├── DCTTests.swift               # DCT/quantization unit tests (Milestone 4)
├── QuantizationTests.swift      # Quantization unit tests (Milestone 4)
├── EntropyTests.swift           # Huffman/arithmetic coding unit tests (Milestone 5)
├── ColorSpaceTests.swift        # Color conversion unit tests (Milestone 6)
├── MarkerTests.swift            # JPEG marker read/write unit tests (Milestone 7–8)
├── MCUTests.swift               # MCU processing unit tests (Milestone 7–8)
├── MetalTests.swift             # Metal GPU unit tests (Milestone 9)
└── BenchmarkTests.swift         # Performance regression (Milestone 10)
```

## File Header

Every test file must begin with:

```swift
// SPDX-License-Identifier: Apache-2.0
// Copyright 2024 Raster Lab. All rights reserved.
```

## Helper Patterns

### Creating Test Images

```swift
/// Creates a small test image with known pixel values.
func makeTestImage(
    width: Int = 8, height: Int = 8,
    pixelFormat: JLIPixelFormat = .uint8,
    colorModel: JLIColorModel = .rgb
) throws -> JLIImage {
    let byteCount = width * height * colorModel.componentCount * pixelFormat.bytesPerComponent
    let data = [UInt8](repeating: 128, count: byteCount)
    return try JLIImage(width: width, height: height, pixelFormat: pixelFormat, colorModel: colorModel, data: data)
}
```

### Pixel Comparison with Tolerance

```swift
/// Compares two images pixel-by-pixel within a tolerance.
func assertImagesEqual(_ a: JLIImage, _ b: JLIImage, tolerance: Int = 1) {
    #expect(a.width == b.width)
    #expect(a.height == b.height)
    for i in 0..<a.data.count {
        #expect(abs(Int(a.data[i]) - Int(b.data[i])) <= tolerance,
                "Pixel mismatch at byte \(i): \(a.data[i]) vs \(b.data[i])")
    }
}
```

## Validation

After writing tests, always run:
```bash
swift test
```

Ensure all new tests pass and no existing tests are broken.
