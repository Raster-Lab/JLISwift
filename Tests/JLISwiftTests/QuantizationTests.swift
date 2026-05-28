// SPDX-License-Identifier: Apache-2.0
// Copyright 2024 Raster Lab. All rights reserved.

import Testing
@testable import JLISwift

@Suite("Quantization – Tables, Zigzag, and Quantize/Dequantize")
struct QuantizationTests {

    // MARK: - Zigzag Ordering

    @Test("Zigzag order position 0 is DC coefficient (index 0)")
    func zigzagDCIsFirst() {
        #expect(Quantization.zigzagOrder[0] == 0)
    }

    @Test("Zigzag order has correct length")
    func zigzagOrderLength() {
        #expect(Quantization.zigzagOrder.count == 64)
    }

    @Test("Inverse zigzag order undoes zigzag")
    func inverseZigzagRoundTrip() {
        for i in 0..<64 {
            let zigzagPos = Quantization.inverseZigzagOrder[i]
            #expect(Quantization.zigzagOrder[zigzagPos] == i)
        }
    }

    @Test("Zigzag scan round-trips correctly")
    func zigzagScanRoundTrip() {
        var block = [Int32](repeating: 0, count: 64)
        for i in 0..<64 { block[i] = Int32(i * 3 + 7) }

        let scanned = Quantization.zigzagScan(block)
        let restored = Quantization.inverseZigzagScan(scanned)
        #expect(block == restored)
    }

    // MARK: - Quantization Tables

    @Test("Standard luminance table has 64 values")
    func luminanceTableSize() {
        #expect(Quantization.standardLuminanceTable.count == 64)
    }

    @Test("Standard chrominance table has 64 values")
    func chrominanceTableSize() {
        #expect(Quantization.standardChrominanceTable.count == 64)
    }

    @Test("Standard tables have no zero values")
    func tablesNonZero() {
        for val in Quantization.standardLuminanceTable {
            #expect(val > 0)
        }
        for val in Quantization.standardChrominanceTable {
            #expect(val > 0)
        }
    }

    // MARK: - Quality Scaling

    @Test("Quality 50 returns the standard table")
    func quality50ReturnsStandard() {
        let scaled = Quantization.scaleTable(Quantization.standardLuminanceTable, quality: 50)
        #expect(scaled == Quantization.standardLuminanceTable)
    }

    @Test("Quality 100 produces all ones")
    func quality100ProducesOnes() {
        let scaled = Quantization.scaleTable(Quantization.standardLuminanceTable, quality: 100)
        for val in scaled {
            #expect(val == 1)
        }
    }

    @Test("Quality 1 produces maximum quantization")
    func quality1ProducesMaximum() {
        let scaled = Quantization.scaleTable(Quantization.standardLuminanceTable, quality: 1)
        // At quality 1, scale = 5000/1 = 5000
        // The values should be clamped to 255
        for val in scaled {
            #expect(val >= 1 && val <= 255)
        }
    }

    @Test("Scaled table values are clamped between 1 and 255")
    func scaledTableClamped() {
        for q in [1, 10, 25, 50, 75, 90, 100] {
            let scaled = Quantization.scaleTable(Quantization.standardLuminanceTable, quality: q)
            for val in scaled {
                #expect(val >= 1 && val <= 255, "Quality \(q) produced out-of-range value \(val)")
            }
        }
    }

    // MARK: - Quantize / Dequantize

    @Test("Quantizing zero block produces zero block")
    func quantizeZeroBlock() {
        let block = [Float](repeating: 0, count: 64)
        let table = Quantization.standardLuminanceTable
        let quantized = Quantization.quantize(block, table: table)
        for val in quantized {
            #expect(val == 0)
        }
    }

    @Test("Quantize then dequantize approximates original")
    func quantizeDequantizeApproximation() {
        var block = [Float](repeating: 0, count: 64)
        for i in 0..<64 { block[i] = Float(i) * 10.0 - 320.0 }

        let table = Quantization.scaleTable(Quantization.standardLuminanceTable, quality: 90)
        let quantized = Quantization.quantize(block, table: table)
        let dequantized = Quantization.dequantize(quantized, table: table)

        // Dequantized values should be within one quantization step of original
        for i in 0..<64 {
            let maxError = Float(table[i])
            #expect(abs(dequantized[i] - block[i]) <= maxError,
                    "Error at index \(i) exceeds quantization step")
        }
    }

    // MARK: - Distance → Quality (jpegli convention)

    @Test("Distance maps to expected IJG quality landmarks")
    func distanceToQualityLandmarks() {
        // d < 0.1 → top quality.
        #expect(Quantization.qualityForDistance(0.0) == 100.0)
        #expect(Quantization.qualityForDistance(0.05) == 100.0)
        // Linear branch landmarks: d=0.1 → q≈100, d=6.4 → q≈30.
        #expect(abs(Quantization.qualityForDistance(0.1) - 100.0) < 0.01)
        #expect(abs(Quantization.qualityForDistance(6.4) - 30.0) < 0.5)
        // d=1.0 (visually lossless) → q≈90.
        let q1 = Quantization.qualityForDistance(1.0)
        #expect(q1 > 88 && q1 < 92, "distance 1.0 should map to ~q90, got \(q1)")
        // Quadratic branch: large distance → near minimum quality.
        #expect(Quantization.qualityForDistance(100.0) == 1.0)
    }

    @Test("Distance → quality is monotonically decreasing")
    func distanceToQualityMonotonic() {
        var prev = Quantization.qualityForDistance(0.0)
        for step in 1...250 {
            let d = Double(step) * 0.1
            let q = Quantization.qualityForDistance(d)
            #expect(q <= prev + 1e-6, "quality rose from \(prev) to \(q) at distance \(d)")
            prev = q
        }
    }

    @Test("Distance is continuous across the q=30 branch boundary")
    func distanceContinuityAtBoundary() {
        // The linear and quadratic branches meet at d=6.4 (q=30).
        let below = Quantization.qualityForDistance(6.39)
        let above = Quantization.qualityForDistance(6.41)
        #expect(abs(below - above) < 0.5, "discontinuity at branch boundary: \(below) vs \(above)")
    }
}
