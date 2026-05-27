// SPDX-License-Identifier: Apache-2.0
// Copyright 2024 Raster Lab. All rights reserved.

import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

/// Apple ImageIO baseline: hardware-accelerated JPEG via CGImageDestination / CGImageSource.
/// This is what most macOS/iOS apps use today — the relevant real-world comparison point.
struct ImageIOCodec: Codec {
    let name = "ImageIO"

    func encode(rgb: [UInt8], width: Int, height: Int, quality: Int) throws -> [UInt8] {
        let cs = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo: CGBitmapInfo = [CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue)]

        // ImageIO needs 4-byte aligned RGBX, so pad RGB → RGBX.
        let pixelCount = width * height
        var rgbx = [UInt8](repeating: 0, count: pixelCount * 4)
        for i in 0..<pixelCount {
            rgbx[i * 4]     = rgb[i * 3]
            rgbx[i * 4 + 1] = rgb[i * 3 + 1]
            rgbx[i * 4 + 2] = rgb[i * 3 + 2]
            rgbx[i * 4 + 3] = 0xFF
        }

        guard let provider = CGDataProvider(data: Data(rgbx) as CFData),
              let cg = CGImage(
                width: width, height: height,
                bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: width * 4,
                space: cs, bitmapInfo: bitmapInfo,
                provider: provider, decode: nil,
                shouldInterpolate: false, intent: .defaultIntent
              ) else {
            throw BenchError.codecFailed("ImageIO: CGImage construction failed")
        }

        let output = NSMutableData()
        let type: CFString = UTType.jpeg.identifier as CFString
        guard let dest = CGImageDestinationCreateWithData(output, type, 1, nil) else {
            throw BenchError.codecFailed("ImageIO: destination creation failed")
        }
        let props: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: Double(quality) / 100.0
        ]
        CGImageDestinationAddImage(dest, cg, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            throw BenchError.codecFailed("ImageIO: finalize failed")
        }
        return [UInt8](output as Data)
    }

    func decode(jpeg: [UInt8]) throws -> (rgb: [UInt8], width: Int, height: Int) {
        guard let src = CGImageSourceCreateWithData(Data(jpeg) as CFData, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            throw BenchError.codecFailed("ImageIO: decode failed")
        }
        let w = cg.width, h = cg.height
        var rgbx = [UInt8](repeating: 0, count: w * h * 4)
        let cs = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.noneSkipLast.rawValue
        guard let ctx = rgbx.withUnsafeMutableBytes({ ptr -> CGContext? in
            CGContext(
                data: ptr.baseAddress,
                width: w, height: h,
                bitsPerComponent: 8, bytesPerRow: w * 4,
                space: cs, bitmapInfo: bitmapInfo
            )
        }) else {
            throw BenchError.codecFailed("ImageIO: context creation failed")
        }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))

        var rgb = [UInt8](repeating: 0, count: w * h * 3)
        for i in 0..<(w * h) {
            rgb[i * 3]     = rgbx[i * 4]
            rgb[i * 3 + 1] = rgbx[i * 4 + 1]
            rgb[i * 3 + 2] = rgbx[i * 4 + 2]
        }
        return (rgb, w, h)
    }
}
