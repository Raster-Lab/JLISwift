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

        // The x-mapping (source columns + fractional weight) is identical for
        // every row, so precompute it once instead of per pixel. The inner loop
        // then uses raw pointers for the source/destination planes, avoiding the
        // per-element copy-on-write check that dominated the decode profile.
        // Same bilinear formula and operand order → byte-identical output.
        let xScale = Float(width - 1) / Float(max(1, targetWidth - 1))
        var sx0 = [Int](repeating: 0, count: targetWidth)
        var sx1 = [Int](repeating: 0, count: targetWidth)
        var fxs = [Float](repeating: 0, count: targetWidth)
        for tx in 0..<targetWidth {
            let srcX = Float(tx) * xScale
            let x0 = min(Int(srcX), width - 1)
            sx0[tx] = x0
            sx1[tx] = min(x0 + 1, width - 1)
            fxs[tx] = srcX - Float(x0)
        }
        let yScale = Float(height - 1) / Float(max(1, targetHeight - 1))

        var result = [Float](unsafeUninitializedCapacity: targetWidth * targetHeight) {
            _, c in c = targetWidth * targetHeight
        }
        plane.withUnsafeBufferPointer { srcBuf in
            result.withUnsafeMutableBufferPointer { dstBuf in
                sx0.withUnsafeBufferPointer { x0b in
                    sx1.withUnsafeBufferPointer { x1b in
                        fxs.withUnsafeBufferPointer { fxb in
                            let p = srcBuf.baseAddress!, d = dstBuf.baseAddress!
                            let X0 = x0b.baseAddress!, X1 = x1b.baseAddress!, FX = fxb.baseAddress!
                            for ty in 0..<targetHeight {
                                let srcY = Float(ty) * yScale
                                let sy0 = min(Int(srcY), height - 1)
                                let sy1 = min(sy0 + 1, height - 1)
                                let fy = srcY - Float(sy0)
                                let row0 = sy0 * width, row1 = sy1 * width
                                let drow = ty * targetWidth
                                for tx in 0..<targetWidth {
                                    let x0 = X0[tx], x1 = X1[tx], fx = FX[tx]
                                    let v00 = p[row0 + x0], v10 = p[row0 + x1]
                                    let v01 = p[row1 + x0], v11 = p[row1 + x1]
                                    d[drow + tx] = v00 * (1 - fx) * (1 - fy) + v10 * fx * (1 - fy) +
                                                   v01 * (1 - fx) * fy + v11 * fx * fy
                                }
                            }
                        }
                    }
                }
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
