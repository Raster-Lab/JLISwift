// SPDX-License-Identifier: Apache-2.0
// Copyright 2024 Raster Lab. All rights reserved.

import Foundation
import CoreGraphics

/// Builds `CGImage`s from raw 8-bit RGB buffers for display. All panes render
/// through here so they share one pixel-order convention (row 0 = top).
enum Render {

    static func cgImage(rgb8: [UInt8], width: Int, height: Int) -> CGImage? {
        guard width > 0, height > 0, rgb8.count >= width * height * 3 else { return nil }
        // Expand to 32-bpp RGBA with an opaque (ignored) alpha. SwiftUI composites
        // images through Core Animation / the GPU, which renders 24-bpp no-alpha
        // CGImages unreliably (often as a blank/white tile); 32-bpp RGBA is the
        // format the compositor handles correctly.
        let pixels = width * height
        var rgba = [UInt8](repeating: 0, count: pixels * 4)
        for i in 0..<pixels {
            rgba[i * 4]     = rgb8[i * 3]
            rgba[i * 4 + 1] = rgb8[i * 3 + 1]
            rgba[i * 4 + 2] = rgb8[i * 3 + 2]
            rgba[i * 4 + 3] = 255
        }
        let cs = CGColorSpaceCreateDeviceRGB()
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue)
        guard let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: cs, bitmapInfo: info,
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )
    }

    /// Amplified per-pixel absolute difference between two RGB buffers, rendered
    /// as a grayscale heat image (brighter = larger error). `amplification` scales
    /// the raw error so subtle artifacts become visible.
    static func differenceImage(
        original: [UInt8], decoded: [UInt8], width: Int, height: Int, amplification: Double
    ) -> CGImage? {
        let pixels = width * height
        guard original.count >= pixels * 3, decoded.count >= pixels * 3 else { return nil }
        var diff = [UInt8](repeating: 0, count: pixels * 3)
        for i in 0..<pixels {
            var e = 0
            for c in 0..<3 { e += abs(Int(original[i*3+c]) - Int(decoded[i*3+c])) }
            let v = min(255, Int(Double(e) / 3.0 * amplification + 0.5))
            let g = UInt8(v)
            diff[i*3] = g; diff[i*3+1] = g; diff[i*3+2] = g
        }
        return cgImage(rgb8: diff, width: width, height: height)
    }
}
