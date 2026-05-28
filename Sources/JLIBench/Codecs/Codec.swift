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

struct JLISwiftCodec: Codec, Gray16Codec {
    let name: String
    let subsampling: JLIChromaSubsampling
    // Explicit (both Codec and Gray16Codec supply a default — disambiguate).
    let isExternal = false

    init(subsampling: JLIChromaSubsampling) {
        self.subsampling = subsampling
        let tag: String
        switch subsampling {
        case .yuv444: tag = "4:4:4"
        case .yuv422: tag = "4:2:2"
        case .yuv420: tag = "4:2:0"
        case .yuv400: tag = "gray"
        }
        self.name = "JLISwift(\(tag))"
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
}
