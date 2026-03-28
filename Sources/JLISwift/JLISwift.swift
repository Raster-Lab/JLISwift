// SPDX-License-Identifier: Apache-2.0
// Copyright 2024 Raster Lab. All rights reserved.

/// JLISwift — A hardware-accelerated, native Swift implementation of Google's jpegli
/// JPEG compression algorithm.
///
/// JLISwift provides encoding and decoding of JPEG images using the jpegli algorithm,
/// which achieves up to 35% better compression ratios while maintaining full backward
/// compatibility with standard JPEG decoders. The library supports advanced features
/// including 10+ bit encoding and XYB color space JPEG.
///
/// ## Quick Start
///
/// ```swift
/// import JLISwift
///
/// // Encode
/// let encoder = JLIEncoder()
/// let jpegData = try encoder.encode(image, configuration: .default)
///
/// // Decode
/// let decoder = JLIDecoder()
/// let image = try decoder.decode(from: jpegData)
/// ```
///
/// ## Features
///
/// - jpegli-compatible JPEG encoding with adaptive quantization
/// - Standard and 10+ bit per component support
/// - XYB color space JPEG encoding and decoding
/// - Hardware acceleration via Accelerate, ARM NEON, and Intel SSE/AVX
/// - Metal GPU compute shader support on Apple platforms
/// - Swift 6 strict concurrency throughout
public enum JLISwift {
    /// The current library version.
    public static let version = "0.1.0"
}
