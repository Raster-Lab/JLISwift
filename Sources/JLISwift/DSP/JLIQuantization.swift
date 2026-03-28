// SPDX-License-Identifier: Apache-2.0
// Copyright 2024 Raster Lab. All rights reserved.

/// Quantization tables, zigzag scan ordering, and quantization operations.
enum Quantization {

    // MARK: - Zigzag Scan Order

    /// Maps zigzag position (0–63) to block index (row × 8 + col).
    static let zigzagOrder: [Int] = [
         0,  1,  8, 16,  9,  2,  3, 10,
        17, 24, 32, 25, 18, 11,  4,  5,
        12, 19, 26, 33, 40, 48, 41, 34,
        27, 20, 13,  6,  7, 14, 21, 28,
        35, 42, 49, 56, 57, 50, 43, 36,
        29, 22, 15, 23, 30, 37, 44, 51,
        58, 59, 52, 45, 38, 31, 39, 46,
        53, 60, 61, 54, 47, 55, 62, 63
    ]

    /// Maps block index to zigzag position (inverse of `zigzagOrder`).
    static let inverseZigzagOrder: [Int] = {
        var inverse = [Int](repeating: 0, count: 64)
        for i in 0..<64 {
            inverse[zigzagOrder[i]] = i
        }
        return inverse
    }()

    /// Reorders a block from natural order to zigzag order.
    static func zigzagScan(_ block: [Int32]) -> [Int32] {
        var result = [Int32](repeating: 0, count: 64)
        for i in 0..<64 {
            result[i] = block[zigzagOrder[i]]
        }
        return result
    }

    /// Reorders a block from zigzag order to natural order.
    static func inverseZigzagScan(_ zigzag: [Int32]) -> [Int32] {
        var result = [Int32](repeating: 0, count: 64)
        for i in 0..<64 {
            result[zigzagOrder[i]] = zigzag[i]
        }
        return result
    }

    // MARK: - Standard Quantization Tables (ITU-T T.81 Annex K)

    /// Standard JPEG luminance quantization table at quality 50.
    static let standardLuminanceTable: [Int] = [
        16, 11, 10, 16,  24,  40,  51,  61,
        12, 12, 14, 19,  26,  58,  60,  55,
        14, 13, 16, 24,  40,  57,  69,  56,
        14, 17, 22, 29,  51,  87,  80,  62,
        18, 22, 37, 56,  68, 109, 103,  77,
        24, 35, 55, 64,  81, 104, 113,  92,
        49, 64, 78, 87, 103, 121, 120, 101,
        72, 92, 95, 98, 112, 100, 103,  99
    ]

    /// Standard JPEG chrominance quantization table at quality 50.
    static let standardChrominanceTable: [Int] = [
        17, 18, 24, 47, 99, 99, 99, 99,
        18, 21, 26, 66, 99, 99, 99, 99,
        24, 26, 56, 99, 99, 99, 99, 99,
        47, 66, 99, 99, 99, 99, 99, 99,
        99, 99, 99, 99, 99, 99, 99, 99,
        99, 99, 99, 99, 99, 99, 99, 99,
        99, 99, 99, 99, 99, 99, 99, 99,
        99, 99, 99, 99, 99, 99, 99, 99
    ]

    /// Scales a quantization table for a given JPEG quality (0–100).
    ///
    /// Uses the standard IJG quality scaling formula.
    static func scaleTable(_ baseTable: [Int], quality: Int) -> [Int] {
        let q = max(1, min(100, quality))
        let scale: Int
        if q < 50 {
            scale = 5000 / q
        } else {
            scale = 200 - 2 * q
        }
        return baseTable.map { entry in
            max(1, min(255, (entry * scale + 50) / 100))
        }
    }

    /// Quantizes a block of DCT coefficients using the given quantization table.
    ///
    /// - Parameters:
    ///   - dctBlock: 64 floating-point DCT coefficients in natural order.
    ///   - table: 64-element quantization table.
    /// - Returns: 64 quantized integer coefficients in natural order.
    static func quantize(_ dctBlock: [Float], table: [Int]) -> [Int32] {
        var result = [Int32](repeating: 0, count: 64)
        for i in 0..<64 {
            result[i] = Int32((dctBlock[i] / Float(table[i])).rounded(.toNearestOrEven))
        }
        return result
    }

    /// Dequantizes a block of quantized coefficients.
    ///
    /// - Parameters:
    ///   - quantized: 64 quantized integer coefficients in natural order.
    ///   - table: 64-element quantization table.
    /// - Returns: 64 floating-point DCT coefficients.
    static func dequantize(_ quantized: [Int32], table: [Int]) -> [Float] {
        var result = [Float](repeating: 0, count: 64)
        for i in 0..<64 {
            result[i] = Float(quantized[i]) * Float(table[i])
        }
        return result
    }
}
