// SPDX-License-Identifier: Apache-2.0
// Copyright 2024 Raster Lab. All rights reserved.

import Testing
@testable import JLISwift

/// Lossless (SOF3) restart-interval support: decode of restart-bearing streams
/// (cross-validated against libjpeg-turbo fixtures), opt-in DRI encode, and the
/// segment-parallel decode path. Restart intervals are row-aligned only — the
/// same constraint libjpeg-turbo enforces ("must be an integer multiple of the
/// number of MCUs in an MCU row"), which makes every segment independently
/// decodable with scan-start prediction at its first row.
@Suite("Lossless restart intervals (SOF3 + DRI/RST)")
struct LosslessRestartTests {
    static let w = 13, h = 9

    /// `cjpeg -lossless 5 -restart 1` on a deterministic 13×9 8-bit gradient —
    /// one restart marker per sample row. djpeg decodes it back to the exact
    /// source (verified at fixture-generation time).
    static let cjpegRestart8: [UInt8] = [
        0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46, 0x00, 0x01,
        0x01, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0xFF, 0xC3, 0x00, 0x0B,
        0x08, 0x00, 0x09, 0x00, 0x0D, 0x01, 0x01, 0x11, 0x00, 0xFF, 0xC4, 0x00,
        0x19, 0x00, 0x01, 0x01, 0x00, 0x03, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x04, 0x03, 0x05, 0x06, 0x07, 0x08,
        0xFF, 0xDD, 0x00, 0x04, 0x00, 0x0D, 0xFF, 0xDA, 0x00, 0x08, 0x01, 0x01,
        0x00, 0x05, 0x00, 0x00, 0xF3, 0xFD, 0xEF, 0x74, 0x5E, 0xE8, 0xBD, 0xD1,
        0x7B, 0xFF, 0x00, 0xFF, 0xD0, 0xE2, 0x48, 0x45, 0xD1, 0x74, 0x5D, 0x17,
        0x45, 0xD1, 0xFF, 0xD1, 0xE4, 0xC8, 0x42, 0x2E, 0x84, 0x22, 0xF5, 0xBA,
        0x11, 0xFF, 0xD2, 0xE7, 0x48, 0x42, 0x10, 0x8A, 0xA2, 0xE8, 0x42, 0x2B,
        0xFF, 0xD3, 0xD3, 0x92, 0x84, 0x22, 0xA8, 0x42, 0x2A, 0x84, 0x23, 0xFF,
        0xD4, 0xC1, 0x25, 0x08, 0xAA, 0x51, 0x54, 0x25, 0x15, 0x47, 0xFF, 0xD5,
        0x32, 0x51, 0x64, 0x26, 0xA8, 0x4D, 0x50, 0x9A, 0xFF, 0x00, 0xFF, 0xD6,
        0x5A, 0x53, 0x54, 0xD5, 0x29, 0xAA, 0x6A, 0x94, 0xFF, 0x00, 0xFF, 0xD7,
        0xCF, 0xA5, 0x36, 0x4D, 0x53, 0x64, 0xD5, 0x36, 0x4F, 0xFF, 0xD9
    ]
    static let expected8: [UInt8] = [
        0, 7, 14, 21, 29, 36, 43, 51, 58, 65, 73, 80, 87,
        19, 27, 35, 42, 50, 57, 65, 72, 80, 87, 95, 102, 110,
        39, 47, 55, 63, 70, 78, 86, 94, 101, 106, 113, 121, 129,
        59, 67, 75, 83, 91, 99, 104, 112, 119, 127, 135, 143, 148,
        79, 88, 96, 104, 112, 117, 125, 133, 141, 146, 154, 162, 170,
        99, 108, 116, 124, 129, 138, 146, 151, 159, 168, 176, 181, 189,
        119, 128, 136, 142, 150, 159, 164, 172, 181, 186, 194, 203, 208,
        139, 148, 157, 162, 171, 176, 185, 194, 199, 208, 213, 222, 231,
        159, 168, 177, 183, 192, 197, 206, 212, 221, 226, 235, 241, 250
    ]

    /// `cjpeg -precision 12 -lossless 6 -restart 1` on a deterministic 13×9
    /// 12-bit gradient (djpeg-verified lossless).
    static let cjpegRestart12: [UInt8] = [
        0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46, 0x00, 0x01,
        0x01, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0xFF, 0xC3, 0x00, 0x0B,
        0x0C, 0x00, 0x09, 0x00, 0x0D, 0x01, 0x01, 0x11, 0x00, 0xFF, 0xC4, 0x00,
        0x19, 0x00, 0x01, 0x01, 0x00, 0x03, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x08, 0x07, 0x09, 0x0A, 0x0B, 0x0C,
        0xFF, 0xDD, 0x00, 0x04, 0x00, 0x0D, 0xFF, 0xDA, 0x00, 0x08, 0x01, 0x01,
        0x00, 0x06, 0x00, 0x00, 0xF3, 0xFF, 0x00, 0xA5, 0xD2, 0xE9, 0x74, 0xC2,
        0x5D, 0x2E, 0x97, 0x4C, 0x25, 0xD2, 0xE9, 0x84, 0xBF, 0xFF, 0xD0, 0xE2,
        0x26, 0x9A, 0x4D, 0xA6, 0x93, 0x49, 0xA4, 0xD2, 0x69, 0x34, 0x9B, 0x4D,
        0x26, 0x93, 0x5F, 0xFF, 0xD1, 0xE4, 0x50, 0x9D, 0x4E, 0xA7, 0x53, 0xA9,
        0xD4, 0xEA, 0x75, 0x3A, 0x9D, 0x4E, 0xA7, 0x6B, 0x7F, 0xFF, 0xD2, 0xE6,
        0x7A, 0xA0, 0x50, 0x28, 0x13, 0xEA, 0x05, 0x02, 0x82, 0xBC, 0xA0, 0x50,
        0x28, 0x13, 0xFF, 0x00, 0xFF, 0xD3, 0xD1, 0x49, 0x46, 0xA2, 0x51, 0xA8,
        0xD4, 0x56, 0x15, 0x1A, 0x8D, 0x46, 0xA2, 0x51, 0xD8, 0x7F, 0xFF, 0xD4,
        0xD5, 0x9D, 0x4A, 0xA6, 0x52, 0xA9, 0xAC, 0x8A, 0x55, 0x32, 0x99, 0x4B,
        0x64, 0x53, 0x29, 0x7F, 0xFF, 0xD5, 0xC3, 0xE2, 0xA1, 0x50, 0xA9, 0xB3,
        0xAA, 0x15, 0x0A, 0x9B, 0x3A, 0xA1, 0x50, 0xA9, 0xB3, 0xFF, 0x00, 0xFF,
        0xD6, 0x88, 0xAA, 0xD5, 0x6A, 0xBB, 0x52, 0xAD, 0x57, 0x6A, 0x55, 0xAB,
        0x2D, 0x2A, 0xB5, 0x67, 0xFF, 0xD7, 0x53, 0x2B, 0xD5, 0xD6, 0xC5, 0x72,
        0xBA, 0xDA, 0xAE, 0x57, 0x5B, 0x15, 0xEA, 0xEB, 0x67, 0xFF, 0xD9
    ]
    static let expected12: [UInt16] = [
        0, 151, 302, 453, 605, 756, 907, 1058, 1210, 1361, 1512, 1664, 1815,
        276, 430, 585, 739, 893, 1047, 1201, 1355, 1509, 1664, 1818, 1972, 2126,
        553, 710, 867, 1024, 1181, 1338, 1495, 1652, 1809, 1966, 2123, 2280, 2371,
        830, 990, 1150, 1310, 1469, 1629, 1789, 1949, 2043, 2203, 2363, 2523, 2682,
        1107, 1270, 1432, 1595, 1758, 1920, 2017, 2180, 2343, 2506, 2668, 2831, 2928,
        1384, 1549, 1715, 1880, 2046, 2146, 2311, 2477, 2643, 2808, 2908, 3074, 3239,
        1661, 1829, 1997, 2166, 2269, 2437, 2605, 2774, 2877, 3045, 3213, 3382, 3485,
        1938, 2109, 2280, 2451, 2557, 2728, 2899, 3005, 3176, 3348, 3453, 3624, 3796,
        2214, 2389, 2563, 2671, 2845, 3019, 3128, 3302, 3476, 3584, 3759, 3933, 4041
    ]

    @Test("cjpeg lossless restart streams decode bit-exactly (8-bit, predictor 5)")
    func decodeCjpegRestart8() throws {
        let img = try JLIDecoder().decode(from: Self.cjpegRestart8)
        #expect(img.width == Self.w && img.height == Self.h)
        #expect(img.data == Self.expected8, "8-bit restart decode not bit-exact")
    }

    @Test("cjpeg lossless restart streams decode bit-exactly (12-bit, predictor 6)")
    func decodeCjpegRestart12() throws {
        let img = try JLIDecoder().decode(from: Self.cjpegRestart12)
        #expect(img.width == Self.w && img.height == Self.h)
        #expect(img.pixelFormat == .uint16)
        var got = [UInt16](repeating: 0, count: Self.w * Self.h)
        for i in 0..<got.count {
            got[i] = UInt16(img.data[i * 2]) | (UInt16(img.data[i * 2 + 1]) << 8)
        }
        #expect(got == Self.expected12, "12-bit restart decode not bit-exact")
    }

    @Test("Opt-in DRI encode round-trips bit-exactly and carries RST markers")
    func encodeRestartRoundTrip() throws {
        let w = 32, h = 21
        var data = [UInt8](repeating: 0, count: w * h * 2)
        var state: UInt32 = 0xACE5
        for i in 0..<(w * h) {
            state = state &* 1664525 &+ 1013904223
            let v = UInt16((i * 17) % 60000) &+ UInt16(state >> 28)
            data[i * 2] = UInt8(v & 0xFF); data[i * 2 + 1] = UInt8(v >> 8)
        }
        let img = try JLIImage(width: w, height: h, pixelFormat: .uint16,
                               colorModel: .grayscale, data: data)
        for rowsPerSegment in [1, 4] {
            var cfg = JLIEncoderConfiguration(lossless: true)
            cfg.losslessPrecision = 16
            cfg.restartInterval = w * rowsPerSegment
            let jpeg = try JLIEncoder().encode(img, configuration: cfg)
            // DRI marker present with the configured interval.
            var sawDRI = false
            for i in 0..<(jpeg.count - 5) where jpeg[i] == 0xFF && jpeg[i + 1] == 0xDD {
                sawDRI = true
                #expect(Int(jpeg[i + 4]) << 8 | Int(jpeg[i + 5]) == w * rowsPerSegment)
            }
            #expect(sawDRI, "DRI marker missing")
            let dec = try JLIDecoder().decode(from: jpeg)
            #expect(dec.data == data, "restart round-trip (\(rowsPerSegment) rows/seg) not bit-exact")
        }

        // Non-row-aligned interval is rejected (libjpeg-turbo's constraint).
        var bad = JLIEncoderConfiguration(lossless: true)
        bad.losslessPrecision = 16
        bad.restartInterval = w + 1
        #expect(throws: JLIError.self) { _ = try JLIEncoder().encode(img, configuration: bad) }
    }

    @Test("Segment-parallel restart decode equals serial, bit-exactly")
    func parallelSegmentDecodeMatchesSerial() throws {
        // 320×280 grayscale 16-bit with restart every 8 rows → 35 segments,
        // 89,600 px ≥ the parallel gate (65,536). 3× determinism + forced-serial
        // equality via the internal gate.
        let w = 320, h = 280
        var data = [UInt8](repeating: 0, count: w * h * 2)
        var state: UInt32 = 0xFEED
        for i in 0..<(w * h) {
            state = state &* 1664525 &+ 1013904223
            let ramp = ((i % w) + (i / w)) * 65535 / (w + h - 2)
            let v = UInt16(clamping: ramp + Int(state >> 26) - 32)
            data[i * 2] = UInt8(v & 0xFF); data[i * 2 + 1] = UInt8(v >> 8)
        }
        let img = try JLIImage(width: w, height: h, pixelFormat: .uint16,
                               colorModel: .grayscale, data: data)
        var cfg = JLIEncoderConfiguration(lossless: true)
        cfg.losslessPrecision = 16
        cfg.restartInterval = w * 8
        let jpeg = try JLIEncoder().encode(img, configuration: cfg)

        let parallel = try JLIDecoder().decode(from: jpeg)
        #expect(parallel.data == data, "restart decode not bit-exact")
        for _ in 0..<2 {
            #expect(try JLIDecoder().decode(from: jpeg).data == parallel.data,
                    "parallel segment decode is not deterministic")
        }

        let saved = JLIDecoder.losslessSegmentParallelMinSamples
        JLIDecoder.losslessSegmentParallelMinSamples = .max
        defer { JLIDecoder.losslessSegmentParallelMinSamples = saved }
        let serial = try JLIDecoder().decode(from: jpeg)
        #expect(serial.data == parallel.data, "parallel segment decode differs from serial")
    }

    @Test("Lossless RGB with restart intervals round-trips bit-exactly (serial path)")
    func rgbRestartRoundTrip() throws {
        let w = 12, h = 10
        var rgb = [UInt8](repeating: 0, count: w * h * 3)
        for i in 0..<rgb.count { rgb[i] = UInt8((i &* 31 &+ 7) & 0xFF) }
        let img = try JLIImage(width: w, height: h, pixelFormat: .uint8,
                               colorModel: .rgb, data: rgb)
        var cfg = JLIEncoderConfiguration(lossless: true)
        cfg.restartInterval = w * 2
        let dec = try JLIDecoder().decode(from: try JLIEncoder().encode(img, configuration: cfg))
        #expect(dec.data == rgb, "RGB restart round-trip not bit-exact")
    }
}
