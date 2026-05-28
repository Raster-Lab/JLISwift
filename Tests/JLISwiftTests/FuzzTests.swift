// SPDX-License-Identifier: Apache-2.0
// Copyright 2024 Raster Lab. All rights reserved.

import Testing
@testable import JLISwift

/// Robustness: JLISwift decodes JPEGs embedded in untrusted clinical DICOM
/// files, so malformed / truncated / adversarial bytes must fail by *throwing*
/// (a `JLIError`), never by trapping (force-unwrap nil, out-of-bounds, integer
/// overflow, `fatalError`). A trap aborts the test process, so any of these
/// cases surfacing one shows up as a hard failure here.
///
/// The fuzzers use a seeded PRNG so a discovered crash reproduces deterministically.
@Suite("Decoder robustness / malformed input")
struct FuzzTests {

    /// Deterministic SplitMix64 — reproducible fuzz corpora across runs.
    struct SeededRNG: RandomNumberGenerator {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
    }

    /// A real, valid baseline JPEG to mutate from.
    static func validJPEG(progressive: Bool = false) throws -> [UInt8] {
        let w = 32, h = 24
        var rgb = [UInt8](repeating: 0, count: w * h * 3)
        for i in 0..<rgb.count { rgb[i] = UInt8((i &* 7) & 0xFF) }
        let img = try JLIImage(width: w, height: h, pixelFormat: .uint8, colorModel: .rgb, data: rgb)
        var cfg = JLIEncoderConfiguration.default
        cfg.chromaSubsampling = .yuv420
        cfg.progressive = progressive
        return try JLIEncoder().encode(img, configuration: cfg)
    }

    /// A valid grayscale JPEG: 8-bit (SOF0) or 12-bit (SOF1, 16-bit DQT, uint16
    /// output buffer) — the clinical-precision path that DICOM actually uses.
    static func validGrayJPEG(bits: Int) throws -> [UInt8] {
        let w = 32, h = 24
        let img: JLIImage
        if bits == 8 {
            var gray = [UInt8](repeating: 0, count: w * h)
            for i in 0..<gray.count { gray[i] = UInt8((i &* 7) & 0xFF) }
            img = try JLIImage(width: w, height: h, pixelFormat: .uint8, colorModel: .grayscale, data: gray)
        } else {
            var bytes = [UInt8](repeating: 0, count: w * h * 2)  // little-endian uint16
            for i in 0..<(w * h) {
                let v = UInt16((i &* 17) & 0x0FFF)               // 12-bit samples 0–4095
                bytes[i * 2] = UInt8(v & 0xFF); bytes[i * 2 + 1] = UInt8(v >> 8)
            }
            img = try JLIImage(width: w, height: h, pixelFormat: .uint16, colorModel: .grayscale, data: bytes)
        }
        var cfg = JLIEncoderConfiguration.default
        cfg.chromaSubsampling = .yuv400
        return try JLIEncoder().encode(img, configuration: cfg)
    }

    /// A valid JPEG carrying a multi-segment ICC profile (>65519 → 2 APP2
    /// segments) and an Exif (APP1) block — exercises the metadata parser, which
    /// reads attacker-controlled segment lengths, sequence numbers, and counts.
    static func validJPEGWithMetadata() throws -> [UInt8] {
        let w = 24, h = 16
        let rgb = (0..<(w * h * 3)).map { UInt8(($0 &* 7) & 0xFF) }
        let icc = (0..<100_000).map { UInt8(($0 &* 251 &+ 13) & 0xFF) }   // 2 segments
        let exif = (0..<200).map { UInt8($0 & 0xFF) }
        let img = try JLIImage(width: w, height: h, pixelFormat: .uint8, colorModel: .rgb,
                               data: rgb, iccProfile: icc, exif: exif)
        return try JLIEncoder().encode(img, configuration: .default)
    }

    /// Feed bytes to both entry points; thrown errors are fine, a trap is not.
    private func probe(_ data: [UInt8]) {
        _ = try? JLIDecoder().inspect(data: data)
        _ = try? JLIDecoder().decode(from: data)
    }

    /// Decode at every supported reduced scale — the box-average (2/4) and DC-only
    /// (8) paths must also throw, never trap, on malformed input.
    private func probeScaled(_ data: [UInt8]) {
        for s in [2, 4, 8] {
            var cfg = JLIDecoderConfiguration.default; cfg.scale = s
            _ = try? JLIDecoder().decode(from: data, configuration: cfg)
        }
    }

    @Test("Truncation at every prefix length never crashes")
    func truncations() throws {
        let corpus = [
            try Self.validJPEG(),
            try Self.validJPEG(progressive: true),
            try Self.validGrayJPEG(bits: 8),
            try Self.validGrayJPEG(bits: 12),
        ]
        for valid in corpus {
            for len in 0...valid.count {
                probe(Array(valid[0..<len]))
            }
        }
    }

    @Test("Single-byte mutations never crash (baseline + progressive)")
    func singleByteMutations() throws {
        for valid in [try Self.validJPEG(), try Self.validJPEG(progressive: true)] {
            for pos in 0..<valid.count {
                for v: UInt8 in [0x00, 0xFF, 0xD8, 0xD9, 0xC0, 0xC2, 0x01, 0x80] {
                    var m = valid
                    m[pos] = v
                    probe(m)
                }
            }
        }
    }

    @Test("Single-byte mutations never crash (8-bit + 12-bit grayscale)")
    func grayscaleMutations() throws {
        for valid in [try Self.validGrayJPEG(bits: 8), try Self.validGrayJPEG(bits: 12)] {
            for pos in 0..<valid.count {
                for v: UInt8 in [0x00, 0xFF, 0xC0, 0xC1, 0xC2, 0x80] {
                    var m = valid
                    m[pos] = v
                    probe(m)
                }
            }
        }
    }

    @Test("Random byte arrays never crash")
    func randomBytes() {
        var rng = SeededRNG(seed: 0xCAFEBABE)
        for _ in 0..<3000 {
            let n = Int.random(in: 0...4096, using: &rng)
            var d = [UInt8](repeating: 0, count: n)
            for i in 0..<n { d[i] = UInt8.random(in: 0...255, using: &rng) }
            probe(d)
        }
    }

    @Test("Random payloads behind a valid SOI never crash")
    func randomWithSOI() {
        var rng = SeededRNG(seed: 0x1234_5678_9ABC_DEF0)
        for _ in 0..<3000 {
            let n = Int.random(in: 0...4096, using: &rng)
            var d: [UInt8] = [0xFF, 0xD8]   // SOI — get past the magic-number gate
            for _ in 0..<n { d.append(UInt8.random(in: 0...255, using: &rng)) }
            probe(d)
        }
    }

    @Test("Corrupted marker length fields never crash")
    func markerLengthFuzz() throws {
        let valid = try Self.validJPEG()
        for pos in 2..<(valid.count - 4) where valid[pos] == 0xFF {
            let m1 = valid[pos + 1]
            guard m1 != 0x00, m1 != 0xFF else { continue }
            for (hi, lo): (UInt8, UInt8) in [(0xFF, 0xFF), (0x00, 0x00), (0x00, 0x01), (0xFF, 0xFE)] {
                var m = valid
                m[pos + 2] = hi
                m[pos + 3] = lo
                probe(m)
            }
        }
    }

    @Test("Malformed ICC/Exif metadata segments never crash")
    func metadataMutations() throws {
        let valid = try Self.validJPEGWithMetadata()
        // Truncation through the (large) ICC segments stresses readSegmentBytes
        // bounds and the chunk reassembler; sample lengths to keep it bounded.
        for len in stride(from: 0, through: valid.count, by: 7) {
            probe(Array(valid[0..<len]))
        }
        // Mutate only the marker/length/seq/count region near each APP segment
        // header — the attacker-controlled fields — to dodge megabytes of work.
        var i = 0
        while i + 1 < min(valid.count, 4096) {
            if valid[i] == 0xFF, valid[i + 1] == 0xE1 || valid[i + 1] == 0xE2 {
                for off in 0..<min(20, valid.count - i) {
                    for v: UInt8 in [0x00, 0xFF, 0x01, 0x80] {
                        var m = valid; m[i + off] = v
                        probe(m)
                    }
                }
            }
            i += 1
        }
    }

    @Test("Scaled decode (1/2, 1/4, 1/8) never crashes on malformed input")
    func scaledDecodeFuzz() throws {
        let corpus = [try Self.validJPEG(), try Self.validGrayJPEG(bits: 8),
                      try Self.validGrayJPEG(bits: 12)]
        for valid in corpus {
            for len in stride(from: 0, through: valid.count, by: 3) {
                probeScaled(Array(valid[0..<len]))
            }
            var rng = SeededRNG(seed: 0xF00D_5CA1_ED00_1234)
            for pos in stride(from: 0, to: valid.count, by: 5) {
                var m = valid; m[pos] = UInt8.random(in: 0...255, using: &rng)
                probeScaled(m)
            }
        }
    }
}

/// Encoder edge cases. `JLIImage.init` already rejects bad dimensions / buffer
/// sizes, so the encoder always gets a consistent image — the risk is edge-case
/// *valid* inputs: tiny and odd dimensions stress MCU padding and chroma
/// subsampling (progressive's non-interleaved grid had off-by-one bugs on
/// non-MCU-multiple sizes). Every combination must encode without trapping and
/// round-trip to the original dimensions.
@Suite("Encoder robustness / edge cases")
struct EncoderEdgeTests {
    /// Tiny, sub-block, odd, and non-MCU-multiple dimensions.
    static let dims: [(Int, Int)] = [
        (1, 1), (1, 8), (8, 1), (7, 7), (8, 8), (9, 9), (16, 16),
        (17, 3), (3, 17), (13, 31), (1, 64), (64, 1), (32, 24),
    ]

    static let modes: [(progressive: Bool, mode: JLIProgressiveMode)] = [
        (false, .spectralSelection),
        (true, .spectralSelection),
        (true, .successiveApproximation),
    ]

    @Test("RGB encode across dimensions × subsampling × progressive modes round-trips")
    func rgbSweep() throws {
        let subs: [JLIChromaSubsampling] = [.yuv444, .yuv422, .yuv420]
        for (w, h) in Self.dims {
            var rgb = [UInt8](repeating: 0, count: w * h * 3)
            for i in 0..<rgb.count { rgb[i] = UInt8((i &* 31) & 0xFF) }
            let img = try JLIImage(width: w, height: h, pixelFormat: .uint8, colorModel: .rgb, data: rgb)
            for sub in subs {
                for m in Self.modes {
                    for q in [1, 50, 100] {
                        var cfg = JLIEncoderConfiguration.default
                        cfg.quality = Double(q)
                        cfg.chromaSubsampling = sub
                        cfg.progressive = m.progressive
                        cfg.progressiveMode = m.mode
                        let jpeg = try JLIEncoder().encode(img, configuration: cfg)
                        let dec = try JLIDecoder().decode(from: jpeg)
                        #expect(dec.width == w && dec.height == h,
                                "RGB \(w)×\(h) sub=\(sub) prog=\(m.progressive)/\(m.mode) q=\(q)")
                    }
                }
            }
        }
    }

    @Test("Grayscale 8/12-bit encode across dimensions round-trips")
    func graySweep() throws {
        for bits in [8, 12] {
            for (w, h) in Self.dims {
                let img: JLIImage
                if bits == 8 {
                    var g = [UInt8](repeating: 0, count: w * h)
                    for i in 0..<g.count { g[i] = UInt8((i &* 31) & 0xFF) }
                    img = try JLIImage(width: w, height: h, pixelFormat: .uint8, colorModel: .grayscale, data: g)
                } else {
                    var b = [UInt8](repeating: 0, count: w * h * 2)
                    for i in 0..<(w * h) {
                        let v = UInt16((i &* 53) & 0x0FFF)
                        b[i * 2] = UInt8(v & 0xFF); b[i * 2 + 1] = UInt8(v >> 8)
                    }
                    img = try JLIImage(width: w, height: h, pixelFormat: .uint16, colorModel: .grayscale, data: b)
                }
                for m in Self.modes {
                    for q in [1, 50, 100] {
                        var cfg = JLIEncoderConfiguration.default
                        cfg.quality = Double(q)
                        cfg.chromaSubsampling = .yuv400
                        cfg.progressive = m.progressive
                        cfg.progressiveMode = m.mode
                        let jpeg = try JLIEncoder().encode(img, configuration: cfg)
                        let dec = try JLIDecoder().decode(from: jpeg)
                        #expect(dec.width == w && dec.height == h,
                                "gray\(bits) \(w)×\(h) prog=\(m.progressive)/\(m.mode) q=\(q)")
                    }
                }
            }
        }
    }
}
