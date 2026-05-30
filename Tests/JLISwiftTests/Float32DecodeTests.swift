// SPDX-License-Identifier: Apache-2.0
// Copyright 2024 Raster Lab. All rights reserved.

import Testing
@testable import JLISwift

/// Float32 decode output (WS-M4): the decoder can emit reconstructed samples as
/// 32-bit little-endian floats — the **raw** sample values (not normalized), a
/// zero-rounding passthrough of the same float planes the integer path rounds.
/// These tests prove the float output agrees with the integer output sample-for-
/// sample (and is *exact* for 12-bit, which is representable in Float32), and that
/// requesting `.float32` no longer trips the latent `bufferSizeMismatch` bug.
@Suite("Float32 decode output")
struct Float32DecodeTests {

    /// Reads little-endian Float32 samples out of a decoded `.float32` buffer.
    private func floats(_ data: [UInt8]) -> [Float] {
        precondition(data.count % 4 == 0)
        var out = [Float](repeating: 0, count: data.count / 4)
        for i in 0..<out.count {
            let bits = UInt32(data[i*4]) | (UInt32(data[i*4+1]) << 8)
                | (UInt32(data[i*4+2]) << 16) | (UInt32(data[i*4+3]) << 24)
            out[i] = Float(bitPattern: bits)
        }
        return out
    }

    /// Encodes an 8-bit grayscale image (lossy DCT) and returns the JPEG.
    private func gray8JPEG(_ w: Int, _ h: Int) throws -> [UInt8] {
        var d = [UInt8](repeating: 0, count: w * h)
        for i in 0..<d.count { d[i] = UInt8((i * 7 + (i / w) * 11) & 0xFF) }
        let img = try JLIImage(width: w, height: h, pixelFormat: .uint8, colorModel: .grayscale, data: d)
        return try JLIEncoder().encode(img, configuration: .default)
    }

    /// Encodes a 12-bit grayscale image (lossy DCT) and returns the JPEG.
    private func gray12JPEG(_ w: Int, _ h: Int) throws -> [UInt8] {
        var d = [UInt8](repeating: 0, count: w * h * 2)
        for i in 0..<(w * h) { let v = UInt16((i * 31) & 0x0FFF); d[i*2] = UInt8(v & 0xFF); d[i*2+1] = UInt8(v >> 8) }
        let img = try JLIImage(width: w, height: h, pixelFormat: .uint16, colorModel: .grayscale, data: d)
        return try JLIEncoder().encode(img, configuration: .default)
    }

    @Test("Setting .float32 no longer throws (latent bufferSizeMismatch fixed)")
    func float32DoesNotThrow() throws {
        let jpeg = try gray8JPEG(16, 16)
        let cfg = JLIDecoderConfiguration(outputPixelFormat: .float32)
        let img = try JLIDecoder().decode(from: jpeg, configuration: cfg)
        #expect(img.pixelFormat == .float32)
        #expect(img.data.count == 16 * 16 * 4)
    }

    @Test("8-bit grayscale float32 == round to the uint8 output, per sample")
    func gray8MatchesUint() throws {
        let jpeg = try gray8JPEG(24, 18)
        let u = try JLIDecoder().decode(from: jpeg)                                  // default → uint8
        let f = try JLIDecoder().decode(from: jpeg, configuration: .init(outputPixelFormat: .float32))
        let fv = floats(f.data)
        #expect(u.data.count == fv.count)
        for i in 0..<u.data.count {
            #expect(UInt8(clamping: Int(fv[i].rounded())) == u.data[i],
                    "sample \(i): float \(fv[i]) vs uint8 \(u.data[i])")
        }
    }

    @Test("12-bit grayscale float32 rounds to the uint16 value (carries sub-integer precision)")
    func gray12MatchesUint() throws {
        let jpeg = try gray12JPEG(20, 16)
        let u = try JLIDecoder().decode(from: jpeg)                                  // default → uint16
        let f = try JLIDecoder().decode(from: jpeg, configuration: .init(outputPixelFormat: .float32))
        let fv = floats(f.data)
        #expect(u.pixelFormat == .uint16)
        #expect(fv.count == u.data.count / 2)
        var sawFractional = false
        for i in 0..<fv.count {
            let uv = Int(u.data[i*2]) | (Int(u.data[i*2+1]) << 8)
            // float32 is the raw reconstructed sample BEFORE the uint path's rounding,
            // so it rounds (and clamps to the 12-bit range) to the uint16 value.
            let rounded = max(0, min(4095, Int(fv[i].rounded())))
            #expect(rounded == uv, "sample \(i): round(float \(fv[i]))=\(rounded) vs uint16 \(uv)")
            if fv[i] != fv[i].rounded() { sawFractional = true }
        }
        // The lossy DCT reconstruction is generally non-integral — float32 preserves
        // that sub-integer precision the uint path discards (the feature's point).
        #expect(sawFractional, "expected float32 to carry sub-integer precision on lossy data")
    }

    @Test("YCbCr color float32 is rejected with a clear error")
    func colorFloat32Rejected() throws {
        // 8×8 RGB → lossy JPEG (YCbCr internally), then request float32 decode.
        var rgb = [UInt8](repeating: 0, count: 8 * 8 * 3)
        for i in 0..<(8*8) { rgb[i*3] = UInt8(i*3 & 0xFF); rgb[i*3+1] = UInt8(i*5 & 0xFF); rgb[i*3+2] = UInt8(i*7 & 0xFF) }
        let img = try JLIImage(width: 8, height: 8, pixelFormat: .uint8, colorModel: .rgb, data: rgb)
        let jpeg = try JLIEncoder().encode(img, configuration: .default)
        #expect(throws: JLIError.self) {
            _ = try JLIDecoder().decode(from: jpeg, configuration: .init(outputPixelFormat: .float32))
        }
    }

    @Test("Lossless float32 is rejected (use the bit-exact integer output)")
    func losslessFloat32Rejected() throws {
        var d = [UInt8](repeating: 0, count: 12 * 12)
        for i in 0..<d.count { d[i] = UInt8(i & 0xFF) }
        let img = try JLIImage(width: 12, height: 12, pixelFormat: .uint8, colorModel: .grayscale, data: d)
        var enc = JLIEncoderConfiguration(lossless: true); enc.chromaSubsampling = .yuv400
        let jpeg = try JLIEncoder().encode(img, configuration: enc)
        #expect(throws: JLIError.self) {
            _ = try JLIDecoder().decode(from: jpeg, configuration: .init(outputPixelFormat: .float32))
        }
        // And the normal uint path still decodes it bit-exact.
        let u = try JLIDecoder().decode(from: jpeg)
        #expect(u.data == d)
    }
}
