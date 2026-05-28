// SPDX-License-Identifier: Apache-2.0
// Copyright 2024 Raster Lab. All rights reserved.

import Foundation
import JLISwift

/// One codec under test. Encode RGB → JPEG bytes, decode JPEG bytes → RGB.
/// Returning `nil` from either function means "this codec is unavailable on this platform."
protocol Codec: Sendable {
    var name: String { get }
    /// True for codecs that shell out to an external binary. Their timing is
    /// dominated by process spawn (~70 ms/call on macOS), so the harness skips
    /// the median-of-5 sampler and runs them once — bytes/PSNR are deterministic.
    var isExternal: Bool { get }
    func encode(rgb: [UInt8], width: Int, height: Int, quality: Int) throws -> [UInt8]
    func decode(jpeg: [UInt8]) throws -> (rgb: [UInt8], width: Int, height: Int)
}

extension Codec {
    var isExternal: Bool { false }
}

/// A codec that round-trips 12-bit grayscale (samples 0–4095), used for the
/// DICOM corpus at native clinical precision. Separate from `Codec` because not
/// every codec supports 12-bit JPEG (e.g. ImageIO's encoder is 8-bit only).
protocol Gray16Codec: Sendable {
    var name: String { get }
    var isExternal: Bool { get }
    func encodeGray16(_ samples: [UInt16], width: Int, height: Int, quality: Int) throws -> [UInt8]
    func decodeGray16(_ jpeg: [UInt8]) throws -> (gray: [UInt16], width: Int, height: Int)
}

extension Gray16Codec {
    var isExternal: Bool { false }
}

/// A codec that round-trips 12-bit color (interleaved RGB samples 0–4095). The
/// color counterpart of ``Gray16Codec`` — separate because not every codec
/// supports 12-bit JPEG (ImageIO's encoder is 8-bit only).
protocol Color16Codec: Sendable {
    var name: String { get }
    var isExternal: Bool { get }
    func encodeColor16(_ rgb: [UInt16], width: Int, height: Int, quality: Int) throws -> [UInt8]
    func decodeColor16(_ jpeg: [UInt8]) throws -> (rgb: [UInt16], width: Int, height: Int)
}

extension Color16Codec {
    var isExternal: Bool { false }
}

struct JLISwiftCodec: Codec, Gray16Codec, Color16Codec {
    let name: String
    let subsampling: JLIChromaSubsampling
    let progressive: Bool
    let progressiveMode: JLIProgressiveMode
    let restartInterval: Int
    // Explicit (Codec, Gray16Codec, and Color16Codec all supply a default).
    let isExternal = false

    init(subsampling: JLIChromaSubsampling, progressive: Bool = false,
         progressiveMode: JLIProgressiveMode = .spectralSelection,
         restartInterval: Int = 0) {
        self.subsampling = subsampling
        self.progressive = progressive
        self.progressiveMode = progressiveMode
        self.restartInterval = restartInterval
        let tag: String
        switch subsampling {
        case .yuv444: tag = "4:4:4"
        case .yuv422: tag = "4:2:2"
        case .yuv420: tag = "4:2:0"
        case .yuv400: tag = "gray"
        }
        // ",prog" = spectral selection; ",progSA" = successive approximation.
        let progTag: String
        switch (progressive, progressiveMode) {
        case (false, _): progTag = ""
        case (true, .spectralSelection): progTag = ",prog"
        case (true, .successiveApproximation): progTag = ",progSA"
        }
        let rstTag = restartInterval > 0 ? ",rst" : ""
        self.name = "JLISwift(\(tag)\(progTag)\(rstTag))"
    }

    func encode(rgb: [UInt8], width: Int, height: Int, quality: Int) throws -> [UInt8] {
        let image = try JLIImage(
            width: width, height: height,
            pixelFormat: .uint8, colorModel: .rgb,
            data: rgb
        )
        var config = JLIEncoderConfiguration.default
        config.quality = Double(quality)
        config.chromaSubsampling = subsampling
        config.progressive = progressive
        config.progressiveMode = progressiveMode
        config.restartInterval = restartInterval
        return try JLIEncoder().encode(image, configuration: config)
    }

    func decode(jpeg: [UInt8]) throws -> (rgb: [UInt8], width: Int, height: Int) {
        let img = try JLIDecoder().decode(from: jpeg)
        return (img.data, img.width, img.height)
    }

    // MARK: - Gray16Codec (12-bit)

    func encodeGray16(_ samples: [UInt16], width: Int, height: Int, quality: Int) throws -> [UInt8] {
        // Pack to little-endian uint16 bytes — JLIImage's `.uint16` layout.
        var bytes = [UInt8](repeating: 0, count: samples.count * 2)
        for i in 0..<samples.count {
            bytes[i * 2] = UInt8(samples[i] & 0xFF)
            bytes[i * 2 + 1] = UInt8(samples[i] >> 8)
        }
        let image = try JLIImage(
            width: width, height: height,
            pixelFormat: .uint16, colorModel: .grayscale, data: bytes
        )
        var config = JLIEncoderConfiguration.default
        config.quality = Double(quality)
        config.chromaSubsampling = .yuv400
        return try JLIEncoder().encode(image, configuration: config)
    }

    func decodeGray16(_ jpeg: [UInt8]) throws -> (gray: [UInt16], width: Int, height: Int) {
        let img = try JLIDecoder().decode(from: jpeg)
        var gray = [UInt16](repeating: 0, count: img.width * img.height)
        // Decoder emits `.uint16` little-endian for 12-bit grayscale.
        if img.pixelFormat == .uint16 {
            for i in 0..<gray.count {
                gray[i] = UInt16(img.data[i * 2]) | (UInt16(img.data[i * 2 + 1]) << 8)
            }
        } else {
            for i in 0..<gray.count { gray[i] = UInt16(img.data[i]) }
        }
        return (gray, img.width, img.height)
    }

    // MARK: - Color16Codec (12-bit color)

    func encodeColor16(_ rgb: [UInt16], width: Int, height: Int, quality: Int) throws -> [UInt8] {
        // Pack interleaved RGB to little-endian uint16 bytes — JLIImage's layout.
        var bytes = [UInt8](repeating: 0, count: rgb.count * 2)
        for i in 0..<rgb.count {
            bytes[i * 2] = UInt8(rgb[i] & 0xFF)
            bytes[i * 2 + 1] = UInt8(rgb[i] >> 8)
        }
        let image = try JLIImage(
            width: width, height: height,
            pixelFormat: .uint16, colorModel: .rgb, data: bytes
        )
        var config = JLIEncoderConfiguration.default
        config.quality = Double(quality)
        config.chromaSubsampling = subsampling
        return try JLIEncoder().encode(image, configuration: config)
    }

    func decodeColor16(_ jpeg: [UInt8]) throws -> (rgb: [UInt16], width: Int, height: Int) {
        let img = try JLIDecoder().decode(from: jpeg)
        var rgb = [UInt16](repeating: 0, count: img.width * img.height * 3)
        // Decoder emits `.uint16` little-endian for 12-bit color.
        if img.pixelFormat == .uint16 {
            for i in 0..<rgb.count {
                rgb[i] = UInt16(img.data[i * 2]) | (UInt16(img.data[i * 2 + 1]) << 8)
            }
        } else {
            for i in 0..<rgb.count { rgb[i] = UInt16(img.data[i]) }
        }
        return (rgb, img.width, img.height)
    }
}
