// SPDX-License-Identifier: Apache-2.0
// Copyright 2024 Raster Lab. All rights reserved.

import Foundation

/// jpegli adaptive-quantization field (WS-A / 0.3.0). A faithful scalar port of
/// libjxl v0.11.2 `lib/jpegli/adaptive_quantization.cc`: from the luma plane it
/// computes a per-8×8-block `aq_strength` that later modulates a per-coefficient
/// zero-bias (dead-zone) during quantization, quantizing busy/visually-masked
/// blocks harder while preserving smooth (banding-prone) ones.
///
/// This is the field computation only; the zero-bias application + RD-validation
/// vs jpegli are the next WS-A steps. Operates on luma in the [0,255] range
/// (JLISwift's `y` plane), matching the constants' `kInputScaling = 1/255`.
///
/// **Not yet wired into the encoder** — gated behind the forthcoming opt-in
/// quantization path; the simplified `adaptiveQuantField` λ-proxy is unchanged.
enum JLIAdaptiveQuant {

    static let kInputScaling: Float = 1.0 / 255.0

    // MARK: - Pointwise helpers (direct ports)

    /// Visual-masking exponent modulation (`ComputeMask`).
    @inline(__always)
    static func computeMask(_ outVal: Float) -> Float {
        let v1 = max(outVal * 0.74760422233706747, 1e-3)
        let v2 = 1.0 / (v1 + 305.04035728311436)
        let v3 = 1.0 / (v1 * v1 + 2.1925739705298404)
        let v4 = 1.0 / (v1 * v1 + 0.25 * 2.1925739705298404)
        return -0.74174993 + 3.2353257320940401 * v4
            + 12.906028311180409 * v2 + 5.0220313103171232 * v3
    }

    private static let kSGmul: Float = 226.0480446705883
    private static let kSGmul2: Float = 1.0 / 73.377132366608819
    private static let kLog2: Float = 0.693147181
    private static let kSGRetMul: Float = kSGmul2 * 18.6580932135 * kLog2
    private static let kSGVOffset: Float = 7.14672470003

    /// Ratio of derivatives of cube-root vs simple-gamma (moves between jxl opsin
    /// and butteraugli log-gamma space).
    @inline(__always)
    static func ratioOfDerivatives(_ v: Float, invert: Bool) -> Float {
        let kEpsilon: Float = 1e-2
        let kNumOffset = kEpsilon / kInputScaling / kInputScaling
        let kNumMul = kSGRetMul * 3 * kSGmul
        let kVOffset = (kSGVOffset * kLog2 + kEpsilon) / kInputScaling
        let kDenMul = kLog2 * kSGmul * kInputScaling * kInputScaling
        let vv = max(v, 0)
        let v2 = vv * vv
        let num = kNumMul * v2 + kNumOffset
        let den = (kDenMul * vv) * v2 + kVOffset
        return invert ? num / den : den / num
    }

    /// `MaskingSqrt` — a saturating sqrt used in the difference accumulation.
    @inline(__always)
    static func maskingSqrt(_ v: Float) -> Float {
        let mul = Float(211.50759899638012 * 1e8)
        return 0.25 * (v * mul.squareRoot() + 28).squareRoot()
    }

    // MARK: - Per-block modulations

    /// Sum over the 8×8 block of the inverse cube-root/gamma ratio, folded into
    /// the exponent (`GammaModulation`).
    private static func gammaModulation(
        _ p: UnsafePointer<Float>, x: Int, y: Int, width w: Int, _ outVal: Float
    ) -> Float {
        let kBias = 0.16 / kInputScaling
        let kScale = kInputScaling / 64.0
        var overall: Float = 0
        for dy in 0..<8 {
            let row = (y + dy) * w + x
            for dx in 0..<8 {
                overall += ratioOfDerivatives(p[row + dx] + kBias, invert: true)
            }
        }
        overall *= kScale
        let kGamma: Float = -0.15526878023684174 * 0.693147180559945
        return kGamma * log2(overall) + outVal
    }

    /// High-frequency content modulation — sum of |right| and |below| abs diffs
    /// over the block (`HfModulation`).
    private static func hfModulation(
        _ p: UnsafePointer<Float>, x: Int, y: Int, width w: Int, height h: Int, _ outVal: Float
    ) -> Float {
        let kSumCoeff = Float(-2.0052193233688884) * kInputScaling / 112.0
        var sum: Float = 0
        for dy in 0..<8 {
            let row = (y + dy) * w + x
            let nextRow = (dy == 7) ? row : row + w
            for dx in 0..<8 {
                if dx < 7 { sum += abs(p[row + dx] - p[row + dx + 1]) }   // right
                sum += abs(p[row + dx] - p[nextRow + dx])                 // below
            }
        }
        return sum * kSumCoeff + outVal
    }

    // MARK: - Field

    /// Computes per-block `aq_strength` (≥ 0) for the block-padded luma `plane`
    /// (`width = blocksH·8`, `height = blocksV·8`, values in [0,255]).
    /// `yQuant01` is the Y quant table's first AC step (`quantval[1]`).
    static func computeField(
        plane: [Float], width w: Int, height h: Int,
        blocksH: Int, blocksV: Int, yQuant01: Int
    ) -> [Float] {
        let pw = w / 4, ph = h / 4
        var pre = [Float](repeating: 0, count: pw * ph)
        let matchGammaOffset = 0.019 / kInputScaling
        let limit: Float = 0.2

        plane.withUnsafeBufferPointer { buf in
            let p = buf.baseAddress!
            var rowAccum = [Float](repeating: 0, count: w)
            rowAccum.withUnsafeMutableBufferPointer { ra in
                let acc = ra.baseAddress!
                for y in 0..<h {
                    let row = y * w
                    let rowT = max(0, y - 1) * w
                    let rowB = min(h - 1, y + 1) * w
                    for x in 0..<w {
                        let inv = p[row + x]
                        let base = 0.25 * (p[row + max(0, x - 1)] + p[row + min(w - 1, x + 1)]
                                           + p[rowT + x] + p[rowB + x])
                        let g = ratioOfDerivatives(inv + matchGammaOffset, invert: false)
                        var diff = g * (inv - base)
                        diff = diff * diff
                        diff = min(diff, limit)
                        diff = maskingSqrt(diff)
                        acc[x] = (y & 3) == 0 ? diff : acc[x] + diff
                    }
                    if (y & 3) == 3 {
                        let yo = (y / 4) * pw
                        for xo in 0..<pw {
                            let b = xo * 4
                            pre[yo + xo] = 0.25 * (acc[b] + acc[b + 1] + acc[b + 2] + acc[b + 3])
                        }
                    }
                }
            }
        }

        // Fuzzy erosion: weighted sum of the 4 smallest in each 3×3 neighborhood,
        // then 2× box-downsample to block resolution.
        var eroded = [Float](repeating: 0, count: pw * ph)
        var nb = [Float](repeating: 0, count: 9)
        for y in 0..<ph {
            for x in 0..<pw {
                var i = 0
                for dy in -1...1 {
                    let yy = min(max(0, y + dy), ph - 1) * pw
                    for dx in -1...1 {
                        nb[i] = pre[yy + min(max(0, x + dx), pw - 1)]; i += 1
                    }
                }
                nb.sort()
                eroded[y * pw + x] = 0.125 * nb[0] + 0.075 * nb[1] + 0.06 * nb[2] + 0.05 * nb[3]
            }
        }

        // Per-block modulations + the final 0.6/field − 1 strength transform.
        let yq = Float(yQuant01)
        let kAcQuant: Float = 0.841
        let baseLevel = 0.48 * kAcQuant
        var dampen: Float = 1
        if yq >= 9 { dampen = max(0, 1 - (yq - 9) / (65 - 9)) }
        let mul = kAcQuant * dampen
        let add = (1 - dampen) * baseLevel

        var field = [Float](repeating: 0, count: blocksH * blocksV)
        plane.withUnsafeBufferPointer { buf in
            let p = buf.baseAddress!
            for yb in 0..<blocksV {
                for xb in 0..<blocksH {
                    var v = eroded[(yb * 2) * pw + xb * 2] + eroded[(yb * 2) * pw + xb * 2 + 1]
                          + eroded[(yb * 2 + 1) * pw + xb * 2] + eroded[(yb * 2 + 1) * pw + xb * 2 + 1]
                    v = computeMask(v)
                    v = hfModulation(p, x: xb * 8, y: yb * 8, width: w, height: h, v)
                    v = gammaModulation(p, x: xb * 8, y: yb * 8, width: w, v)
                    let qf = exp(v) * mul + add
                    field[yb * blocksH + xb] = max(0, 0.6 / qf - 1.0)
                }
            }
        }
        return field
    }
}
