// SPDX-License-Identifier: Apache-2.0
// Copyright 2024 Raster Lab. All rights reserved.

/// Chroma subsampling mode for JPEG encoding.
public enum JLIChromaSubsampling: Sendable {
    /// No subsampling — full resolution for all channels (4:4:4).
    case yuv444

    /// Horizontal subsampling — chrominance at half horizontal resolution (4:2:2).
    case yuv422

    /// Both horizontal and vertical subsampling — chrominance at quarter resolution (4:2:0).
    case yuv420

    /// Grayscale — single luminance channel, no chrominance (4:0:0).
    case yuv400
}

/// The color space to use for encoding the JPEG.
public enum JLIEncodingColorSpace: Sendable {
    /// Standard YCbCr encoding (default, maximum compatibility).
    case yCbCr

    /// XYB perceptual color space (from JPEG XL).
    ///
    /// Produces an ICC-tagged JPEG that standard decoders can display, while
    /// jpegli-aware decoders can exploit the perceptual quantization for better quality.
    case xyb
}

/// Configuration for the jpegli encoder.
///
/// Use ``JLIEncoderConfiguration/default`` for sensible defaults or customise
/// individual parameters for fine-grained control.
public struct JLIEncoderConfiguration: Sendable {
    /// The JPEG quality level (0.0 – 100.0).
    ///
    /// Higher values produce larger files with fewer artifacts.
    /// This is translated internally to an appropriate jpegli distance parameter.
    public var quality: Double

    /// The jpegli distance parameter (analogous to JPEG XL distance).
    ///
    /// When set, this takes precedence over ``quality``. Lower values produce
    /// higher quality output. A value of `1.0` is visually lossless for most images.
    /// `nil` means the distance is computed from the ``quality`` value.
    public var distance: Double?

    /// The chroma subsampling mode.
    public var chromaSubsampling: JLIChromaSubsampling

    /// The color space used for encoding.
    public var colorSpace: JLIEncodingColorSpace

    /// Whether to produce a progressive JPEG.
    public var progressive: Bool

    /// Whether to use optimised Huffman coding.
    public var optimiseHuffman: Bool

    /// Whether to enable adaptive dead-zone quantization.
    ///
    /// When enabled, quantization thresholds vary spatially based on image
    /// content — smoother regions get finer quantization while noisy regions
    /// are quantized more aggressively. This is a core jpegli improvement.
    public var adaptiveQuantization: Bool

    /// A sensible default configuration: quality 90, YCbCr, 4:2:0 subsampling,
    /// progressive encoding with adaptive quantization enabled.
    public static let `default` = JLIEncoderConfiguration(
        quality: 90.0,
        distance: nil,
        chromaSubsampling: .yuv420,
        colorSpace: .yCbCr,
        progressive: true,
        optimiseHuffman: true,
        adaptiveQuantization: true
    )

    /// Creates an encoder configuration.
    ///
    /// - Parameters:
    ///   - quality: JPEG quality level (0.0 – 100.0). Default is 90.
    ///   - distance: Optional jpegli distance parameter. Overrides quality when set.
    ///   - chromaSubsampling: Chroma subsampling mode. Default is `.yuv420`.
    ///   - colorSpace: Encoding color space. Default is `.yCbCr`.
    ///   - progressive: Whether to produce a progressive JPEG. Default is `true`.
    ///   - optimiseHuffman: Whether to use optimised Huffman tables. Default is `true`.
    ///   - adaptiveQuantization: Whether to enable adaptive quantization. Default is `true`.
    public init(
        quality: Double = 90.0,
        distance: Double? = nil,
        chromaSubsampling: JLIChromaSubsampling = .yuv420,
        colorSpace: JLIEncodingColorSpace = .yCbCr,
        progressive: Bool = true,
        optimiseHuffman: Bool = true,
        adaptiveQuantization: Bool = true
    ) {
        self.quality = quality
        self.distance = distance
        self.chromaSubsampling = chromaSubsampling
        self.colorSpace = colorSpace
        self.progressive = progressive
        self.optimiseHuffman = optimiseHuffman
        self.adaptiveQuantization = adaptiveQuantization
    }
}

/// Configuration for the jpegli decoder.
public struct JLIDecoderConfiguration: Sendable {
    /// The desired output pixel format.
    ///
    /// When `nil`, the decoder selects the most appropriate format based on the
    /// JPEG's internal precision (8-bit input → `.uint8`, 10+ bit → `.uint16`).
    public var outputPixelFormat: JLIPixelFormat?

    /// The desired output color model.
    ///
    /// When `nil`, the decoder outputs in the JPEG's native color model (typically RGB).
    public var outputColorModel: JLIColorModel?

    /// A sensible default configuration that auto-detects precision and color model.
    public static let `default` = JLIDecoderConfiguration(
        outputPixelFormat: nil,
        outputColorModel: nil
    )

    /// Creates a decoder configuration.
    ///
    /// - Parameters:
    ///   - outputPixelFormat: Desired output pixel format, or `nil` for auto-detection.
    ///   - outputColorModel: Desired output color model, or `nil` for auto-detection.
    public init(
        outputPixelFormat: JLIPixelFormat? = nil,
        outputColorModel: JLIColorModel? = nil
    ) {
        self.outputPixelFormat = outputPixelFormat
        self.outputColorModel = outputColorModel
    }
}
