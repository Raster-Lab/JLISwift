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

/// The scan script used when encoding a progressive (SOF2) JPEG.
public enum JLIProgressiveMode: Sendable {
    /// Spectral selection only: one DC scan plus one full-band AC scan per
    /// component, using end-of-band runs (EOBRUN). Best for flat / low-frequency
    /// content such as medical imaging — a run of AC-empty blocks collapses to a
    /// single EOBn symbol. This is the default.
    case spectralSelection

    /// Spectral selection **and** successive approximation: libjpeg's canonical
    /// `jpeg_simple_progression` script (band-split luma, Al=2 luma / Al=1
    /// chroma, refined to 0). Slightly smaller on textured / photographic
    /// content, but larger on flat content where the extra scans fragment EOB
    /// runs. Opt in when encoding natural photographs rather than medical plates.
    case successiveApproximation
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

    /// The scan script for progressive encoding (ignored unless ``progressive``
    /// is set). Defaults to ``JLIProgressiveMode/spectralSelection``, which
    /// compresses flat / medical content best.
    public var progressiveMode: JLIProgressiveMode

    /// Emit a restart marker (RST) every N MCUs, with a DRI marker declaring the
    /// interval. `0` (default) disables restart markers. Restart markers add
    /// resync points so a corrupt run only damages one interval rather than the
    /// rest of the scan, and enable segmented decoding — at a small size cost.
    /// Applies to the baseline / extended-sequential path (not progressive).
    public var restartInterval: Int

    /// Produce a lossless (SOF3) JPEG — exact reconstruction via spatial
    /// prediction, no DCT/quantization. Larger files, but bit-for-bit lossless
    /// (e.g. medical archival). Grayscale only for now; overrides `progressive`.
    public var lossless: Bool

    /// Lossless predictor selector (1–7, ITU-T T.81 Table H.1; default 1 = left).
    /// Ignored unless `lossless` is set.
    public var losslessPredictor: Int

    /// Sample precision for lossless encoding (2–16), or `0` to derive it from the
    /// pixel format (8-bit for `.uint8`, 12-bit for `.uint16`). Set to 16 for
    /// full 16-bit lossless (e.g. 16-bit medical sources); requires `.uint16`
    /// input. Ignored unless `lossless` is set; DCT modes always use 8/12-bit.
    public var losslessPrecision: Int

    /// Point transform for **near-lossless** SOF3 encoding (0–`precision-1`;
    /// default `0` = true lossless). When `> 0`, the low `Pt` bits of each sample
    /// are discarded before prediction, bounding the reconstruction error to
    /// `2^Pt − 1` while shrinking the file — a controlled-loss archival tradeoff.
    /// Ignored unless `lossless` is set.
    public var losslessPointTransform: Int

    /// Whether to use optimised Huffman coding.
    public var optimiseHuffman: Bool

    /// Whether to enable adaptive dead-zone quantization.
    ///
    /// When enabled, quantization thresholds vary spatially based on image
    /// content — smoother regions get finer quantization while noisy regions
    /// are quantized more aggressively. This is a core jpegli improvement.
    public var adaptiveQuantization: Bool

    /// Derive the quantization tables from jpegli's perceptual model instead of
    /// scaling the ITU-T Annex K tables by an IJG quality factor.
    ///
    /// jpegli builds each quantization step from perceptually-tuned base matrices
    /// and a per-coefficient non-linear function of the ``distance`` (see
    /// ``Quantization/perceptualQuantTable(distance:chroma:isYUV420:)``). When no
    /// explicit distance is set, ``quality`` is mapped to a distance first.
    /// Applies to the YCbCr DCT path (baseline/progressive, 8-bit); ignored for
    /// lossless and 12-bit. Defaults to `false` (the Annex K path) — opt in for
    /// jpegli-style perceptual rate allocation.
    public var perceptualQuantTables: Bool

    /// A sensible default configuration: quality 90, YCbCr, 4:2:0 subsampling,
    /// baseline (non-progressive) with optimized Huffman + adaptive quantization.
    /// Progressive is opt-in — it's a multi-pass encode and most callers want the
    /// faster baseline path by default.
    public static let `default` = JLIEncoderConfiguration(
        quality: 90.0,
        distance: nil,
        chromaSubsampling: .yuv420,
        colorSpace: .yCbCr,
        progressive: false,
        progressiveMode: .spectralSelection,
        restartInterval: 0,
        lossless: false,
        losslessPredictor: 1,
        losslessPrecision: 0,
        losslessPointTransform: 0,
        optimiseHuffman: true,
        adaptiveQuantization: true,
        perceptualQuantTables: false
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
        progressiveMode: JLIProgressiveMode = .spectralSelection,
        restartInterval: Int = 0,
        lossless: Bool = false,
        losslessPredictor: Int = 1,
        losslessPrecision: Int = 0,
        losslessPointTransform: Int = 0,
        optimiseHuffman: Bool = true,
        adaptiveQuantization: Bool = true,
        perceptualQuantTables: Bool = false
    ) {
        self.quality = quality
        self.distance = distance
        self.chromaSubsampling = chromaSubsampling
        self.colorSpace = colorSpace
        self.progressive = progressive
        self.progressiveMode = progressiveMode
        self.restartInterval = restartInterval
        self.lossless = lossless
        self.losslessPredictor = losslessPredictor
        self.losslessPrecision = losslessPrecision
        self.losslessPointTransform = losslessPointTransform
        self.optimiseHuffman = optimiseHuffman
        self.adaptiveQuantization = adaptiveQuantization
        self.perceptualQuantTables = perceptualQuantTables
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

    /// Decode at a reduced scale of `1/scale` for fast previews/thumbnails of
    /// large images. Supported: `1` (full, default), `2`, `4`, and `8`. Each
    /// output sample is the exact average of its `scale × scale` source-pixel box,
    /// reconstructed directly from the low-frequency DCT coefficients (no full
    /// IDCT) — so the result is exact and faster than decoding then downsampling.
    /// `8` is the DC-only special case. Output dimensions are
    /// `ceil(width/scale) × ceil(height/scale)`.
    public var scale: Int

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
    ///   - scale: Decode at `1/scale` resolution (`1` full, `8` for 1/8 thumbnails).
    public init(
        outputPixelFormat: JLIPixelFormat? = nil,
        outputColorModel: JLIColorModel? = nil,
        scale: Int = 1
    ) {
        self.outputPixelFormat = outputPixelFormat
        self.outputColorModel = outputColorModel
        self.scale = scale
    }
}
