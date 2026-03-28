// SPDX-License-Identifier: Apache-2.0
// Copyright 2024 Raster Lab. All rights reserved.

import Testing
@testable import JLISwift

@Suite("DCT – Forward and Inverse Discrete Cosine Transform")
struct DCTTests {

    @Test("Forward DCT of all-zero block returns all zeros")
    func forwardDCTZeroBlock() {
        let block = [Float](repeating: 0, count: 64)
        let result = DCT.forward(block)
        for coeff in result {
            #expect(abs(coeff) < 1e-5)
        }
    }

    @Test("Forward DCT of constant block concentrates energy in DC")
    func forwardDCTConstantBlock() {
        // A constant block should produce a non-zero DC and near-zero AC
        let block = [Float](repeating: 100.0, count: 64)
        let result = DCT.forward(block)

        // DC coefficient should be 100 * 8 = 800 (due to normalization)
        #expect(abs(result[0] - 800.0) < 1.0)

        // All AC coefficients should be near zero
        for i in 1..<64 {
            #expect(abs(result[i]) < 1e-3, "AC coefficient at index \(i) is \(result[i])")
        }
    }

    @Test("Forward then inverse DCT round-trips correctly")
    func forwardInverseRoundTrip() {
        // Create a test pattern
        var block = [Float](repeating: 0, count: 64)
        for i in 0..<64 {
            block[i] = Float(i) * 3.0 - 96.0
        }

        let dctResult = DCT.forward(block)
        let reconstructed = DCT.inverse(dctResult)

        // Should reconstruct within floating-point tolerance
        for i in 0..<64 {
            #expect(abs(reconstructed[i] - block[i]) < 0.01,
                    "Mismatch at index \(i): expected \(block[i]), got \(reconstructed[i])")
        }
    }

    @Test("Inverse DCT of all-zero block returns all zeros")
    func inverseDCTZeroBlock() {
        let block = [Float](repeating: 0, count: 64)
        let result = DCT.inverse(block)
        for pixel in result {
            #expect(abs(pixel) < 1e-5)
        }
    }

    @Test("DCT preserves energy (Parseval's theorem)")
    func dctPreservesEnergy() {
        var block = [Float](repeating: 0, count: 64)
        for i in 0..<64 {
            block[i] = Float(i % 8) * 30.0 + Float(i / 8) * 5.0 - 100.0
        }

        let energyBefore = block.reduce(Float(0)) { $0 + $1 * $1 }
        let dctResult = DCT.forward(block)
        let energyAfter = dctResult.reduce(Float(0)) { $0 + $1 * $1 }

        // Energies should be equal (orthonormal transform)
        #expect(abs(energyBefore - energyAfter) / energyBefore < 0.01)
    }

    @Test("Cosine matrix is orthonormal")
    func cosineMatrixOrthonormal() {
        let c = DCT.cosineMatrix
        let ct = DCT.cosineMatrixTransposed

        // C * C^T should equal identity
        var product = [Float](repeating: 0, count: 64)
        for i in 0..<8 {
            for j in 0..<8 {
                var sum: Float = 0
                for k in 0..<8 {
                    sum += c[i * 8 + k] * ct[k * 8 + j]
                }
                product[i * 8 + j] = sum
            }
        }

        for i in 0..<8 {
            for j in 0..<8 {
                let expected: Float = (i == j) ? 1.0 : 0.0
                #expect(abs(product[i * 8 + j] - expected) < 1e-5)
            }
        }
    }
}
