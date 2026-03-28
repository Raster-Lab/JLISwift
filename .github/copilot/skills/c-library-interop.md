# Skill: C Library Interop

You are integrating a C library (libjpeg-turbo or jpegli/libjpegli) into JLISwift via Swift Package Manager. This skill covers Milestones 2 and 3 of the roadmap.

## SwiftPM C Target Integration

### Option A: System Library (linking against system-installed library)

```swift
// Package.swift
.systemLibrary(
    name: "CJPEGTurbo",
    pkgConfig: "libjpeg",
    providers: [
        .brew(["libjpeg-turbo"]),
        .apt(["libjpeg-turbo8-dev"]),
    ]
)
```

With a module map:
```
// Sources/CJPEGTurbo/module.modulemap
module CJPEGTurbo {
    header "shim.h"
    link "jpeg"
    export *
}
```

### Option B: Vendored C Target (preferred for reproducibility)

```swift
// Package.swift
.target(
    name: "CJPEGTurbo",
    path: "Sources/CJPEGTurbo",
    publicHeadersPath: "include",
    cSettings: [
        .define("HAVE_STDINT_H"),
        .headerSearchPath("src"),
    ]
),
.target(
    name: "JLISwift",
    dependencies: ["CJPEGTurbo"]
)
```

## C API Wrapping Pattern

### Encoder (libjpeg-turbo)

```swift
import CJPEGTurbo

extension JLIEncoder {
    /// Internal encoding implementation via libjpeg-turbo.
    internal func encodeViaLibjpeg(
        _ image: JLIImage,
        configuration: JLIEncoderConfiguration
    ) throws -> [UInt8] {
        var cinfo = jpeg_compress_struct()
        var jerr = jpeg_error_mgr()
        
        // Set up error handler
        cinfo.err = jpeg_std_error(&jerr)
        // TODO: Install custom error handler that throws instead of calling exit()
        
        jpeg_create_compress(&cinfo)
        defer { jpeg_destroy_compress(&cinfo) }
        
        // Set up memory destination
        var outBuffer: UnsafeMutablePointer<UInt8>? = nil
        var outSize: UInt = 0
        jpeg_mem_dest(&cinfo, &outBuffer, &outSize)
        
        // Configure
        cinfo.image_width = JDIMENSION(image.width)
        cinfo.image_height = JDIMENSION(image.height)
        cinfo.input_components = Int32(image.colorModel.componentCount)
        cinfo.in_color_space = mapColorSpace(image.colorModel)
        
        jpeg_set_defaults(&cinfo)
        jpeg_set_quality(&cinfo, Int32(configuration.quality), 1)
        
        if configuration.progressive {
            jpeg_simple_progression(&cinfo)
        }
        
        // Compress
        jpeg_start_compress(&cinfo, 1)
        
        let rowStride = image.bytesPerRow
        image.data.withUnsafeBufferPointer { buffer in
            var rowPointer: UnsafeMutablePointer<UInt8>?
            while cinfo.next_scanline < cinfo.image_height {
                let offset = Int(cinfo.next_scanline) * rowStride
                // Write scanline...
            }
        }
        
        jpeg_finish_compress(&cinfo)
        
        // Copy output
        guard let outBuffer else { throw JLIError.encodingFailed("libjpeg memory destination returned nil") }
        let result = Array(UnsafeBufferPointer(start: outBuffer, count: Int(outSize)))
        free(outBuffer)
        
        return result
    }
}
```

### Decoder (libjpeg-turbo)

```swift
extension JLIDecoder {
    /// Internal decoding implementation via libjpeg-turbo.
    internal func decodeViaLibjpeg(
        _ data: [UInt8],
        configuration: JLIDecoderConfiguration
    ) throws -> JLIImage {
        var cinfo = jpeg_decompress_struct()
        var jerr = jpeg_error_mgr()
        
        cinfo.err = jpeg_std_error(&jerr)
        jpeg_create_decompress(&cinfo)
        defer { jpeg_destroy_decompress(&cinfo) }
        
        // Set up memory source
        data.withUnsafeBufferPointer { buffer in
            jpeg_mem_src(&cinfo, buffer.baseAddress, UInt(buffer.count))
        }
        
        jpeg_read_header(&cinfo, 1)
        jpeg_start_decompress(&cinfo)
        
        // Read scanlines...
        let width = Int(cinfo.output_width)
        let height = Int(cinfo.output_height)
        let components = Int(cinfo.output_components)
        var pixels = [UInt8](repeating: 0, count: width * height * components)
        
        // ... scanline reading loop ...
        
        jpeg_finish_decompress(&cinfo)
        
        return try JLIImage(
            width: width, height: height,
            pixelFormat: .uint8,
            colorModel: mapColorModel(components),
            data: pixels
        )
    }
}
```

## Error Handling in C Interop

**Critical:** libjpeg's default error handler calls `exit()`. You MUST install a custom error handler that uses `setjmp`/`longjmp` to recover, then map the error to a `JLIError`.

```swift
/// Custom error manager that uses longjmp instead of exit().
struct JLIJPEGErrorManager {
    var base: jpeg_error_mgr
    var jumpBuffer: jmp_buf
}

/// C-compatible error exit function.
private func jliErrorExit(_ cinfo: j_common_ptr?) {
    guard let cinfo else { return }
    let errMgr = cinfo.pointee.err.withMemoryRebound(to: JLIJPEGErrorManager.self, capacity: 1) { $0 }
    longjmp(&errMgr.pointee.jumpBuffer, 1)
}
```

## jpegli-Specific API (Milestone 3)

```swift
import CJpegli

// Distance parameter (overrides quality)
jpegli_set_distance(&cinfo, Float(configuration.distance ?? 1.0))

// Enable adaptive quantization
jpegli_enable_adaptive_quantization(&cinfo, configuration.adaptiveQuantization ? 1 : 0)

// XYB color space
if configuration.colorSpace == .xyb {
    jpegli_set_xyb_mode(&cinfo)
}

// 10+ bit input
jpegli_set_input_format(&cinfo, JPEGLI_TYPE_UINT16, JPEGLI_NATIVE_ENDIAN)
```

## Memory Safety Rules

1. **Always use `defer` for cleanup:** `defer { jpeg_destroy_compress(&cinfo) }`
2. **Never let C pointers escape** beyond the scope where they're valid.
3. **Copy data out of C buffers** before freeing them.
4. **Use `withUnsafe*` closures** to pass Swift arrays to C functions safely.
5. **Handle `nil` returns** from all C allocation functions.

## Directory Structure

```
Sources/
├── CJPEGTurbo/                    # C target for libjpeg-turbo
│   ├── include/
│   │   ├── module.modulemap
│   │   └── shim.h                 # Includes jpeglib.h, jpegli.h
│   └── src/                       # Vendored C source (if not system library)
├── CJpegli/                       # C target for jpegli (Milestone 3)
│   ├── include/
│   │   ├── module.modulemap
│   │   └── shim.h
│   └── src/
└── JLISwift/
    ├── Interop/                   # Swift ↔ C bridge code
    │   ├── LibjpegEncoder.swift   # libjpeg-turbo encode wrapper
    │   ├── LibjpegDecoder.swift   # libjpeg-turbo decode wrapper
    │   ├── JpegliEncoder.swift    # jpegli encode wrapper (Milestone 3)
    │   ├── JpegliDecoder.swift    # jpegli decode wrapper (Milestone 3)
    │   └── CErrorHandler.swift    # Custom error handler (setjmp/longjmp)
```

## Testing C Interop

All tests must be **unit tests** — test each C wrapper function in isolation.

```swift
@Suite("libjpeg-turbo Encoder Unit Tests")
struct LibjpegEncoderTests {
    @Test("Encode produces valid JPEG data with SOI marker")
    func encodeProducesValidJPEG() throws {
        let image = try makeTestImage(width: 64, height: 64)
        let encoder = JLIEncoder()
        
        let jpegData = try encoder.encode(image, configuration: .init(quality: 90.0))
        
        #expect(jpegData.count > 2)
        #expect(jpegData[0] == 0xFF)  // SOI marker
        #expect(jpegData[1] == 0xD8)
    }
    
    @Test("Encode rejects zero-dimension image")
    func encodeRejectsZeroDimension() {
        #expect(throws: JLIError.self) {
            let image = try JLIImage(width: 0, height: 10, pixelFormat: .uint8, colorModel: .rgb, data: [])
            let encoder = JLIEncoder()
            try encoder.encode(image)
        }
    }
}
```
