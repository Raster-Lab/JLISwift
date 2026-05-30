// SPDX-License-Identifier: Apache-2.0
// Copyright 2024 Raster Lab. All rights reserved.

import Testing
import Foundation
@testable import JLIDICOM
@testable import JLISwift

/// Malformed-input fuzzing of the DICOM reader. The medical-grade audit flagged
/// that the JPEG decoder had a real fuzz harness but the DICOM parser had none —
/// yet the DICOM file is the untrusted front door for clinical data. Every probe
/// calls `DICOMReader.read` under `try?`, so a *trap* (force-unwrap nil, out-of-
/// bounds, integer overflow, precondition, OOM) is uncatchable and crashes the
/// test process; a clean `throw` is swallowed. A green run is therefore evidence
/// that the reader fails safe (throws, never traps) over the explored space.
@Suite("DICOM reader robustness / malformed input")
struct DICOMFuzzTests {

    /// Deterministic SplitMix64 — reproducible corpora across runs.
    struct RNG {
        var state: UInt64
        init(_ seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func byte() -> UInt8 { UInt8(next() & 0xFF) }
        mutating func int(_ n: Int) -> Int { n <= 0 ? 0 : Int(next() % UInt64(n)) }
    }

    /// A valid native (uncompressed) DICOM seed: 8×8 16-bit MONOCHROME2.
    static func validNative() throws -> [UInt8] {
        var px = [UInt8]()
        for i in 0..<64 { let v = UInt16(i * 60); px.append(UInt8(v & 0xFF)); px.append(UInt8(v >> 8)) }
        let module = DICOMWriter.PixelModule(
            rows: 8, columns: 8, bitsAllocated: 16, bitsStored: 12, highBit: 11,
            rescaleSlope: 1, rescaleIntercept: -1024, windowCenter: 40, windowWidth: 400,
            modality: "CT")
        return try DICOMWriter.write(pixelData: px, module: module)
    }

    /// A valid *encapsulated* JPEG-lossless DICOM seed.
    static func validEncapsulated() throws -> [UInt8] {
        var px = [UInt8]()
        for i in 0..<64 { let v = UInt16((i * 37) & 0x0FFF); px.append(UInt8(v & 0xFF)); px.append(UInt8(v >> 8)) }
        let img = try JLIImage(width: 8, height: 8, pixelFormat: .uint16, colorModel: .grayscale, data: px)
        var cfg = JLIEncoderConfiguration(lossless: true); cfg.losslessPrecision = 12
        let jpeg = try JLIEncoder().encode(img, configuration: cfg)
        let module = DICOMWriter.PixelModule(
            rows: 8, columns: 8, bitsAllocated: 16, bitsStored: 12, highBit: 11)
        return try DICOMWriter.writeEncapsulatedJPEG(
            jpegStream: jpeg, module: module, transferSyntax: DICOMWriter.jpegLosslessSV1)
    }

    /// The probe: read must never trap. We deliberately ignore success/failure —
    /// only a crash fails the test.
    private func probe(_ data: [UInt8]) {
        _ = try? DICOMReader.read(data)
    }

    @Test("Truncation at every prefix length never traps (native + encapsulated)")
    func truncations() throws {
        for seed in [try Self.validNative(), try Self.validEncapsulated()] {
            // Dense near the header (where length/VR parsing lives), sparse in the body.
            var len = 0
            while len <= seed.count {
                probe(Array(seed[0..<len]))
                len += len < 300 ? 1 : 64
            }
            probe(seed)
        }
    }

    @Test("Single-byte mutations never trap")
    func singleByteMutations() throws {
        let seed = try Self.validNative()
        var rng = RNG(0xD1C0_0001)
        // Walk every position once with a flipped value; a few random values each
        // near the structurally-sensitive header region (first 256 bytes).
        for pos in 0..<seed.count {
            var m = seed
            m[pos] = m[pos] ^ 0xFF
            probe(m)
            if pos < 256 {
                for _ in 0..<2 { var m2 = seed; m2[pos] = rng.byte(); probe(m2) }
            }
        }
    }

    @Test("Corrupted element length fields never trap")
    func lengthFieldFuzz() throws {
        let seed = try Self.validNative()
        var rng = RNG(0xD1C0_0002)
        // Scan for plausible explicit-VR length fields (a VR is two uppercase
        // ASCII letters) and overwrite the following length with hostile values.
        let hostile: [UInt32] = [0xFFFFFFFF, 0xFFFFFFFE, 0x7FFFFFFF, 0x80000000, 0, 1, 0xFFFF]
        var i = 132
        while i + 8 <= seed.count {
            let v0 = seed[i + 4], v1 = seed[i + 5]
            let looksVR = (65...90).contains(v0) && (65...90).contains(v1)
            if looksVR {
                for h in hostile {
                    var m = seed
                    // Short-form 16-bit length at +6, and long-form 32-bit at +8.
                    m[i + 6] = UInt8(h & 0xFF); m[i + 7] = UInt8((h >> 8) & 0xFF)
                    probe(m)
                    if i + 12 <= m.count {
                        m[i + 8] = UInt8(h & 0xFF); m[i + 9] = UInt8((h >> 8) & 0xFF)
                        m[i + 10] = UInt8((h >> 16) & 0xFF); m[i + 11] = UInt8((h >> 24) & 0xFF)
                        probe(m)
                    }
                }
            }
            i += 1 + rng.int(3)   // stride irregularly to cover odd alignments cheaply
        }
    }

    @Test("Hostile geometry headers never trap (bomb / zero / overflow)")
    func hostileGeometry() throws {
        // Build datasets that declare extreme Rows/Columns/BitsAllocated against a
        // tiny PixelData — the decompression-bomb + truncation surface.
        let geometries: [(rows: UInt16, cols: UInt16, bits: UInt16, spp: UInt16)] = [
            (0xFFFF, 0xFFFF, 16, 1),   // ~4.29e9 samples → must throw imageTooLarge
            (0xFFFF, 0xFFFF, 16, 3),   // ×3
            (0, 0, 16, 1), (1, 0, 16, 1), (0xFFFF, 1, 16, 1),
            (8, 8, 0, 1), (8, 8, 99, 1), (8, 8, 16, 0), (8, 8, 16, 99),
            (0x8000, 0x8000, 16, 1),
        ]
        for g in geometries {
            var b = TinyBuilder()
            b.us(0x0028, 0x0002, g.spp)
            b.str(0x0028, 0x0004, "CS", "MONOCHROME2")
            b.us(0x0028, 0x0010, g.rows)
            b.us(0x0028, 0x0011, g.cols)
            b.us(0x0028, 0x0100, g.bits)
            b.us(0x0028, 0x0101, g.bits == 0 ? 0 : min(g.bits, 16))
            b.us(0x0028, 0x0103, 0)
            b.ow(0x7FE0, 0x0010, [0, 1, 2, 3])   // only 8 bytes — far short of the claim
            probe(b.bytes())
        }
    }

    @Test("Random bytes and random-behind-DICM never trap")
    func randomBytes() {
        var rng = RNG(0xD1C0_0003)
        for _ in 0..<3000 {
            let n = 16 + rng.int(4096)
            var d = [UInt8](repeating: 0, count: n)
            for i in 0..<n { d[i] = rng.byte() }
            probe(d)
        }
        // Random payloads behind a valid preamble + DICM magic (past the front gate).
        for _ in 0..<3000 {
            var d = [UInt8](repeating: 0, count: 132)
            d[128] = 0x44; d[129] = 0x49; d[130] = 0x43; d[131] = 0x4D
            let n = rng.int(2048)
            for _ in 0..<n { d.append(rng.byte()) }
            probe(d)
        }
    }

    @Test("Corrupted encapsulated fragment framing never traps")
    func encapsulatedFragmentFuzz() throws {
        let seed = try Self.validEncapsulated()
        var rng = RNG(0xD1C0_0004)
        // Truncate within the encapsulated PixelData region and mutate item tags /
        // fragment lengths — the FFFE,E000 / E0DD framing the reader walks.
        for _ in 0..<2000 {
            var m = seed
            let pos = 128 + rng.int(max(1, m.count - 128))
            m[pos] = rng.byte()
            probe(m)
        }
        // Hostile fragment lengths: find FFFE,E000 items and overwrite their length.
        var i = 132
        while i + 8 <= seed.count {
            if seed[i] == 0xFE && seed[i + 1] == 0xFF && seed[i + 2] == 0x00 && seed[i + 3] == 0xE0 {
                for h in [UInt32(0xFFFFFFFF), 0x7FFFFFFF, 0xFFFFFFF0, 0] {
                    var m = seed
                    m[i + 4] = UInt8(h & 0xFF); m[i + 5] = UInt8((h >> 8) & 0xFF)
                    m[i + 6] = UInt8((h >> 16) & 0xFF); m[i + 7] = UInt8((h >> 24) & 0xFF)
                    probe(m)
                }
            }
            i += 1
        }
    }

    @Test("Deeply nested / unterminated sequences never trap")
    func sequenceFuzz() throws {
        // An undefined-length SQ whose delimiter is missing, and nested SQs, must
        // terminate at EOF rather than loop or over-read.
        var b = TinyBuilder()
        // Open an undefined-length SQ and never close it; bury pixel-module tags.
        b.openUndefinedSQ(0x0008, 0x1140)
        b.openUndefinedSQ(0x0008, 0x1115)        // nested, also unterminated
        b.us(0x0028, 0x0010, 8); b.us(0x0028, 0x0011, 8)
        probe(b.bytes())

        // A well-formed nested SQ followed by a real pixel module — must parse past.
        var b2 = TinyBuilder()
        var inner = TinyBuilder(); inner.us(0x0028, 0x0010, 999)
        b2.undefinedSQ(0x0008, 0x1140, inner: inner.bytesRaw())
        b2.us(0x0028, 0x0002, 1); b2.str(0x0028, 0x0004, "CS", "MONOCHROME2")
        b2.us(0x0028, 0x0010, 8); b2.us(0x0028, 0x0011, 8)
        b2.us(0x0028, 0x0100, 16); b2.us(0x0028, 0x0101, 12); b2.us(0x0028, 0x0103, 0)
        var px = [UInt16](); for i in 0..<64 { px.append(UInt16(i)) }
        b2.ow(0x7FE0, 0x0010, px)
        probe(b2.bytes())
    }
}

/// Minimal Explicit-VR-LE dataset builder for the fuzz seeds (separate from the
/// reader-test builder so the two suites stay independent).
private struct TinyBuilder {
    var elements: [UInt8] = []

    mutating func us(_ g: UInt16, _ e: UInt16, _ v: UInt16) {
        short(g, e, "US", [UInt8(v & 0xFF), UInt8(v >> 8)])
    }
    mutating func str(_ g: UInt16, _ e: UInt16, _ vr: String, _ s: String) {
        var v = Array(s.utf8); if v.count % 2 != 0 { v.append(0x20) }
        short(g, e, vr, v)
    }
    mutating func ow(_ g: UInt16, _ e: UInt16, _ samples: [UInt16]) {
        var v = [UInt8](); for s in samples { v.append(UInt8(s & 0xFF)); v.append(UInt8(s >> 8)) }
        a16(g); a16(e); elements += Array("OW".utf8); a16(0); a32(UInt32(v.count)); elements += v
    }
    mutating func openUndefinedSQ(_ g: UInt16, _ e: UInt16) {
        a16(g); a16(e); elements += Array("SQ".utf8); a16(0); a32(0xFFFFFFFF)
        a16(0xFFFE); a16(0xE000); a32(0xFFFFFFFF)        // an item, also undefined, unterminated
    }
    mutating func undefinedSQ(_ g: UInt16, _ e: UInt16, inner: [UInt8]) {
        a16(g); a16(e); elements += Array("SQ".utf8); a16(0); a32(0xFFFFFFFF)
        a16(0xFFFE); a16(0xE000); a32(0xFFFFFFFF); elements += inner
        a16(0xFFFE); a16(0xE00D); a32(0)
        a16(0xFFFE); a16(0xE0DD); a32(0)
    }
    private mutating func short(_ g: UInt16, _ e: UInt16, _ vr: String, _ v: [UInt8]) {
        a16(g); a16(e); elements += Array(vr.utf8); a16(UInt16(v.count)); elements += v
    }
    private mutating func a16(_ v: UInt16) { elements.append(UInt8(v & 0xFF)); elements.append(UInt8(v >> 8)) }
    private mutating func a32(_ v: UInt32) {
        elements.append(UInt8(v & 0xFF)); elements.append(UInt8((v >> 8) & 0xFF))
        elements.append(UInt8((v >> 16) & 0xFF)); elements.append(UInt8((v >> 24) & 0xFF))
    }
    func bytesRaw() -> [UInt8] { elements }
    func bytes() -> [UInt8] {
        var out = [UInt8](repeating: 0, count: 128) + Array("DICM".utf8)
        var meta = TinyBuilder()
        meta.str(0x0002, 0x0010, "UI", "1.2.840.10008.1.2.1\0")
        out += meta.elements
        out += elements
        return out
    }
}
