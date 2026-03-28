// SPDX-License-Identifier: Apache-2.0
// Copyright 2024 Raster Lab. All rights reserved.

/// Chroma subsampling and upsampling operations.
///
/// Handles chroma plane downsampling (encoder) and upsampling (decoder)
/// for the supported subsampling modes: 4:4:4, 4:2:2, 4:2:0, and 4:0:0.
enum ChromaSampling {

    /// Downsamples a component plane by a factor of 2 in each specified dimension.
    ///
    /// Uses simple box filtering (averaging) for downsampling.
    ///
    /// - Parameters:
    ///   - plane: Source plane data.
    ///   - width: Source plane width.
    ///   - height: Source plane height.
    ///   - horizontally: Whether to downsample horizontally (halve width).
    ///   - vertically: Whether to downsample vertically (halve height).
    /// - Returns: Downsampled plane data and new dimensions.
    static func downsample(_ plane: [Float], width: Int, height: Int,
                           horizontally: Bool, vertically: Bool) -> (data: [Float], width: Int, height: Int) {
        guard horizontally || vertically else {
            return (plane, width, height)
        }

        let newWidth = horizontally ? (width + 1) / 2 : width
        let newHeight = vertically ? (height + 1) / 2 : height
        var result = [Float](repeating: 0, count: newWidth * newHeight)

        let hStep = horizontally ? 2 : 1
        let vStep = vertically ? 2 : 1

        for dy in 0..<newHeight {
            for dx in 0..<newWidth {
                var sum: Float = 0
                var count: Float = 0
                for vy in 0..<vStep {
                    let sy = dy * vStep + vy
                    guard sy < height else { continue }
                    for vx in 0..<hStep {
                        let sx = dx * hStep + vx
                        guard sx < width else { continue }
                        sum += plane[sy * width + sx]
                        count += 1
                    }
                }
                result[dy * newWidth + dx] = sum / count
            }
        }

        return (result, newWidth, newHeight)
    }

    /// Upsamples a component plane by a factor of 2 in each specified dimension.
    ///
    /// Uses bilinear interpolation for smooth upsampling.
    ///
    /// - Parameters:
    ///   - plane: Source plane data.
    ///   - width: Source plane width.
    ///   - height: Source plane height.
    ///   - targetWidth: Target width after upsampling.
    ///   - targetHeight: Target height after upsampling.
    /// - Returns: Upsampled plane data.
    static func upsample(_ plane: [Float], width: Int, height: Int,
                          targetWidth: Int, targetHeight: Int) -> [Float] {
        guard targetWidth != width || targetHeight != height else {
            return plane
        }

        var result = [Float](repeating: 0, count: targetWidth * targetHeight)

        for ty in 0..<targetHeight {
            let srcY = Float(ty) * Float(height - 1) / Float(max(1, targetHeight - 1))
            let sy0 = min(Int(srcY), height - 1)
            let sy1 = min(sy0 + 1, height - 1)
            let fy = srcY - Float(sy0)

            for tx in 0..<targetWidth {
                let srcX = Float(tx) * Float(width - 1) / Float(max(1, targetWidth - 1))
                let sx0 = min(Int(srcX), width - 1)
                let sx1 = min(sx0 + 1, width - 1)
                let fx = srcX - Float(sx0)

                let v00 = plane[sy0 * width + sx0]
                let v10 = plane[sy0 * width + sx1]
                let v01 = plane[sy1 * width + sx0]
                let v11 = plane[sy1 * width + sx1]

                let value = v00 * (1 - fx) * (1 - fy) + v10 * fx * (1 - fy) +
                            v01 * (1 - fx) * fy + v11 * fx * fy
                result[ty * targetWidth + tx] = value
            }
        }

        return result
    }

    /// Returns the horizontal and vertical sampling factors for a subsampling mode.
    static func samplingFactors(for mode: JLIChromaSubsampling) -> (h: Int, v: Int) {
        switch mode {
        case .yuv444: return (1, 1)
        case .yuv422: return (2, 1)
        case .yuv420: return (2, 2)
        case .yuv400: return (1, 1)  // Grayscale, no chroma
        }
    }
}
