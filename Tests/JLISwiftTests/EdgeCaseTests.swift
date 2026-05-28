// SPDX-License-Identifier: Apache-2.0
// Copyright 2024 Raster Lab. All rights reserved.

import Testing
@testable import JLISwift

/// Boundary-condition coverage for features added in this milestone — the cases
/// most likely to harbor off-by-one / reset bugs: ICC APP2 chunk boundaries,
/// 12-bit scaled-decode values, and progressive restart at extreme intervals.
@Suite("Edge cases")
struct EdgeCaseTests {

    // MARK: - ICC APP2 chunking boundaries

    @Test("ICC profile round-trips at exact APP2 segment boundaries")
    func iccChunkBoundaries() throws {
        let w = 8, h = 8
        let gray = [UInt8](repeating: 128, count: w * h)
        // 65519 = one full segment payload; the ±1 / multiples stress the
        // ceil-division chunk count and reassembly seam.
        for n in [65518, 65519, 65520, 131037, 131038, 131039] {
            let icc = (0..<n).map { UInt8(($0 &* 1103515245 &+ 12345) >> 7 & 0xFF) }
            let img = try JLIImage(width: w, height: h, pixelFormat: .uint8,
                                   colorModel: .grayscale, data: gray, iccProfile: icc)
            var cfg = JLIEncoderConfiguration.default; cfg.chromaSubsampling = .yuv400
            let dec = try JLIDecoder().decode(from: try JLIEncoder().encode(img, configuration: cfg))
            #expect(dec.iccProfile?.count == n, "ICC length wrong at n=\(n)")
            #expect(dec.iccProfile == icc, "ICC not bit-exact at boundary n=\(n)")
        }
    }

    // MARK: - 12-bit scaled decode value correctness

    @Test("1/2 & 1/4 scaled decode of 12-bit grayscale equals the box-average")
    func scaled12BitValues() throws {
        let w = 48, h = 32
        var src = [UInt8](repeating: 0, count: w * h * 2)
        for y in 0..<h {
            for x in 0..<w {
                let v = UInt16(200 + (x + y) * 3000 / (w + h))   // smooth, no clipping, 12-bit range
                let i = (y * w + x) * 2
                src[i] = UInt8(v & 0xFF); src[i + 1] = UInt8(v >> 8)
            }
        }
        let img = try JLIImage(width: w, height: h, pixelFormat: .uint16, colorModel: .grayscale, data: src)
        var cfg = JLIEncoderConfiguration.default; cfg.quality = 95; cfg.chromaSubsampling = .yuv400
        let jpeg = try JLIEncoder().encode(img, configuration: cfg)
        let full = try JLIDecoder().decode(from: jpeg)
        func sample(_ d: [UInt8], _ i: Int) -> Int { Int(d[i * 2]) | (Int(d[i * 2 + 1]) << 8) }

        for scale in [2, 4] {
            var sc = JLIDecoderConfiguration.default; sc.scale = scale
            let small = try JLIDecoder().decode(from: jpeg, configuration: sc)
            #expect(small.pixelFormat == .uint16 && small.width == w / scale && small.height == h / scale)
            var maxErr = 0
            for ty in 0..<small.height {
                for tx in 0..<small.width {
                    var sum = 0
                    for dy in 0..<scale { for dx in 0..<scale {
                        sum += sample(full.data, (ty * scale + dy) * w + (tx * scale + dx))
                    } }
                    let avg = (sum + scale * scale / 2) / (scale * scale)
                    maxErr = max(maxErr, abs(sample(small.data, ty * small.width + tx) - avg))
                }
            }
            #expect(maxErr <= 8, "12-bit scale 1/\(scale) vs box-average max err \(maxErr)")
        }
    }

    // MARK: - Progressive restart at extreme intervals

    private func decode(_ jpeg: [UInt8]) throws -> [UInt8] { try JLIDecoder().decode(from: jpeg).data }

    @Test("Progressive restart with interval 1 (every MCU) round-trips identically")
    func progressiveRestartIntervalOne() throws {
        let w = 40, h = 32
        var rgb = [UInt8](repeating: 0, count: w * h * 3)
        for y in 0..<h { for x in 0..<w {
            let i = (y * w + x) * 3
            rgb[i] = UInt8(20 + (x * 4) % 200); rgb[i+1] = UInt8(30 + (y * 6) % 200); rgb[i+2] = UInt8((x + y) % 200)
        } }
        let img = try JLIImage(width: w, height: h, pixelFormat: .uint8, colorModel: .rgb, data: rgb)
        for mode in [JLIProgressiveMode.spectralSelection, .successiveApproximation] {
            var base = JLIEncoderConfiguration.default
            base.progressive = true; base.progressiveMode = mode; base.chromaSubsampling = .yuv444
            var r1 = base; r1.restartInterval = 1            // restart every single MCU/unit
            let pNo = try decode(try JLIEncoder().encode(img, configuration: base))
            let pR1 = try decode(try JLIEncoder().encode(img, configuration: r1))
            #expect(pR1 == pNo, "progressive restart interval=1 changed pixels (mode=\(mode))")
        }
    }

    @Test("Restart interval larger than the image still round-trips (no resets fire)")
    func restartIntervalLargerThanImage() throws {
        let w = 24, h = 24
        var gray = [UInt8](repeating: 0, count: w * h)
        for i in 0..<gray.count { gray[i] = UInt8((i * 7) % 240 + 8) }
        let img = try JLIImage(width: w, height: h, pixelFormat: .uint8, colorModel: .grayscale, data: gray)
        // Baseline and progressive, valid interval far exceeding the MCU count
        // (≤ 65535 so it fits the DRI field) — no restart boundary ever fires.
        for prog in [false, true] {
            var base = JLIEncoderConfiguration.default
            base.chromaSubsampling = .yuv400; base.progressive = prog
            var big = base; big.restartInterval = 5000
            let pNo = try decode(try JLIEncoder().encode(img, configuration: base))
            let pBig = try decode(try JLIEncoder().encode(img, configuration: big))
            #expect(pBig == pNo, "oversized restart interval changed pixels (progressive=\(prog))")
        }
    }

    @Test("Out-of-range restart interval throws cleanly (16-bit DRI field), never traps")
    func restartIntervalOutOfRange() throws {
        let img = try JLIImage(width: 16, height: 16, pixelFormat: .uint8,
                               colorModel: .grayscale, data: [UInt8](repeating: 100, count: 256))
        var cfg = JLIEncoderConfiguration.default
        cfg.chromaSubsampling = .yuv400; cfg.restartInterval = 100_000  // > 65535
        #expect(throws: JLIError.self) {
            _ = try JLIEncoder().encode(img, configuration: cfg)
        }
    }
}
