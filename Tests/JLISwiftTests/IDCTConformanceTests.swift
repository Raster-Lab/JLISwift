// SPDX-License-Identifier: Apache-2.0
// Copyright 2024 Raster Lab. All rights reserved.

import Testing
@testable import JLISwift

/// ISO/IEC 10918-2 (JPEG Part 2) Annex A — inverse-DCT accuracy procedure.
///
/// The standard defines a statistical conformance test for an 8×8 IDCT: feed
/// many random coefficient blocks through both the implementation's IDCT and a
/// double-precision reference IDCT (the exact separable cosine sum), then bound
/// the per-pixel error statistics. An implementation "conforms" when, over the
/// block ensemble, every one of these holds:
///
///   • peak absolute error              ≤ 1      (no reconstructed pel off by >1)
///   • peak per-position mean-sq error  ≤ 0.06
///   • overall mean-square error        ≤ 0.02
///   • peak per-position mean error     ≤ 0.015  (|bias| at any pel position)
///   • overall mean error               ≤ 0.0015 (|bias| over all positions)
///
/// The procedure is run for three input ranges (Annex A.3.3): coefficients drawn
/// so that the spatial reference output lands in [−256, 255], [−5, 5] and
/// [−300, 300]. We approximate the spec's input generation by drawing random
/// *spatial* blocks in each range, forward-transforming them to coefficients with
/// the exact DCT, rounding to integers (as a real encoder would), and using those
/// integer coefficients as the IDCT input — exactly the data an IDCT sees in a
/// decoder. The reference is computed in `Double`; the implementation under test
/// is ``DCT/inverse`` (the production Accelerate IDCT). A fixed-seed PRNG keeps
/// the test deterministic and CI-reproducible.
@Suite("IDCT accuracy (ISO/IEC 10918-2 Annex A)")
struct IDCTConformanceTests {

    /// Deterministic SplitMix64 → uniform integers, so the ensemble is identical
    /// on every run (a conformance result must be reproducible).
    private struct SplitMix64 {
        var state: UInt64
        init(_ seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        /// Uniform integer in `lo...hi` inclusive.
        mutating func int(_ lo: Int, _ hi: Int) -> Int {
            let span = UInt64(hi - lo + 1)
            return lo + Int(next() % span)
        }
    }

    /// Exact double-precision separable 8×8 IDCT (the conformance reference):
    /// f(x,y) = ¼ Σ_u Σ_v C(u)C(v) F(u,v) cos((2x+1)uπ/16) cos((2y+1)vπ/16).
    private static func referenceIDCT(_ coeff: [Double]) -> [Double] {
        // Precompute the cosine/scale table once per call (64 entries).
        var cos = [Double](repeating: 0, count: 64)   // cos[u*8 + x]
        for u in 0..<8 {
            let cu = u == 0 ? (1.0 / 2.0.squareRoot()) : 1.0
            for x in 0..<8 {
                cos[u * 8 + x] = cu * Foundation_cos((Double(2 * x + 1) * Double(u) * Double.pi) / 16.0)
            }
        }
        var out = [Double](repeating: 0, count: 64)
        for y in 0..<8 {
            for x in 0..<8 {
                var sum = 0.0
                for u in 0..<8 {
                    for v in 0..<8 {
                        sum += coeff[v * 8 + u] * cos[u * 8 + x] * cos[v * 8 + y]
                    }
                }
                out[y * 8 + x] = sum / 4.0
            }
        }
        return out
    }

    /// Runs the Annex A statistics for one spatial range and asserts the bounds.
    private func runRange(lo: Int, hi: Int, seed: UInt64, blocks: Int = 10_000) {
        var rng = SplitMix64(seed)
        var sumErr = [Double](repeating: 0, count: 64)     // Σ (impl − ref)  per position
        var sumSq  = [Double](repeating: 0, count: 64)     // Σ (impl − ref)² per position
        var peakAbs = 0.0

        for _ in 0..<blocks {
            // Random integer spatial block in [lo, hi].
            var spatial = [Float](repeating: 0, count: 64)
            for i in 0..<64 { spatial[i] = Float(rng.int(lo, hi)) }
            // Forward-transform and round to integer coefficients — the real
            // quantized-coefficient distribution an IDCT decodes.
            let fwd = DCT.forward(spatial)
            var coeffF = [Float](repeating: 0, count: 64)
            var coeffD = [Double](repeating: 0, count: 64)
            for i in 0..<64 {
                let q = (fwd[i]).rounded()
                coeffF[i] = q
                coeffD[i] = Double(q)
            }
            // Implementation under test vs double-precision reference.
            let impl = DCT.inverse(coeffF)
            let ref = Self.referenceIDCT(coeffD)
            for i in 0..<64 {
                // Both rounded to integer pels, as a decoder emits.
                let e = Double((impl[i]).rounded()) - ref[i].rounded()
                sumErr[i] += e
                sumSq[i]  += e * e
                peakAbs = max(peakAbs, abs(e))
            }
        }

        let n = Double(blocks)
        var peakMeanSq = 0.0, overallSq = 0.0
        var peakMean = 0.0, overallMean = 0.0
        for i in 0..<64 {
            let msq = sumSq[i] / n
            let mean = sumErr[i] / n
            peakMeanSq = max(peakMeanSq, msq)
            peakMean = max(peakMean, abs(mean))
            overallSq += sumSq[i]
            overallMean += sumErr[i]
        }
        overallSq /= (n * 64)
        overallMean = abs(overallMean) / (n * 64)

        let label = "[\(lo),\(hi)]"
        // Emit the measured margins so the conformance evidence is recorded, not
        // just a pass/fail (limits: peakAbs≤1, peakMSq≤0.06, MSq≤0.02,
        // peakMean≤0.015, mean≤0.0015).
        print(String(format: "IDCT-CONFORMANCE %@ peakAbs=%.3f peakMSq=%.4f MSq=%.5f peakMean=%.5f mean=%.6f",
                     label, peakAbs, peakMeanSq, overallSq, peakMean, overallMean))
        #expect(peakAbs <= 1.0,        "\(label) peak abs error \(peakAbs) > 1")
        #expect(peakMeanSq <= 0.06,    "\(label) peak mean-sq \(peakMeanSq) > 0.06")
        #expect(overallSq <= 0.02,     "\(label) overall mean-sq \(overallSq) > 0.02")
        #expect(peakMean <= 0.015,     "\(label) peak mean \(peakMean) > 0.015")
        #expect(overallMean <= 0.0015, "\(label) overall mean \(overallMean) > 0.0015")
    }

    @Test("IDCT accuracy, full range [-256, 255]")
    func fullRange() { runRange(lo: -256, hi: 255, seed: 0x1234_5678) }

    @Test("IDCT accuracy, small range [-5, 5]")
    func smallRange() { runRange(lo: -5, hi: 5, seed: 0xABCD_EF01) }

    @Test("IDCT accuracy, over-range [-300, 300]")
    func overRange() { runRange(lo: -300, hi: 300, seed: 0x0FED_CBA9) }
}

// `cos` from the C math library, namespaced to avoid clashing with the local
// cosine table variable above.
#if canImport(Darwin)
import Darwin
private func Foundation_cos(_ x: Double) -> Double { Darwin.cos(x) }
#else
import Glibc
private func Foundation_cos(_ x: Double) -> Double { Glibc.cos(x) }
#endif
