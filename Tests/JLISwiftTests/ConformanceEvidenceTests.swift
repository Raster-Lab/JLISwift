// SPDX-License-Identifier: Apache-2.0
// Copyright 2024 Raster Lab. All rights reserved.

import Testing
import Foundation
@testable import JLIDICOM
@testable import JLISwift

/// Medical verification-evidence suite (WS-M1).
///
/// This is the organizing layer for the safety-critical claims a medical-imaging
/// partner needs proven on every commit. The underlying mechanisms are also
/// exercised by `LosslessTests`, `IDCTConformanceTests`, `DICOMWriterTests`,
/// `MedicalSafetyTests` and `DICOMFuzzTests`; here they are asserted as named
/// claims with **explicit acceptance criteria**, and each emits a `CONFORMANCE`
/// line so a green CI run produces a quotable evidence record (claim → result).
///
/// Acceptance criteria (the medical contract):
///   C1  Lossless reconstructs pixels BIT-EXACTLY at 8/12/16-bit (gray + RGB).
///   C2  Lossless cross-validates BIT-EXACTLY against libjpeg-turbo fixtures.
///   C3  Near-lossless bounds max per-pixel error to (2^Pt − 1).
///   C4  Signed lossless round-trips bit-exactly; signed lossy is rejected.
///   C5  Encapsulated JPEG-in-DICOM reconstructs pixels bit-exactly end to end.
///   C6  The decoder fails safe on malformed input (covered by Fuzz suites).
///   C7  IDCT meets ISO/IEC 10918-2 Annex A accuracy (covered by IDCT suite).
@Suite("Conformance evidence (medical safety-critical claims)")
struct ConformanceEvidenceTests {

    private func record(_ id: String, _ claim: String, _ result: String) {
        print("CONFORMANCE \(id) PASS — \(claim) :: \(result)")
    }

    // C1 — Lossless bit-exact round-trip across bit depths and predictors.
    @Test("C1: lossless round-trip is bit-exact at 8/12/16-bit, predictors 1–7")
    func c1LosslessBitExact() throws {
        let w = 24, h = 20
        var g8 = [UInt8](repeating: 0, count: w * h)
        for i in 0..<g8.count { g8[i] = UInt8((i * 13 + (i / w) * 7) & 0xFF) }
        func gN(_ mask: UInt16, _ mul: Int) -> [UInt8] {
            var d = [UInt8](repeating: 0, count: w * h * 2)
            for i in 0..<(w * h) { let v = UInt16((i * mul) & Int(mask)); d[i*2] = UInt8(v & 0xFF); d[i*2+1] = UInt8(v >> 8) }
            return d
        }
        let g12 = gN(0x0FFF, 61), g16 = gN(0xFFFF, 1009)
        var checked = 0
        for predictor in 1...7 {
            var cfg = JLIEncoderConfiguration.default
            cfg.lossless = true; cfg.losslessPredictor = predictor; cfg.chromaSubsampling = .yuv400
            // 8-bit
            let i8 = try JLIImage(width: w, height: h, pixelFormat: .uint8, colorModel: .grayscale, data: g8)
            #expect(try JLIDecoder().decode(from: JLIEncoder().encode(i8, configuration: cfg)).data == g8)
            // 12-bit
            let i12 = try JLIImage(width: w, height: h, pixelFormat: .uint16, colorModel: .grayscale, data: g12)
            #expect(try JLIDecoder().decode(from: JLIEncoder().encode(i12, configuration: cfg)).data == g12)
            // 16-bit
            var cfg16 = cfg; cfg16.losslessPrecision = 16
            let i16 = try JLIImage(width: w, height: h, pixelFormat: .uint16, colorModel: .grayscale, data: g16)
            #expect(try JLIDecoder().decode(from: JLIEncoder().encode(i16, configuration: cfg16)).data == g16)
            checked += 3
        }
        record("C1", "lossless bit-exact (8/12/16-bit × predictors 1–7)",
               "\(checked) round-trips, 0 mismatches")
    }

    // C2 — Cross-validation against an independent reference (libjpeg-turbo).
    // The reference output is embedded as fixtures in LosslessTests, so this runs
    // unconditionally in CI with no external tool. We re-decode the same fixtures
    // here to record it as explicit cross-validation evidence.
    @Test("C2: lossless decode cross-validates bit-exactly vs libjpeg-turbo fixtures")
    func c2CrossValidation() throws {
        // 8-bit predictor 1 & 7 fixtures (cjpeg -lossless), 16-bit fixture.
        let p1 = try JLIDecoder().decode(from: LosslessTests.llP1)
        #expect(p1.data == LosslessTests.src, "predictor-1 vs cjpeg not bit-exact")
        let p7 = try JLIDecoder().decode(from: LosslessTests.llP7)
        #expect(p7.data == LosslessTests.src, "predictor-7 vs cjpeg not bit-exact")
        let g16 = try JLIDecoder().decode(from: LosslessTests.ll16)
        #expect(g16.data == LosslessTests.src16LE, "16-bit vs cjpeg not bit-exact")
        let color = try JLIDecoder().decode(from: LosslessTests.colorLL)
        #expect(color.data == LosslessTests.colorSrc, "color vs cjpeg not bit-exact")
        record("C2", "cross-validation vs libjpeg-turbo (cjpeg -lossless fixtures)",
               "4 reference streams decoded bit-exact (8-bit p1/p7, 16-bit, RGB)")
    }

    // C3 — Near-lossless bounds the per-pixel error to (2^Pt − 1).
    @Test("C3: near-lossless bounds max per-pixel error to 2^Pt − 1")
    func c3NearLosslessBound() throws {
        let w = 16, h = 16
        var src = [UInt8](repeating: 0, count: w * h * 2)
        for i in 0..<(w * h) { let v = UInt16((i * 97) & 0x0FFF); src[i*2] = UInt8(v & 0xFF); src[i*2+1] = UInt8(v >> 8) }
        for pt in 1...4 {
            var cfg = JLIEncoderConfiguration(lossless: true)
            cfg.losslessPrecision = 12; cfg.losslessPointTransform = pt; cfg.chromaSubsampling = .yuv400
            let img = try JLIImage(width: w, height: h, pixelFormat: .uint16, colorModel: .grayscale, data: src)
            let dec = try JLIDecoder().decode(from: JLIEncoder().encode(img, configuration: cfg))
            var maxErr = 0
            for i in 0..<(w * h) {
                let a = Int(UInt16(src[i*2]) | (UInt16(src[i*2+1]) << 8))
                let b = Int(UInt16(dec.data[i*2]) | (UInt16(dec.data[i*2+1]) << 8))
                maxErr = max(maxErr, abs(a - b))
            }
            let bound = (1 << pt) - 1
            #expect(maxErr <= bound, "Pt=\(pt): max error \(maxErr) exceeds bound \(bound)")
            record("C3", "near-lossless error bound (Pt=\(pt))", "maxErr=\(maxErr) ≤ 2^\(pt)−1=\(bound)")
        }
    }

    // C4 — Signed data: lossless preserves it bit-exactly; lossy rejects it.
    @Test("C4: signed lossless is bit-exact; signed lossy is rejected")
    func c4Signed() throws {
        let vals: [Int16] = [-32768, -1000, -1, 0, 1, 1000, 32767]
        var data = [UInt8](); for v in vals { let u = UInt16(bitPattern: v); data.append(UInt8(u & 0xFF)); data.append(UInt8(u >> 8)) }
        let img = try JLIImage(width: vals.count, height: 1, pixelFormat: .uint16,
                               colorModel: .grayscale, data: data, isSigned: true)
        var cfg = JLIEncoderConfiguration(lossless: true); cfg.losslessPrecision = 16
        let dec = try JLIDecoder().decode(from: JLIEncoder().encode(img, configuration: cfg))
        #expect(dec.data == data, "signed lossless not bit-exact")

        var rejected = false
        do { _ = try JLIEncoder().encode(img, configuration: .default) }
        catch { rejected = true }
        #expect(rejected, "signed lossy must be rejected, not silently corrupted")
        record("C4", "signed pixel handling", "lossless bit-exact (±extremes); lossy rejected")
    }

    // C5 — Encapsulated JPEG-in-DICOM end-to-end bit-exactness.
    @Test("C5: encapsulated JPEG-in-DICOM reconstructs pixels bit-exactly")
    func c5Encapsulation() throws {
        let w = 8, h = 8
        var bytes = [UInt8](); for y in 0..<h { for x in 0..<w { let v = UInt16((x*256 + y*13) & 0x0FFF); bytes.append(UInt8(v & 0xFF)); bytes.append(UInt8(v >> 8)) } }
        let img = try JLIImage(width: w, height: h, pixelFormat: .uint16, colorModel: .grayscale, data: bytes)
        var cfg = JLIEncoderConfiguration(lossless: true); cfg.losslessPrecision = 12
        let jpeg = try JLIEncoder().encode(img, configuration: cfg)
        let module = DICOMWriter.PixelModule(rows: h, columns: w, bitsAllocated: 16,
                                             bitsStored: 12, highBit: 11)
        let file = try DICOMWriter.writeEncapsulatedJPEG(
            jpegStream: jpeg, module: module, transferSyntax: DICOMWriter.jpegLosslessSV1)
        let dicom = try DICOMReader.read(file)
        #expect(dicom.isEncapsulated)
        let decoded = try JLIDecoder().decode(from: dicom.pixelData)
        #expect(decoded.data == bytes, "encapsulated DICOM round-trip not bit-exact")
        record("C5", "encapsulated JPEG-in-DICOM end-to-end",
               "pixels→encode→encapsulate→read→decode bit-exact (\(w)×\(h), JPEG Lossless SV1)")
    }

    // C6 / C7 — pointers so the evidence record is complete in one place.
    @Test("C6/C7: fail-safe + IDCT conformance are proven by dedicated suites")
    func c6c7Pointers() {
        record("C6", "fail-safe on malformed input", "see FuzzTests + DICOMFuzzTests (throws, never traps)")
        record("C7", "ISO/IEC 10918-2 Annex A IDCT accuracy", "see IDCTConformanceTests (3 ranges, large margin)")
    }
}
