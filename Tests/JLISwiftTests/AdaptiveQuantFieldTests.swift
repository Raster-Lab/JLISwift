// SPDX-License-Identifier: Apache-2.0
// Copyright 2024 Raster Lab. All rights reserved.

import Testing
import Foundation
@testable import JLISwift

@Suite("Adaptive-quant field (jpegli port)")
struct AdaptiveQuantFieldTests {

    /// Smooth left half, busy right half — the field must produce finite,
    /// non-negative strengths, and quantize the busy/masked side harder
    /// (higher aq_strength) than the smooth side.
    @Test("Field is finite, ≥0, and higher on busy blocks than smooth")
    func fieldShape() {
        let bw = 12, bh = 8           // 96×64, block grid 12×8
        let w = bw * 8, h = bh * 8
        var plane = [Float](repeating: 0, count: w * h)
        var state: UInt64 = 0xDEAD_BEEF_1234_5678
        func rnd() -> Float {
            state ^= state << 13; state ^= state >> 7; state ^= state << 17
            return Float(state & 0xFF)
        }
        for y in 0..<h {
            for x in 0..<w {
                // left half: smooth gradient; right half: high-frequency noise
                plane[y * w + x] = x < w / 2 ? Float(40 + x) : rnd()
            }
        }

        let field = JLIAdaptiveQuant.computeField(
            plane: plane, width: w, height: h, blocksH: bw, blocksV: bh, yQuant01: 16
        )
        #expect(field.count == bw * bh)
        #expect(field.allSatisfy { $0.isFinite && $0 >= 0 }, "field must be finite and non-negative")

        // Average strength over the smooth (left) vs busy (right) block columns.
        var smooth: Float = 0, busy: Float = 0
        var ns = 0, nb = 0
        for yb in 0..<bh {
            for xb in 0..<bw {
                let v = field[yb * bw + xb]
                if xb < bw / 2 - 1 { smooth += v; ns += 1 }
                else if xb > bw / 2 { busy += v; nb += 1 }
            }
        }
        let smoothAvg = smooth / Float(ns), busyAvg = busy / Float(nb)
        #expect(busyAvg > smoothAvg,
                "busy blocks should quantize harder: busy \(busyAvg) vs smooth \(smoothAvg)")
    }

    @Test("Uniform plane yields a roughly uniform, finite field")
    func uniformField() {
        let bw = 6, bh = 6
        let w = bw * 8, h = bh * 8
        let plane = [Float](repeating: 128, count: w * h)
        let field = JLIAdaptiveQuant.computeField(
            plane: plane, width: w, height: h, blocksH: bw, blocksV: bh, yQuant01: 16
        )
        #expect(field.allSatisfy { $0.isFinite && $0 >= 0 })
        let mn = field.min() ?? 0, mx = field.max() ?? 0
        #expect(mx - mn < 0.05, "uniform input should give a near-uniform field (\(mn)…\(mx))")
    }
}
