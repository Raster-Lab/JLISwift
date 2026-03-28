// SPDX-License-Identifier: Apache-2.0
// Copyright 2024 Raster Lab. All rights reserved.

import Foundation

/// Forward and inverse Discrete Cosine Transform for 8×8 blocks.
///
/// Implements the JPEG standard Type-II DCT (forward) and Type-III DCT (inverse)
/// using a floating-point precision pipeline as per the jpegli approach.
enum DCT {

    /// Precomputed 8×8 DCT cosine matrix.
    ///
    /// `C[u][n] = alpha(u) * cos((2n + 1) * u * π / 16)`
    /// where `alpha(0) = 1/sqrt(8)`, `alpha(u>0) = sqrt(2/8) = 1/2`.
    static let cosineMatrix: [Float] = {
        var matrix = [Float](repeating: 0, count: 64)
        for u in 0..<8 {
            let alpha: Float = u == 0 ? 1.0 / sqrt(8.0) : sqrt(2.0 / 8.0)
            for n in 0..<8 {
                matrix[u * 8 + n] = alpha * cos(Float(2 * n + 1) * Float(u) * .pi / 16.0)
            }
        }
        return matrix
    }()

    /// Transposed cosine matrix (used for inverse DCT and column transforms).
    static let cosineMatrixTransposed: [Float] = {
        var transposed = [Float](repeating: 0, count: 64)
        for u in 0..<8 {
            for n in 0..<8 {
                transposed[n * 8 + u] = cosineMatrix[u * 8 + n]
            }
        }
        return transposed
    }()

    /// Performs an 8×8 forward DCT on the given block.
    ///
    /// The input block is in natural (row-major) order, 64 elements.
    /// The output is 64 DCT coefficients in natural order.
    ///
    /// - Parameter block: 64 floating-point pixel values (level-shifted by -128).
    /// - Returns: 64 DCT coefficients.
    static func forward(_ block: [Float]) -> [Float] {
        // F = C * f * C^T  (two matrix multiplications)
        var temp = [Float](repeating: 0, count: 64)
        var result = [Float](repeating: 0, count: 64)

        // temp = C * f (transform rows)
        matmul8x8(cosineMatrix, block, &temp)
        // result = temp * C^T (transform columns)
        matmul8x8(temp, cosineMatrixTransposed, &result)

        return result
    }

    /// Performs an 8×8 inverse DCT on the given block.
    ///
    /// The input block is 64 DCT coefficients in natural order.
    /// The output is 64 pixel values that should be level-shifted by +128.
    ///
    /// - Parameter block: 64 DCT coefficients.
    /// - Returns: 64 floating-point pixel values (before level shift).
    static func inverse(_ block: [Float]) -> [Float] {
        // f = C^T * F * C  (two matrix multiplications)
        var temp = [Float](repeating: 0, count: 64)
        var result = [Float](repeating: 0, count: 64)

        // temp = C^T * F
        matmul8x8(cosineMatrixTransposed, block, &temp)
        // result = temp * C
        matmul8x8(temp, cosineMatrix, &result)

        return result
    }

    /// Multiplies two 8×8 matrices: C = A * B.
    @inline(__always)
    private static func matmul8x8(_ a: [Float], _ b: [Float], _ c: inout [Float]) {
        for i in 0..<8 {
            for j in 0..<8 {
                var sum: Float = 0
                for k in 0..<8 {
                    sum += a[i * 8 + k] * b[k * 8 + j]
                }
                c[i * 8 + j] = sum
            }
        }
    }
}
