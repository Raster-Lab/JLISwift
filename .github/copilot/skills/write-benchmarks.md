# Skill: Write Benchmarks for JLISwift

You are creating benchmarks for the JLISwift JPEG codec library. Every pipeline stage must be benchmarked, and native Swift implementations must be compared against their C library counterparts.

## Benchmark Strategy

### What to Benchmark

| Pipeline Stage | Metrics | Compare Against |
|---------------|---------|-----------------|
| Encode (full) | Wall-clock time, output size, peak memory | libjpeg-turbo, Google cjpegli, MozJPEG |
| Decode (full) | Wall-clock time, peak memory | libjpeg-turbo, Google djpegli |
| DCT (forward) | Throughput (blocks/sec) | C library DCT, Accelerate vDSP |
| DCT (inverse) | Throughput (blocks/sec) | C library IDCT, Accelerate vDSP |
| Quantization | Throughput (blocks/sec) | C library quantization |
| Entropy coding | Throughput (bytes/sec) | C library Huffman |
| Color conversion | Throughput (pixels/sec) | C library, vImage |
| Chroma sampling | Throughput (pixels/sec) | C library |

### Image Test Corpus

Use a standard set of test images at multiple resolutions:

| Image | Resolution | Purpose |
|-------|-----------|---------|
| Gradient | 256×256 | Low complexity baseline |
| Photo (natural) | 1920×1080 | Typical use case |
| Photo (natural) | 4096×3072 | High resolution stress test |
| Text/graphics | 1024×768 | Sharp edges, high frequency |
| Medical/16-bit | 512×512 | 10+ bit precision path |
| Synthetic noise | 512×512 | Worst-case entropy coding |

### Quality Levels

Benchmark at multiple quality/distance settings:
- Quality 50 (high compression)
- Quality 75 (balanced)
- Quality 90 (high quality)
- Quality 95 (near-lossless)
- Distance 1.0 (jpegli visually lossless)

## Benchmark Implementation

### Using swift-benchmark (Recommended)

```swift
import Benchmark

let benchmarks = {
    Benchmark("Encode 1080p RGB uint8 q90") { benchmark in
        let image = try loadTestImage("photo_1080p")
        let encoder = JLIEncoder()
        let config = JLIEncoderConfiguration(quality: 90.0)
        
        for _ in benchmark.scaledIterations {
            blackHole(try encoder.encode(image, configuration: config))
        }
    }
    
    Benchmark("Decode 1080p JPEG") { benchmark in
        let jpegData = try loadTestJPEG("photo_1080p.jpg")
        let decoder = JLIDecoder()
        
        for _ in benchmark.scaledIterations {
            blackHole(try decoder.decode(from: jpegData))
        }
    }
}
```

### Manual Timing (Fallback)

```swift
import Foundation

func benchmark(_ label: String, iterations: Int = 100, _ body: () throws -> Void) rethrows {
    // Warmup
    for _ in 0..<5 { try body() }
    
    let start = CFAbsoluteTimeGetCurrent()
    for _ in 0..<iterations { try body() }
    let elapsed = CFAbsoluteTimeGetCurrent() - start
    
    let perIteration = elapsed / Double(iterations) * 1000.0  // ms
    print("\(label): \(String(format: "%.2f", perIteration)) ms/iteration (\(iterations) iterations)")
}
```

## Benchmark Categories by Milestone

### Milestone 2 — Baseline Codec
- JLISwift (libjpeg-turbo) encode time vs raw libjpeg-turbo
- JLISwift (libjpeg-turbo) decode time vs raw libjpeg-turbo
- Overhead of Swift wrapper layer

### Milestone 3 — jpegli Features
- JLISwift (jpegli) vs Google cjpegli/djpegli
- Compression ratio at matched SSIM/PSNR
- Adaptive quantization overhead

### Milestone 4 — Native DCT
- Native Swift DCT vs C library DCT
- Accelerate vDSP DCT vs pure Swift DCT
- ARM NEON DCT vs pure Swift DCT
- Intel SSE/AVX DCT vs pure Swift DCT

### Milestone 5 — Native Entropy Coding
- Native Huffman vs C library Huffman
- Progressive scan overhead

### Milestone 6 — Native Color Space
- Native RGB↔YCbCr vs C library
- Native RGB↔XYB vs reference
- Accelerate vImage vs pure Swift
- Metal color conversion vs CPU

### Milestone 7–8 — Full Native Pipeline
- Full native encode vs full C encode
- Full native decode vs full C decode
- Memory usage: native vs C

### Milestone 9 — Metal GPU
- Metal pipeline vs CPU pipeline
- GPU transfer overhead analysis
- Break-even image size (where GPU becomes faster)

### Milestone 10 — Final Benchmarks
- Comprehensive suite vs all competitors
- Per-platform breakdown (Apple Silicon, Intel, Linux)
- Concurrent encoding throughput

## Output Format

Benchmark results should be reported as:

```
JLISwift Benchmark Results
==========================
Platform: macOS 14.0, Apple M2 Pro, arm64
Swift: 6.2
Date: 2024-XX-XX

Encode (1080p RGB uint8):
  q50:  JLISwift  12.3 ms | libjpeg-turbo  11.8 ms | ratio: 1.04x
  q90:  JLISwift  18.7 ms | libjpeg-turbo  17.2 ms | ratio: 1.09x

Decode (1080p JPEG):
  JLISwift  8.1 ms | libjpeg-turbo  7.6 ms | ratio: 1.07x

Compression Ratio (1080p, q90, SSIM ≥ 0.98):
  JLISwift (jpegli): 142 KB
  libjpeg-turbo:     198 KB
  Improvement:       28.3%
```

## File Structure

```
Benchmarks/
├── Package.swift                    # Separate benchmark package
├── Sources/
│   └── JLISwiftBenchmarks/
│       ├── EncodeBenchmarks.swift
│       ├── DecodeBenchmarks.swift
│       ├── DCTBenchmarks.swift
│       ├── EntropyBenchmarks.swift
│       ├── ColorSpaceBenchmarks.swift
│       ├── MetalBenchmarks.swift
│       └── Helpers/
│           ├── TestImages.swift
│           └── BenchmarkUtils.swift
└── Resources/
    └── TestImages/
```
