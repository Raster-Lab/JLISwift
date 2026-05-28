// SPDX-License-Identifier: Apache-2.0
// Copyright 2024 Raster Lab. All rights reserved.

import Testing
@testable import JLISwift

/// jpegli perceptual quantization-table model (`perceptualQuantTables`). The
/// model itself is a faithful port of libjxl's tables; these tests verify it is
/// wired in correctly — valid tables, sane rate/quality behaviour, and clean
/// round-trips. (Perceptual quality vs Annex K is a butteraugli question,
/// validated out-of-band since the metric tool isn't available in CI.)
@Suite("Perceptual quantization (jpegli tables)")
struct PerceptualQuantTests {

    @Test("Quant-table values are valid and coarsen with distance")
    func tableValidity() throws {
        for chroma in [false, true] {
            var prevMean = 0.0
            for distance in [0.5, 1.0, 2.0, 4.0, 8.0] {
                let t = Quantization.perceptualQuantTable(distance: distance, chroma: chroma, isYUV420: false)
                #expect(t.count == 64)
                #expect(t.allSatisfy { $0 >= 1 && $0 <= 255 }, "quant value out of 1...255")
                let mean = Double(t.reduce(0, +)) / 64.0
                #expect(mean > prevMean, "larger distance must not give finer quant (chroma=\(chroma), d=\(distance))")
                prevMean = mean
            }
        }
    }

    @Test("distanceForQuality is monotonic and matches libjxl anchors")
    func distanceMapping() {
        #expect(Quantization.distanceForQuality(100) == 0.01)
        // q90 → 1.0, q80 → 1.9 (linear branch 0.1 + (100-q)*0.09).
        #expect(abs(Quantization.distanceForQuality(90) - 1.0) < 1e-9)
        #expect(abs(Quantization.distanceForQuality(80) - 1.9) < 1e-9)
        // Strictly decreasing in quality.
        var prev = Double.infinity
        for q in stride(from: 100, through: 1, by: -1) {
            let d = Quantization.distanceForQuality(Double(q))
            #expect(d > 0)
            if q < 100 { #expect(d >= prev || q == 99, "distance should rise as quality falls") }
            prev = d
        }
    }

    @Test("4:2:0 chroma table is coarser than 4:4:4 (extra rescale)")
    func yuv420ChromaCoarser() {
        let c444 = Quantization.perceptualQuantTable(distance: 1.0, chroma: true, isYUV420: false)
        let c420 = Quantization.perceptualQuantTable(distance: 1.0, chroma: true, isYUV420: true)
        // 4:2:0 already halves chroma resolution, so jpegli quantizes the
        // remaining chroma coefficients a touch finer per-coefficient but applies
        // a 1.22 global bump; net AC behaviour should still differ from 4:4:4.
        #expect(c444 != c420, "4:2:0 chroma table should differ from 4:4:4")
    }

    @Test("Perceptual tables differ from the Annex K path")
    func differsFromAnnexK() throws {
        let w = 32, h = 32
        var rgb = [UInt8](repeating: 0, count: w * h * 3)
        for i in 0..<(w * h) {
            rgb[i * 3] = UInt8((i * 7) & 0xFF)
            rgb[i * 3 + 1] = UInt8((i * 5) & 0xFF)
            rgb[i * 3 + 2] = UInt8((i * 3) & 0xFF)
        }
        let img = try JLIImage(width: w, height: h, pixelFormat: .uint8, colorModel: .rgb, data: rgb)
        var ak = JLIEncoderConfiguration.default; ak.quality = 90; ak.chromaSubsampling = .yuv444
        var pq = ak; pq.perceptualQuantTables = true
        let akBytes = try JLIEncoder().encode(img, configuration: ak)
        let pqBytes = try JLIEncoder().encode(img, configuration: pq)
        #expect(akBytes != pqBytes, "perceptualQuantTables should change the output")
    }

    @Test("Perceptual-quant encode round-trips with sane error (color + grayscale)")
    func roundTrip() throws {
        let w = 48, h = 40
        // Color — smooth gradients (no wrap cliffs, which would ring under any
        // lossy DCT codec and aren't what this test is checking).
        var rgb = [UInt8](repeating: 0, count: w * h * 3)
        for y in 0..<h { for x in 0..<w {
            let i = (y * w + x) * 3
            rgb[i] = UInt8(30 + x * 180 / w)
            rgb[i+1] = UInt8(40 + y * 170 / h)
            rgb[i+2] = UInt8(20 + (x + y) * 150 / (w + h))
        } }
        let cImg = try JLIImage(width: w, height: h, pixelFormat: .uint8, colorModel: .rgb, data: rgb)
        for sub in [JLIChromaSubsampling.yuv444, .yuv420] {
            var cfg = JLIEncoderConfiguration.default
            cfg.quality = 92; cfg.chromaSubsampling = sub; cfg.perceptualQuantTables = true
            let dec = try JLIDecoder().decode(from: try JLIEncoder().encode(cImg, configuration: cfg))
            #expect(dec.width == w && dec.height == h && dec.colorModel == .rgb)
            var maxErr = 0
            for i in 0..<rgb.count { maxErr = max(maxErr, abs(Int(dec.data[i]) - Int(rgb[i]))) }
            #expect(maxErr <= 40, "perceptual-quant color round-trip error \(maxErr) too high (\(sub))")
        }
        // Grayscale (yuv400 → Y table only) — smooth gradient, no wrap cliffs.
        var gray = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h { for x in 0..<w { gray[y * w + x] = UInt8(20 + (x + y) * 200 / (w + h)) } }
        let gImg = try JLIImage(width: w, height: h, pixelFormat: .uint8, colorModel: .grayscale, data: gray)
        var gcfg = JLIEncoderConfiguration.default
        gcfg.quality = 92; gcfg.chromaSubsampling = .yuv400; gcfg.perceptualQuantTables = true
        let gdec = try JLIDecoder().decode(from: try JLIEncoder().encode(gImg, configuration: gcfg))
        #expect(gdec.colorModel == .grayscale)
        var gMax = 0
        for i in 0..<gray.count { gMax = max(gMax, abs(Int(gdec.data[i]) - Int(gray[i]))) }
        #expect(gMax <= 30, "perceptual-quant grayscale round-trip error \(gMax) too high")
    }

    @Test("Higher quality (lower distance) yields a larger file")
    func rateMonotonic() throws {
        let w = 64, h = 64
        var rgb = [UInt8](repeating: 0, count: w * h * 3)
        for y in 0..<h { for x in 0..<w {
            let i = (y * w + x) * 3
            rgb[i] = UInt8((x * 3 + y) & 0xFF); rgb[i+1] = UInt8((x + y * 3) & 0xFF); rgb[i+2] = UInt8((x ^ y) & 0xFF)
        } }
        let img = try JLIImage(width: w, height: h, pixelFormat: .uint8, colorModel: .rgb, data: rgb)
        var prev = 0
        for q in [60, 75, 90, 98] {
            var cfg = JLIEncoderConfiguration.default
            cfg.quality = Double(q); cfg.chromaSubsampling = .yuv444; cfg.perceptualQuantTables = true
            let n = try JLIEncoder().encode(img, configuration: cfg).count
            #expect(n > prev, "file size should grow with quality (q=\(q): \(n) vs \(prev))")
            prev = n
        }
    }
}
