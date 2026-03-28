// SPDX-License-Identifier: Apache-2.0
// Copyright 2024 Raster Lab. All rights reserved.

/// Detected hardware acceleration capabilities for the current platform.
///
/// Used internally to select the optimal code path for DSP-heavy operations
/// (DCT, color space conversion, quantization).
public struct JLIPlatformCapabilities: Sendable {
    /// The CPU architecture family.
    public let architecture: Architecture

    /// Whether the Accelerate framework (vDSP/vImage) is available.
    public let hasAccelerate: Bool

    /// Whether ARM NEON SIMD is available.
    public let hasNEON: Bool

    /// Whether Intel SSE2+ SIMD is available.
    public let hasSSE: Bool

    /// Whether Metal GPU compute is available.
    public let hasMetal: Bool

    /// CPU architecture family.
    public enum Architecture: String, Sendable {
        case arm64
        case x86_64
        case unknown
    }

    /// Detects the capabilities of the current platform at compile time.
    public static let current: JLIPlatformCapabilities = {
        #if arch(arm64)
        let arch = Architecture.arm64
        #elseif arch(x86_64)
        let arch = Architecture.x86_64
        #else
        let arch = Architecture.unknown
        #endif

        #if canImport(Accelerate)
        let accelerate = true
        #else
        let accelerate = false
        #endif

        #if arch(arm64)
        let neon = true
        #else
        let neon = false
        #endif

        #if arch(x86_64)
        let sse = true
        #else
        let sse = false
        #endif

        #if canImport(Metal)
        let metal = true
        #else
        let metal = false
        #endif

        return JLIPlatformCapabilities(
            architecture: arch,
            hasAccelerate: accelerate,
            hasNEON: neon,
            hasSSE: sse,
            hasMetal: metal
        )
    }()
}
