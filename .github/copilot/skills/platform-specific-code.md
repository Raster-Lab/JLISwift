# Skill: Write Platform-Specific Code

You are writing platform-specific code for JLISwift. The library runs on macOS, iOS, tvOS, watchOS, visionOS (all Apple platforms) and Linux (x86_64 and arm64). Every feature must work on all platforms, with hardware acceleration used where available.

## Platform Detection Hierarchy

```swift
// 1. Architecture detection (compile-time)
#if arch(arm64)
    // Apple Silicon, iOS/tvOS/watchOS/visionOS, Linux arm64
#elseif arch(x86_64)
    // Intel Mac, Linux x86_64
#else
    // Unknown architecture — pure Swift fallback
#endif

// 2. Framework detection (compile-time)
#if canImport(Accelerate)
    import Accelerate  // Apple platforms only
#endif

#if canImport(Metal)
    import Metal  // Apple platforms with GPU
#endif

#if canImport(simd)
    import simd  // Apple platforms
#endif

// 3. OS detection (compile-time)
#if os(macOS)
#elseif os(iOS) || os(tvOS) || os(visionOS)
#elseif os(watchOS)
#elseif os(Linux)
#endif

// 4. Runtime detection
let caps = JLIPlatformCapabilities.current
if caps.hasAccelerate { /* ... */ }
if caps.hasNEON { /* ... */ }
if caps.hasMetal { /* ... */ }
```

## Implementation Pattern

Every performance-critical function must follow this tiered pattern:

```swift
/// Performs forward DCT on an 8×8 block.
func forwardDCT(_ block: inout [Float]) {
    #if canImport(Accelerate)
        forwardDCT_Accelerate(&block)
    #elseif arch(arm64)
        forwardDCT_NEON(&block)
    #elseif arch(x86_64)
        forwardDCT_SSE(&block)
    #else
        forwardDCT_Swift(&block)
    #endif
}

// Tier 1: Accelerate (Apple platforms — highest performance on Apple Silicon)
#if canImport(Accelerate)
private func forwardDCT_Accelerate(_ block: inout [Float]) {
    // Use vDSP_DCT_Execute
}
#endif

// Tier 2: ARM NEON (arm64 without Accelerate, i.e., Linux arm64)
#if arch(arm64) && !canImport(Accelerate)
private func forwardDCT_NEON(_ block: inout [Float]) {
    // NEON intrinsics via Swift SIMD
}
#endif

// Tier 3: Intel SSE/AVX (x86_64)
#if arch(x86_64)
private func forwardDCT_SSE(_ block: inout [Float]) {
    // SSE/AVX via Swift SIMD
}
#endif

// Tier 4: Pure Swift (universal fallback)
private func forwardDCT_Swift(_ block: inout [Float]) {
    // Reference implementation — always correct, not optimized
}
```

## Accelerate Framework Usage

### vDSP (Signal Processing)

```swift
#if canImport(Accelerate)
import Accelerate

// DCT
let dctSetup = vDSP.DCT(count: 64, transformType: .II)
var result = [Float](repeating: 0, count: 64)
dctSetup?.transform(input, result: &result)

// Matrix multiply
vDSP_mmul(a, 1, b, 1, &c, 1, vDSP_Length(m), vDSP_Length(n), vDSP_Length(k))

// Vector operations
vDSP_vadd(a, 1, b, 1, &c, 1, vDSP_Length(count))
#endif
```

### vImage (Image Processing)

```swift
#if canImport(Accelerate)
import Accelerate

// Color space conversion
var src = vImage_Buffer(data: srcPtr, height: height, width: width, rowBytes: srcRowBytes)
var dst = vImage_Buffer(data: dstPtr, height: height, width: width, rowBytes: dstRowBytes)

// RGB to YCbCr
let matrix = [Float](/* BT.601 coefficients */)
vImageMatrixMultiply_ARGB8888(&src, &dst, matrix, divisor, preBias, postBias, vImage_Flags(kvImageNoFlags))
#endif
```

## Metal Compute Shaders

### Pattern

```swift
#if canImport(Metal)
import Metal

final class JLIMetalPipeline: @unchecked Sendable {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let dctPipeline: MTLComputePipelineState
    
    init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.commandQueue = queue
        // Load kernel from Metal library...
    }
}
#endif
```

### Metal Shader Location

- Metal shader source files: `Sources/JLISwift/Metal/`
- Shader names: `jli_forward_dct`, `jli_inverse_dct`, `jli_rgb_to_ycbcr`, etc.

## SIMD Usage (Swift Native)

```swift
// Swift SIMD types work on all platforms
import simd // Not needed — built into Swift stdlib

// Use SIMD for vectorized math
let a = SIMD8<Float>(1, 2, 3, 4, 5, 6, 7, 8)
let b = SIMD8<Float>(repeating: 0.5)
let c = a * b  // Element-wise multiply

// 4×4 matrix operations
let matrix = simd_float4x4(/* ... */)
let vector = simd_float4(/* ... */)
let result = matrix * vector
```

## Linux-Specific Considerations

- No Accelerate framework — use pure Swift or SIMD fallbacks
- No Metal — GPU acceleration not available
- No `Foundation.ProcessInfo` differences — use `#if os(Linux)` for Linux-specific paths
- `DispatchQueue` is available on Linux via swift-corelibs-foundation
- Use `swift test --enable-test-discovery` on older Swift versions if needed

## watchOS Considerations

- No Metal GPU compute (limited GPU API)
- Memory constrained — minimize peak allocation
- Smaller image sizes expected

## File Organization

```
Sources/JLISwift/
├── Platform/
│   ├── PlatformDetection.swift     # JLIPlatformCapabilities
│   ├── AccelerateBackend.swift     # #if canImport(Accelerate) implementations
│   ├── SIMDBackend.swift           # NEON/SSE via Swift SIMD
│   └── SwiftBackend.swift          # Pure Swift reference implementations
├── Metal/
│   ├── JLIMetalPipeline.swift      # Metal orchestration
│   ├── Shaders.metal               # Metal shader source
│   └── MetalFallback.swift         # CPU fallback when Metal unavailable
```

## Testing Platform-Specific Code

```swift
@Suite("Platform-specific DCT")
struct PlatformDCTTests {
    @Test("Pure Swift DCT matches reference output")
    func swiftDCTMatchesReference() {
        // Always test the pure Swift path
    }
    
    #if canImport(Accelerate)
    @Test("Accelerate DCT matches pure Swift DCT within tolerance")
    func accelerateDCTMatchesSwift() {
        // Compare Accelerate output vs pure Swift output
    }
    #endif
    
    #if canImport(Metal)
    @Test("Metal DCT matches CPU DCT within tolerance")
    func metalDCTMatchesCPU() {
        // Compare Metal output vs CPU output
    }
    #endif
}
```
