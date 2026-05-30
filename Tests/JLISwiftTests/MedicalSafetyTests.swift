// SPDX-License-Identifier: Apache-2.0
// Copyright 2024 Raster Lab. All rights reserved.

import Testing
@testable import JLISwift

/// Provenance / lossy-vs-lossless safety surface added for diagnostic use.
/// These pin the contract that callers and UIs rely on to avoid presenting
/// lossy output as diagnostic-lossless.
struct MedicalSafetyTests {

    @Test func defaultConfigurationIsLossy() {
        // The default encode path is perceptual/lossy — it must report so, so a
        // caller never mistakes it for diagnostic-lossless.
        #expect(JLIEncoderConfiguration.default.isNumericallyLossless == false)
        #expect(JLIEncoderConfiguration.default.isLossy == true)
    }

    @Test func diagnosticLosslessIsNumericallyLossless() {
        let cfg = JLIEncoderConfiguration.diagnosticLossless
        #expect(cfg.isNumericallyLossless == true)
        #expect(cfg.isLossy == false)
        // The preset must actually disable every lossy path.
        #expect(cfg.lossless == true)
        #expect(cfg.losslessPointTransform == 0)
        #expect(cfg.perceptualQuantTables == false)
        #expect(cfg.adaptiveQuantization == false)
        #expect(cfg.adaptiveQuantField == false)
        #expect(cfg.chromaSubsampling == .yuv444)
    }

    @Test func nearLosslessIsReportedLossy() {
        // Lossless flag but a non-zero point transform = bounded-error (lossy).
        var cfg = JLIEncoderConfiguration(lossless: true)
        cfg.losslessPointTransform = 2
        #expect(cfg.isNumericallyLossless == false)
        #expect(cfg.isLossy == true)
    }

    @Test func plainLosslessConfigurationIsLossless() {
        let cfg = JLIEncoderConfiguration(lossless: true)
        #expect(cfg.isNumericallyLossless == true)
        #expect(cfg.isLossy == false)
    }

    // MARK: - Signed pixel data (DICOM PixelRepresentation == 1)

    /// Packs signed 16-bit samples as little-endian two's-complement bytes.
    private func signedLE(_ vals: [Int16]) -> [UInt8] {
        var d = [UInt8]()
        for v in vals { let u = UInt16(bitPattern: v); d.append(UInt8(u & 0xFF)); d.append(UInt8(u >> 8)) }
        return d
    }

    @Test("Signed 16-bit data round-trips bit-exactly through the lossless path")
    func signedLosslessRoundTrip() throws {
        let vals: [Int16] = [-32768, -1000, -1, 0, 1, 1000, 32767]
        let data = signedLE(vals)
        let img = try JLIImage(width: vals.count, height: 1, pixelFormat: .uint16,
                               colorModel: .grayscale, data: data, isSigned: true)
        #expect(img.isSigned == true)
        var cfg = JLIEncoderConfiguration(lossless: true)
        cfg.losslessPrecision = 16
        let jpeg = try JLIEncoder().encode(img, configuration: cfg)
        let dec = try JLIDecoder().decode(from: jpeg)
        // Lossless preserves the exact sample bytes regardless of sign.
        #expect(dec.data == data)
        for i in 0..<vals.count {
            let u = UInt16(dec.data[i*2]) | (UInt16(dec.data[i*2+1]) << 8)
            #expect(Int16(bitPattern: u) == vals[i])
        }
    }

    @Test("Signed data on the lossy DCT path is rejected, not silently corrupted")
    func signedLossyIsRejected() throws {
        let vals: [Int16] = [-2048, -500, 0, 500, 2047]
        let img = try JLIImage(width: vals.count, height: 1, pixelFormat: .uint16,
                               colorModel: .grayscale, data: signedLE(vals), isSigned: true)
        // Default (lossy) configuration must throw rather than emit garbage.
        #expect(throws: JLIError.self) {
            _ = try JLIEncoder().encode(img, configuration: .default)
        }
    }

    @Test("isSigned defaults to false and unsigned lossy encoding is unaffected")
    func unsignedDefaultStillEncodes() throws {
        let data = [UInt8](repeating: 128, count: 4 * 4)   // 4×4 gray, mid-level
        let img = try JLIImage(width: 4, height: 4, pixelFormat: .uint8,
                               colorModel: .grayscale, data: data)
        #expect(img.isSigned == false)
        let jpeg = try JLIEncoder().encode(img, configuration: .default)
        #expect(jpeg.isEmpty == false)
    }
}
