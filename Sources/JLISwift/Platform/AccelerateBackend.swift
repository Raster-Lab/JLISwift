// SPDX-License-Identifier: Apache-2.0
// Copyright 2024 Raster Lab. All rights reserved.

/// Accelerate framework-backed DSP operations for the JPEG pipeline.
///
/// JLISwift only targets Apple platforms, so Accelerate is always available —
/// callers can depend on this enum without a `canImport` guard.

import Accelerate

enum AccelerateDSP {

    // MARK: - DCT

    /// Precomputed 8×8 normalized DCT-II matrix.
    ///
    /// `C[u][n] = α(u) · cos(π·(2n+1)·u / 16)` with `α(0) = 1/√8`, `α(u>0) = √(2/8) = 1/2`.
    /// (Earlier revisions used half-scale α and produced quarter-magnitude coefficients
    /// — quantization then nuked everything.)
    static let dctMatrix: [Float] = {
        var matrix = [Float](repeating: 0, count: 64)
        for u in 0..<8 {
            let alpha: Float = u == 0 ? 1.0 / sqrt(8.0) : sqrt(2.0 / 8.0)
            for n in 0..<8 {
                matrix[u * 8 + n] = alpha * cos(Float(2 * n + 1) * Float(u) * .pi / 16.0)
            }
        }
        return matrix
    }()

    /// Transposed DCT matrix.
    static let dctMatrixTransposed: [Float] = {
        var transposed = [Float](repeating: 0, count: 64)
        for i in 0..<8 {
            for j in 0..<8 {
                transposed[j * 8 + i] = dctMatrix[i * 8 + j]
            }
        }
        return transposed
    }()

    /// Forward 2D DCT-II on an 8×8 block via `vDSP_mmul`. `F = C · f · Cᵀ`.
    ///
    /// Convenience wrapper that allocates output. Hot paths should use
    /// ``forwardDCT(_:into:scratch:)`` to reuse buffers across blocks.
    static func forwardDCT(_ block: [Float]) -> [Float] {
        var output = [Float](repeating: 0, count: 64)
        var scratch = [Float](repeating: 0, count: 64)
        forwardDCT(block, into: &output, scratch: &scratch)
        return output
    }

    /// Inverse 2D DCT-II on an 8×8 block via `vDSP_mmul`. `f = Cᵀ · F · C`.
    static func inverseDCT(_ block: [Float]) -> [Float] {
        var output = [Float](repeating: 0, count: 64)
        var scratch = [Float](repeating: 0, count: 64)
        inverseDCT(block, into: &output, scratch: &scratch)
        return output
    }

    /// Forward DCT into a caller-supplied output buffer; pass a reusable 64-element
    /// `scratch` buffer to eliminate per-block allocation in tight encoding loops.
    static func forwardDCT(
        _ block: [Float], into output: inout [Float], scratch: inout [Float]
    ) {
        precondition(block.count == 64 && output.count == 64 && scratch.count == 64)
        vDSP_mmul(dctMatrix, 1, block, 1, &scratch, 1, 8, 8, 8)
        vDSP_mmul(scratch, 1, dctMatrixTransposed, 1, &output, 1, 8, 8, 8)
    }

    /// Inverse DCT into a caller-supplied output buffer.
    static func inverseDCT(
        _ block: [Float], into output: inout [Float], scratch: inout [Float]
    ) {
        precondition(block.count == 64 && output.count == 64 && scratch.count == 64)
        vDSP_mmul(dctMatrixTransposed, 1, block, 1, &scratch, 1, 8, 8, 8)
        vDSP_mmul(scratch, 1, dctMatrix, 1, &output, 1, 8, 8, 8)
    }

    // MARK: - Batched DCT
    //
    // For a 512×512 4:4:4 encode, the per-block DCT path issues ~12k `vDSP_mmul`
    // calls. Each call's dispatch overhead is in the hundreds of nanoseconds — for
    // an 8×8 matmul that's only ~1k FLOPs, the overhead dominates the actual work
    // by an order of magnitude. The batched routines below collapse all of those
    // calls into two large mmuls, with one O(N×64) rearrangement in between.
    //
    // Layout: every batch buffer is sized `blockCount * 64`, with block `i` at
    // offset `64*i` and stored row-major within (matches what the encoder extracts
    // from image planes and what dequantize naturally produces in the decoder).

    /// Forward DCT-II on `n` contiguous 8×8 blocks: `F_i = C · f_i · Cᵀ` for each i.
    ///
    /// `input` and `output` are both at least `n * 64` long; only the first `n * 64`
    /// elements are read/written. `output` may NOT alias `input`. `scratch` is also
    /// caller-supplied and may be oversized (so a single allocation can serve
    /// multiple consecutive batches of different sizes).
    static func forwardDCTBatch(
        _ input: [Float], into output: inout [Float], scratch: inout [Float],
        blockCount n: Int
    ) {
        precondition(input.count >= n * 64 && output.count >= n * 64 && scratch.count >= n * 64)
        guard n > 0 else { return }
        let eightN = vDSP_Length(8 * n)

        // Pack input (per-block-contig) into M-layout (8 × 8N row-major) where
        // block i occupies columns [8i, 8i+8). After packing,
        //   M[r * 8N + 8i + c] == input[64i + 8r + c].
        // We use the scratch buffer as M.
        input.withUnsafeBufferPointer { inBuf in
            scratch.withUnsafeMutableBufferPointer { mBuf in
                let src = inBuf.baseAddress!
                let dst = mBuf.baseAddress!
                let rowStride = 8 * n
                for i in 0..<n {
                    for r in 0..<8 {
                        // 8 contiguous floats per row of one block.
                        memcpy(
                            dst + r * rowStride + 8 * i,
                            src + 64 * i + 8 * r,
                            8 * MemoryLayout<Float>.size
                        )
                    }
                }
            }
        }

        // Pass 1: T = C · M, both shaped (8 × 8N). Write into `output` to free
        // scratch for the next rearrangement.
        vDSP_mmul(dctMatrix, 1, scratch, 1, &output, 1, 8, eightN, 8)

        // Rearrange T (8 × 8N col-block-major) → V (8N × 8 per-block-contig)
        // for the second-pass right-multiply. After rearranging,
        //   V[64i + 8r + c] == T[r * 8N + 8i + c].
        output.withUnsafeBufferPointer { tBuf in
            scratch.withUnsafeMutableBufferPointer { vBuf in
                let src = tBuf.baseAddress!
                let dst = vBuf.baseAddress!
                let rowStride = 8 * n
                for i in 0..<n {
                    for r in 0..<8 {
                        memcpy(
                            dst + 64 * i + 8 * r,
                            src + r * rowStride + 8 * i,
                            8 * MemoryLayout<Float>.size
                        )
                    }
                }
            }
        }

        // Pass 2: F = V · Cᵀ, both shaped (8N × 8). Output is per-block-contig.
        vDSP_mmul(scratch, 1, dctMatrixTransposed, 1, &output, 1, eightN, 8, 8)
    }

    /// Inverse DCT-II on `n` contiguous 8×8 blocks: `f_i = Cᵀ · F_i · C` for each i.
    /// Same layout/aliasing rules as ``forwardDCTBatch(_:into:scratch:blockCount:)``.
    static func inverseDCTBatch(
        _ input: [Float], into output: inout [Float], scratch: inout [Float],
        blockCount n: Int
    ) {
        precondition(input.count >= n * 64 && output.count >= n * 64 && scratch.count >= n * 64)
        guard n > 0 else { return }
        let eightN = vDSP_Length(8 * n)

        // Pack input → M (8 × 8N col-block layout).
        input.withUnsafeBufferPointer { inBuf in
            scratch.withUnsafeMutableBufferPointer { mBuf in
                let src = inBuf.baseAddress!
                let dst = mBuf.baseAddress!
                let rowStride = 8 * n
                for i in 0..<n {
                    for r in 0..<8 {
                        memcpy(
                            dst + r * rowStride + 8 * i,
                            src + 64 * i + 8 * r,
                            8 * MemoryLayout<Float>.size
                        )
                    }
                }
            }
        }

        // Pass 1: T = Cᵀ · M, both shaped (8 × 8N).
        vDSP_mmul(dctMatrixTransposed, 1, scratch, 1, &output, 1, 8, eightN, 8)

        // Rearrange T → V (8N × 8 per-block-contig).
        output.withUnsafeBufferPointer { tBuf in
            scratch.withUnsafeMutableBufferPointer { vBuf in
                let src = tBuf.baseAddress!
                let dst = vBuf.baseAddress!
                let rowStride = 8 * n
                for i in 0..<n {
                    for r in 0..<8 {
                        memcpy(
                            dst + 64 * i + 8 * r,
                            src + r * rowStride + 8 * i,
                            8 * MemoryLayout<Float>.size
                        )
                    }
                }
            }
        }

        // Pass 2: f = V · C, both shaped (8N × 8). Output per-block-contig.
        vDSP_mmul(scratch, 1, dctMatrix, 1, &output, 1, eightN, 8, 8)
    }

    // MARK: - Image-level color conversion (BT.601)

    /// Converts interleaved RGB(A) bytes to planar Y/Cb/Cr Float planes via vDSP.
    ///
    /// `componentCount` is 3 for tight-packed RGB or 4 for RGBA (alpha is ignored).
    /// All three output planes are sized `pixelCount` elements. This replaces a per-pixel
    /// Swift loop with stride-aware `vDSP_vfltu8` deinterleaves plus three fused
    /// multiply-add chains — typically 4–8× faster on large images.
    static func imageRGBToYCbCr(
        data: [UInt8], pixelCount: Int, componentCount: Int
    ) -> (y: [Float], cb: [Float], cr: [Float]) {
        precondition(componentCount == 3 || componentCount == 4)
        precondition(data.count >= pixelCount * componentCount)

        var r = [Float](repeating: 0, count: pixelCount)
        var g = [Float](repeating: 0, count: pixelCount)
        var b = [Float](repeating: 0, count: pixelCount)
        let n = vDSP_Length(pixelCount)
        let stride = vDSP_Stride(componentCount)

        data.withUnsafeBufferPointer { buf in
            let base = buf.baseAddress!
            vDSP_vfltu8(base + 0, stride, &r, 1, n)
            vDSP_vfltu8(base + 1, stride, &g, 1, n)
            vDSP_vfltu8(base + 2, stride, &b, 1, n)
        }

        var y = [Float](repeating: 0, count: pixelCount)
        var cb = [Float](repeating: 0, count: pixelCount)
        var cr = [Float](repeating: 0, count: pixelCount)

        // Y = 0.299 R + 0.587 G + 0.114 B
        var yR: Float = 0.299, yG: Float = 0.587, yB: Float = 0.114
        vDSP_vsmul(r, 1, &yR, &y, 1, n)
        vDSP_vsma(g, 1, &yG, y, 1, &y, 1, n)
        vDSP_vsma(b, 1, &yB, y, 1, &y, 1, n)

        // Cb = -0.168736 R - 0.331264 G + 0.5 B + 128
        var cbR: Float = -0.168736, cbG: Float = -0.331264, cbB: Float = 0.5
        var center: Float = 128.0
        vDSP_vsmul(r, 1, &cbR, &cb, 1, n)
        vDSP_vsma(g, 1, &cbG, cb, 1, &cb, 1, n)
        vDSP_vsma(b, 1, &cbB, cb, 1, &cb, 1, n)
        vDSP_vsadd(cb, 1, &center, &cb, 1, n)

        // Cr = 0.5 R - 0.418688 G - 0.081312 B + 128
        var crR: Float = 0.5, crG: Float = -0.418688, crB: Float = -0.081312
        vDSP_vsmul(r, 1, &crR, &cr, 1, n)
        vDSP_vsma(g, 1, &crG, cr, 1, &cr, 1, n)
        vDSP_vsma(b, 1, &crB, cr, 1, &cr, 1, n)
        vDSP_vsadd(cr, 1, &center, &cr, 1, n)

        return (y, cb, cr)
    }

    /// Converts planar Y/Cb/Cr Float planes back to interleaved RGB bytes via vDSP.
    static func imageYCbCrToRGB(
        y: [Float], cb: [Float], cr: [Float], pixelCount: Int
    ) -> [UInt8] {
        precondition(y.count == pixelCount && cb.count == pixelCount && cr.count == pixelCount)
        let n = vDSP_Length(pixelCount)

        // Shift chroma by -128 once; reuse for all three output channels.
        var cbS = [Float](repeating: 0, count: pixelCount)
        var crS = [Float](repeating: 0, count: pixelCount)
        var neg128: Float = -128.0
        vDSP_vsadd(cb, 1, &neg128, &cbS, 1, n)
        vDSP_vsadd(cr, 1, &neg128, &crS, 1, n)

        // R = Y + 1.402 Cr',  G = Y - 0.344136 Cb' - 0.714136 Cr',  B = Y + 1.772 Cb'
        var r = [Float](repeating: 0, count: pixelCount)
        var g = [Float](repeating: 0, count: pixelCount)
        var b = [Float](repeating: 0, count: pixelCount)
        var rCr: Float = 1.402
        var gCb: Float = -0.344136, gCr: Float = -0.714136
        var bCb: Float = 1.772

        vDSP_vsma(crS, 1, &rCr, y, 1, &r, 1, n)

        vDSP_vsmul(cbS, 1, &gCb, &g, 1, n)
        vDSP_vsma(crS, 1, &gCr, g, 1, &g, 1, n)
        vDSP_vadd(y, 1, g, 1, &g, 1, n)

        vDSP_vsma(cbS, 1, &bCb, y, 1, &b, 1, n)

        var lo: Float = 0.0
        var hi: Float = 255.0
        vDSP_vclip(r, 1, &lo, &hi, &r, 1, n)
        vDSP_vclip(g, 1, &lo, &hi, &g, 1, n)
        vDSP_vclip(b, 1, &lo, &hi, &b, 1, n)

        var rgb = [UInt8](repeating: 0, count: pixelCount * 3)
        let stride = vDSP_Stride(3)
        rgb.withUnsafeMutableBufferPointer { buf in
            let base = buf.baseAddress!
            // vDSP_vfixru8 rounds to nearest (ties to even), matching the scalar
            // `Int(value.rounded())` semantics used by the previous implementation.
            vDSP_vfixru8(r, 1, base + 0, stride, n)
            vDSP_vfixru8(g, 1, base + 1, stride, n)
            vDSP_vfixru8(b, 1, base + 2, stride, n)
        }
        return rgb
    }

    // MARK: - Batched quantization

    /// Quantize `n` contiguous 8×8 blocks against a single 64-element inverse table.
    ///
    /// `input` and `output` are sized `n * 64`. `invTable[k] = 1.0 / table[k]` —
    /// the encoder precomputes this once. Uses a tight pointer loop with `i & 63`
    /// table indexing; LLVM autovectorizes the multiply/round/convert into NEON.
    /// Avoids per-block dispatch overhead from the prior `vDSP_vmul`/`vDSP_vfix32`
    /// pair (which also allocated two scratch arrays per call).
    static func quantizeBatch(
        _ input: [Float], invTable: [Float],
        into output: inout [Int32], blockCount n: Int
    ) {
        precondition(input.count >= n * 64 && invTable.count == 64 && output.count >= n * 64)
        input.withUnsafeBufferPointer { inBuf in
            invTable.withUnsafeBufferPointer { invBuf in
                output.withUnsafeMutableBufferPointer { outBuf in
                    let inP = inBuf.baseAddress!
                    let invP = invBuf.baseAddress!
                    let outP = outBuf.baseAddress!
                    for i in 0..<(n * 64) {
                        let q = (inP[i] * invP[i & 63]).rounded(.toNearestOrEven)
                        outP[i] = Int32(q)
                    }
                }
            }
        }
    }

    /// Dequantize `n` contiguous 8×8 blocks against a single 64-element table.
    static func dequantizeBatch(
        _ input: [Int32], table: [Float],
        into output: inout [Float], blockCount n: Int
    ) {
        precondition(input.count >= n * 64 && table.count == 64 && output.count >= n * 64)
        input.withUnsafeBufferPointer { inBuf in
            table.withUnsafeBufferPointer { tabBuf in
                output.withUnsafeMutableBufferPointer { outBuf in
                    let inP = inBuf.baseAddress!
                    let tabP = tabBuf.baseAddress!
                    let outP = outBuf.baseAddress!
                    for i in 0..<(n * 64) {
                        outP[i] = Float(inP[i]) * tabP[i & 63]
                    }
                }
            }
        }
    }

    // MARK: - Vectorized quantization / level shift

    /// Subtract 128 from each element (in-place).
    static func levelShiftDown(_ block: inout [Float]) {
        var offset: Float = -128.0
        vDSP_vsadd(block, 1, &offset, &block, 1, 64)
    }

    /// Add 128, clamp to [0, 255], in-place.
    static func levelShiftUpClamped(_ block: inout [Float]) {
        var offset: Float = 128.0
        var lo: Float = 0.0
        var hi: Float = 255.0
        vDSP_vsadd(block, 1, &offset, &block, 1, 64)
        vDSP_vclip(block, 1, &lo, &hi, &block, 1, 64)
    }

    /// Divide block by quantization table (precomputed as reciprocals) and round to int.
    /// Pass `invTable` = `1.0 / table[i]` (computed once per encode).
    static func quantize(
        _ block: [Float], invTable: [Float], into output: inout [Int32]
    ) {
        precondition(block.count == 64 && invTable.count == 64 && output.count == 64)
        var scratch = [Float](repeating: 0, count: 64)
        vDSP_vmul(block, 1, invTable, 1, &scratch, 1, 64)
        var rounded = [Float](repeating: 0, count: 64)
        // vDSP_vrnd rounds to nearest even (the IEEE default), matching jpegli/IJG.
        for i in 0..<64 { rounded[i] = scratch[i].rounded(.toNearestOrEven) }
        vDSP_vfix32(rounded, 1, &output, 1, 64)
    }

    /// Multiply quantized coefficients by quantization table → float DCT coefficients.
    static func dequantize(
        _ quantized: [Int32], table: [Float], into output: inout [Float]
    ) {
        precondition(quantized.count == 64 && table.count == 64 && output.count == 64)
        var asFloat = [Float](repeating: 0, count: 64)
        vDSP_vflt32(quantized, 1, &asFloat, 1, 64)
        vDSP_vmul(asFloat, 1, table, 1, &output, 1, 64)
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
