// SPDX-License-Identifier: Apache-2.0
// Copyright 2024 Raster Lab. All rights reserved.

/// Accelerate framework-optimised implementations of DSP operations.
///
/// Provides hardware-accelerated DCT, matrix multiply, and color conversion
/// on Apple platforms. Falls back to pure-Swift implementations when Accelerate
/// is not available.

#if canImport(Accelerate)
import Accelerate

/// Accelerate-backed DSP operations for the JPEG pipeline.
enum AccelerateDSP {

    // MARK: - DCT

    /// Precomputed 8×8 DCT matrix for use with Accelerate.
    private static let dctMatrix: [Float] = {
        var matrix = [Float](repeating: 0, count: 64)
        let n = 8
        for u in 0..<n {
            for x in 0..<n {
                let alpha: Float = u == 0 ? 1.0 / sqrt(Float(2 * n)) : sqrt(2.0 / Float(n)) / 2.0
                matrix[u * n + x] = alpha * cos(Float(2 * x + 1) * Float(u) * .pi / Float(2 * n))
            }
        }
        return matrix
    }()

    /// Transposed DCT matrix.
    private static let dctMatrixTransposed: [Float] = {
        var transposed = [Float](repeating: 0, count: 64)
        for i in 0..<8 {
            for j in 0..<8 {
                transposed[j * 8 + i] = dctMatrix[i * 8 + j]
            }
        }
        return transposed
    }()

    /// Performs forward 2D DCT on an 8×8 block using Accelerate matrix multiply.
    ///
    /// Computes `F = C × f × Cᵀ` where C is the DCT matrix.
    static func forwardDCT(_ block: inout [Float]) {
        var temp = [Float](repeating: 0, count: 64)
        var result = [Float](repeating: 0, count: 64)

        // temp = C × block (transform rows)
        vDSP_mmul(dctMatrix, 1, block, 1, &temp, 1, 8, 8, 8)
        // result = temp × Cᵀ (transform columns)
        vDSP_mmul(temp, 1, dctMatrixTransposed, 1, &result, 1, 8, 8, 8)

        block = result
    }

    /// Performs inverse 2D DCT on an 8×8 block using Accelerate matrix multiply.
    ///
    /// Computes `f = Cᵀ × F × C` where C is the DCT matrix.
    static func inverseDCT(_ block: inout [Float]) {
        var temp = [Float](repeating: 0, count: 64)
        var result = [Float](repeating: 0, count: 64)

        // temp = Cᵀ × block (inverse rows)
        vDSP_mmul(dctMatrixTransposed, 1, block, 1, &temp, 1, 8, 8, 8)
        // result = temp × C (inverse columns)
        vDSP_mmul(temp, 1, dctMatrix, 1, &result, 1, 8, 8, 8)

        block = result
    }

    // MARK: - Color Conversion

    /// Converts RGB to YCbCr for a row of pixels using Accelerate vector operations.
    ///
    /// - Parameters:
    ///   - r: Red channel values (0–255 as Float).
    ///   - g: Green channel values.
    ///   - b: Blue channel values.
    /// - Returns: (Y, Cb, Cr) channel arrays.
    static func rgbToYCbCr(
        r: [Float], g: [Float], b: [Float]
    ) -> (y: [Float], cb: [Float], cr: [Float]) {
        let count = r.count
        var y = [Float](repeating: 0, count: count)
        var cb = [Float](repeating: 0, count: count)
        var cr = [Float](repeating: 0, count: count)

        // Y = 0.299R + 0.587G + 0.114B
        var temp1 = [Float](repeating: 0, count: count)
        var temp2 = [Float](repeating: 0, count: count)
        var scale: Float = 0.299
        vDSP_vsmul(r, 1, &scale, &y, 1, vDSP_Length(count))
        scale = 0.587
        vDSP_vsmul(g, 1, &scale, &temp1, 1, vDSP_Length(count))
        vDSP_vadd(y, 1, temp1, 1, &y, 1, vDSP_Length(count))
        scale = 0.114
        vDSP_vsmul(b, 1, &scale, &temp1, 1, vDSP_Length(count))
        vDSP_vadd(y, 1, temp1, 1, &y, 1, vDSP_Length(count))

        // Cb = -0.168736R - 0.331264G + 0.5B + 128
        scale = -0.168736
        vDSP_vsmul(r, 1, &scale, &cb, 1, vDSP_Length(count))
        scale = -0.331264
        vDSP_vsmul(g, 1, &scale, &temp1, 1, vDSP_Length(count))
        vDSP_vadd(cb, 1, temp1, 1, &cb, 1, vDSP_Length(count))
        scale = 0.5
        vDSP_vsmul(b, 1, &scale, &temp1, 1, vDSP_Length(count))
        vDSP_vadd(cb, 1, temp1, 1, &cb, 1, vDSP_Length(count))
        scale = 128.0
        vDSP_vsadd(cb, 1, &scale, &cb, 1, vDSP_Length(count))

        // Cr = 0.5R - 0.418688G - 0.081312B + 128
        scale = 0.5
        vDSP_vsmul(r, 1, &scale, &cr, 1, vDSP_Length(count))
        scale = -0.418688
        vDSP_vsmul(g, 1, &scale, &temp1, 1, vDSP_Length(count))
        vDSP_vadd(cr, 1, temp1, 1, &cr, 1, vDSP_Length(count))
        scale = -0.081312
        vDSP_vsmul(b, 1, &scale, &temp2, 1, vDSP_Length(count))
        vDSP_vadd(cr, 1, temp2, 1, &cr, 1, vDSP_Length(count))
        scale = 128.0
        vDSP_vsadd(cr, 1, &scale, &cr, 1, vDSP_Length(count))

        return (y, cb, cr)
    }

    // MARK: - Block Operations

    /// Level-shifts an 8×8 block by subtracting 128 using Accelerate.
    static func levelShift(_ block: inout [Float]) {
        var offset: Float = -128.0
        vDSP_vsadd(block, 1, &offset, &block, 1, 64)
    }

    /// Inverse level-shifts an 8×8 block by adding 128 and clamping to 0–255.
    static func inverseLevelShift(_ block: inout [Float]) {
        var offset: Float = 128.0
        vDSP_vsadd(block, 1, &offset, &block, 1, 64)
        var low: Float = 0.0
        var high: Float = 255.0
        vDSP_vclip(block, 1, &low, &high, &block, 1, 64)
    }
}
#endif
