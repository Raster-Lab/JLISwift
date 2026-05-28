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

struct JLISwiftCodec: Codec {
    let name: String
    let subsampling: JLIChromaSubsampling

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
}
