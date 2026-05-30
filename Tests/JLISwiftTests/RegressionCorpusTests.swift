// SPDX-License-Identifier: Apache-2.0
// Copyright 2024 Raster Lab. All rights reserved.

import Testing
import Foundation
import CryptoKit
@testable import JLIDICOM
@testable import JLISwift

/// Frozen medical regression corpus (WS-M1).
///
/// A content-addressed test matrix spanning the dimensions that matter for
/// diagnostic data — modality, bit depth, signedness, photometric
/// interpretation, and transfer syntax (native + encapsulated). We cannot ship
/// PHI, so each case is generated **deterministically** from a seed; the source
/// pixels are then frozen by a SHA-256 in `Case.sourceSHA256`. Every run:
///
///   1. regenerates the source and asserts its SHA-256 matches the frozen value
///      (a **drift guard** — if the generator changes, the corpus is no longer
///      the thing the acceptance criteria were qualified against, and CI fails);
///   2. runs the case through the pipeline and enforces its acceptance criterion.
///
/// Acceptance criteria:
///   • `.losslessBitExact`     — encode lossless, decode, pixels must be identical.
///   • `.nearLosslessBound(Pt)`— max per-pixel error ≤ 2^Pt − 1.
///   • `.encapsulatedBitExact` — wrap lossless JPEG in DICOM, read back, decode,
///                                pixels identical.
///   • `.dicomReadsBack`       — native DICOM write→read preserves geometry + bytes.
///   • `.rejected`             — the pipeline must throw (e.g. signed on lossy).
///
/// To (re)generate the frozen hashes after an intentional corpus change, run the
/// `corpusManifest` test and copy the printed `MANIFEST` lines into the cases.
@Suite("Frozen regression corpus (medical dimensions)")
struct RegressionCorpusTests {

    enum Acceptance: Sendable {
        case losslessBitExact
        case nearLosslessBound(pt: Int)
        case encapsulatedBitExact
        case dicomReadsBack
        case rejected
    }

    struct Case: Sendable {
        let id: String
        let rows: Int, cols: Int
        let bitsStored: Int           // 8, 12, or 16
        let signed: Bool
        let photometric: String       // MONOCHROME1/2, RGB
        let samplesPerPixel: Int
        let acceptance: Acceptance
        let sourceSHA256: String      // frozen hash of the generated source bytes
    }

    /// Deterministic generator: pixel bytes for a case, keyed by its id so each
    /// case has stable, distinct content. 16-bit samples are little-endian.
    static func sourceBytes(_ c: Case) -> [UInt8] {
        var seed: UInt64 = 0xC0FFEE
        for b in c.id.utf8 { seed = (seed &* 1099511628211) ^ UInt64(b) }   // FNV-ish
        var state = seed
        func nextU16() -> UInt16 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return UInt16((state >> 33) & 0xFFFF)
        }
        let px = c.rows * c.cols
        let bytesPerSample = c.bitsStored <= 8 ? 1 : 2
        let mask = c.bitsStored >= 16 ? 0xFFFF : ((1 << c.bitsStored) - 1)
        var out = [UInt8]()
        out.reserveCapacity(px * c.samplesPerPixel * bytesPerSample)
        for i in 0..<(px * c.samplesPerPixel) {
            // Mix a smooth gradient with deterministic noise so both prediction
            // and entropy paths are exercised; keep within the stored bit width.
            // The raw bit pattern is stored verbatim; signedness (if any) is
            // interpreted on read, so a set top bit is a negative value there.
            let grad = (i * 17 + (i / max(1, c.cols)) * 3)
            let v = (grad ^ Int(nextU16())) & mask
            if bytesPerSample == 1 { out.append(UInt8(v & 0xFF)) }
            else { out.append(UInt8(v & 0xFF)); out.append(UInt8((v >> 8) & 0xFF)) }
        }
        return out
    }

    static func sha256(_ bytes: [UInt8]) -> String {
        SHA256.hash(data: Data(bytes)).compactMap { String(format: "%02x", $0) }.joined()
    }

    // The frozen corpus. (Hashes are filled in by the `corpusManifest` generator
    // below, then committed — see the suite doc comment.)
    static let cases: [Case] = [
        Case(id: "ct-16s",  rows: 24, cols: 24, bitsStored: 16, signed: true,  photometric: "MONOCHROME2", samplesPerPixel: 1, acceptance: .losslessBitExact,      sourceSHA256: "7482f45e83de433f70bd02d2ce655916e954abe14cb36a5bfda0d556f506f7a8"),
        Case(id: "ct-12s",  rows: 20, cols: 28, bitsStored: 12, signed: true,  photometric: "MONOCHROME2", samplesPerPixel: 1, acceptance: .encapsulatedBitExact,   sourceSHA256: "626b6e53eb1a6640a2cfc531833acb71bd2f284b525413ee78198a909c4b3ac6"),
        Case(id: "dx-12u",  rows: 32, cols: 16, bitsStored: 12, signed: false, photometric: "MONOCHROME2", samplesPerPixel: 1, acceptance: .losslessBitExact,      sourceSHA256: "7f5539f600d2a379ca23bd7c1264f7f12b70e02f1586fcea3eb350b25dd3f05a"),
        Case(id: "mg-12u",  rows: 30, cols: 30, bitsStored: 12, signed: false, photometric: "MONOCHROME1", samplesPerPixel: 1, acceptance: .dicomReadsBack,        sourceSHA256: "d79034edda9ee322a049208d83e59f5329819fca0dfca011d2bc0bbf2e9f0410"),
        Case(id: "mr-12u",  rows: 16, cols: 16, bitsStored: 12, signed: false, photometric: "MONOCHROME2", samplesPerPixel: 1, acceptance: .nearLosslessBound(pt: 2), sourceSHA256: "2c3008857891a6267c4e5e13dc3122842db1ef6d2330ef48d9281ce50cf6f19f"),
        Case(id: "us-8rgb", rows: 12, cols: 16, bitsStored: 8,  signed: false, photometric: "RGB",         samplesPerPixel: 3, acceptance: .encapsulatedBitExact,   sourceSHA256: "f4d4898e38ce5e29bc31028d8b54ad69b745bf1c2cfe0e04227e3a5d5bc1373d"),
        Case(id: "xa-12u",  rows: 28, cols: 20, bitsStored: 12, signed: false, photometric: "MONOCHROME2", samplesPerPixel: 1, acceptance: .losslessBitExact,      sourceSHA256: "4faaae115d4fd8a72b98aec497af086e46822fbee95508fbe06854cbd661d962"),
        Case(id: "sc-8u",   rows: 8,  cols: 8,  bitsStored: 8,  signed: false, photometric: "MONOCHROME2", samplesPerPixel: 1, acceptance: .dicomReadsBack,        sourceSHA256: "a655c30eee903c9190ac6b7e5450d484cdf0f856ec6651df1b641f368709eebc"),
        Case(id: "ct-16s-lossy-reject", rows: 8, cols: 8, bitsStored: 16, signed: true, photometric: "MONOCHROME2", samplesPerPixel: 1, acceptance: .rejected,      sourceSHA256: "c4706cc3c5df70ed24c4d063ff5152e40644f6df2f4e8a92d30a06bda37d3353"),
    ]

    // MARK: - Pipeline per acceptance criterion

    private func bitsAllocated(_ c: Case) -> Int { c.bitsStored <= 8 ? 8 : 16 }
    private func pixelFormat(_ c: Case) -> JLIPixelFormat { c.bitsStored <= 8 ? .uint8 : .uint16 }
    private func colorModel(_ c: Case) -> JLIColorModel { c.samplesPerPixel == 3 ? .rgb : .grayscale }

    private func makeImage(_ c: Case, _ src: [UInt8]) throws -> JLIImage {
        try JLIImage(width: c.cols, height: c.rows, pixelFormat: pixelFormat(c),
                     colorModel: colorModel(c), data: src, isSigned: c.signed)
    }
    private func losslessConfig(_ c: Case, pt: Int = 0) -> JLIEncoderConfiguration {
        var cfg = JLIEncoderConfiguration(lossless: true)
        cfg.losslessPrecision = c.bitsStored <= 8 ? 8 : c.bitsStored
        cfg.losslessPointTransform = pt
        cfg.chromaSubsampling = .yuv444
        return cfg
    }
    private func module(_ c: Case) -> DICOMWriter.PixelModule {
        DICOMWriter.PixelModule(
            rows: c.rows, columns: c.cols, bitsAllocated: bitsAllocated(c),
            bitsStored: c.bitsStored, highBit: c.bitsStored - 1,
            pixelRepresentation: c.signed ? 1 : 0,
            samplesPerPixel: c.samplesPerPixel,
            photometricInterpretation: c.photometric)
    }

    @Test("Every frozen case matches its hash and meets its acceptance criterion")
    func runCorpus() throws {
        for c in Self.cases {
            let src = Self.sourceBytes(c)
            // 1) Drift guard — fail loudly if the generator no longer produces the
            //    frozen bytes the acceptance criteria were qualified against.
            #expect(Self.sha256(src) == c.sourceSHA256,
                    "corpus drift: case \(c.id) hash changed — regenerate the manifest if intentional")

            // 2) Acceptance.
            switch c.acceptance {
            case .losslessBitExact:
                let img = try makeImage(c, src)
                let dec = try JLIDecoder().decode(from: JLIEncoder().encode(img, configuration: losslessConfig(c)))
                #expect(dec.data == src, "\(c.id): lossless not bit-exact")

            case .nearLosslessBound(let pt):
                let img = try makeImage(c, src)
                let dec = try JLIDecoder().decode(from: JLIEncoder().encode(img, configuration: losslessConfig(c, pt: pt)))
                let bound = (1 << pt) - 1
                var maxErr = 0
                let step = c.bitsStored <= 8 ? 1 : 2
                var i = 0
                while i < src.count {
                    let a = step == 1 ? Int(src[i]) : Int(UInt16(src[i]) | (UInt16(src[i+1]) << 8))
                    let b = step == 1 ? Int(dec.data[i]) : Int(UInt16(dec.data[i]) | (UInt16(dec.data[i+1]) << 8))
                    maxErr = max(maxErr, abs(a - b)); i += step
                }
                #expect(maxErr <= bound, "\(c.id): near-lossless err \(maxErr) > \(bound)")

            case .encapsulatedBitExact:
                let img = try makeImage(c, src)
                let jpeg = try JLIEncoder().encode(img, configuration: losslessConfig(c))
                let file = try DICOMWriter.writeEncapsulatedJPEG(
                    jpegStream: jpeg, module: module(c), transferSyntax: DICOMWriter.jpegLosslessSV1)
                let dicom = try DICOMReader.read(file)
                #expect(dicom.isEncapsulated)
                let dec = try JLIDecoder().decode(from: dicom.pixelData)
                #expect(dec.data == src, "\(c.id): encapsulated round-trip not bit-exact")

            case .dicomReadsBack:
                let file = try DICOMWriter.write(pixelData: src, module: module(c))
                let dicom = try DICOMReader.read(file)
                #expect(dicom.width == c.cols && dicom.height == c.rows)
                #expect(dicom.pixelData == src, "\(c.id): native DICOM bytes not preserved")
                #expect(dicom.photometric == c.photometric)

            case .rejected:
                let img = try makeImage(c, src)
                var threw = false
                do { _ = try JLIEncoder().encode(img, configuration: .default) } catch { threw = true }
                #expect(threw, "\(c.id): expected the pipeline to reject this case")
            }
        }
    }

    /// Prints the manifest (id → sha256 → acceptance) so a green CI run records
    /// the frozen corpus, and so the hashes can be (re)generated after an
    /// intentional change. Always passes; it is a reporting/regeneration aid.
    @Test("Corpus manifest (record + regeneration aid)")
    func corpusManifest() {
        print("MANIFEST corpus=frozen-medical cases=\(Self.cases.count)")
        for c in Self.cases {
            let src = Self.sourceBytes(c)
            print("MANIFEST \(c.id) \(c.rows)x\(c.cols) bits=\(c.bitsStored) signed=\(c.signed) "
                + "photo=\(c.photometric) spp=\(c.samplesPerPixel) accept=\(c.acceptance) "
                + "sha256=\(Self.sha256(src))")
        }
    }
}
