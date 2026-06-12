// SPDX-License-Identifier: Apache-2.0
// Copyright 2024 Raster Lab. All rights reserved.

import Testing
@testable import JLISwift

@Suite("Encoder & Decoder – Full JPEG Pipeline")
struct EncoderDecoderTests {

    // MARK: - Encoder

    @Test("Encoder produces valid JPEG starting with SOI")
    func encoderProducesValidJPEG() throws {
        let image = try JLIImage(
            width: 8, height: 8,
            pixelFormat: .uint8, colorModel: .rgb,
            data: [UInt8](repeating: 128, count: 8 * 8 * 3)
        )

        var config = JLIEncoderConfiguration.default
        config.chromaSubsampling = .yuv444
        let jpegData = try JLIEncoder().encode(image, configuration: config)

        // Starts with SOI marker
        #expect(jpegData[0] == 0xFF)
        #expect(jpegData[1] == 0xD8)
        // Ends with EOI marker
        #expect(jpegData[jpegData.count - 2] == 0xFF)
        #expect(jpegData[jpegData.count - 1] == 0xD9)
    }

    @Test("Encoder handles 1×1 pixel image")
    func encoderHandles1x1() throws {
        let image = try JLIImage(
            width: 1, height: 1,
            pixelFormat: .uint8, colorModel: .rgb,
            data: [255, 0, 0]
        )
        var config = JLIEncoderConfiguration.default
        config.chromaSubsampling = .yuv444
        let jpegData = try JLIEncoder().encode(image, configuration: config)
        #expect(jpegData.count > 4)
        #expect(jpegData[0] == 0xFF)
        #expect(jpegData[1] == 0xD8)
    }

    @Test("Encoder handles grayscale images")
    func encoderHandlesGrayscale() throws {
        let image = try JLIImage(
            width: 8, height: 8,
            pixelFormat: .uint8, colorModel: .grayscale,
            data: [UInt8](repeating: 200, count: 64)
        )
        let jpegData = try JLIEncoder().encode(image)
        #expect(jpegData[0] == 0xFF)
        #expect(jpegData[1] == 0xD8)
    }

    @Test("Encoder handles 4:2:0 subsampling")
    func encoderHandles420() throws {
        let image = try JLIImage(
            width: 16, height: 16,
            pixelFormat: .uint8, colorModel: .rgb,
            data: [UInt8](repeating: 100, count: 16 * 16 * 3)
        )
        var config = JLIEncoderConfiguration.default
        config.chromaSubsampling = .yuv420
        let jpegData = try JLIEncoder().encode(image, configuration: config)
        #expect(jpegData[0] == 0xFF)
        #expect(jpegData[1] == 0xD8)
    }

    @Test("Encoder handles non-multiple-of-8 dimensions")
    func encoderHandlesOddDimensions() throws {
        let image = try JLIImage(
            width: 13, height: 7,
            pixelFormat: .uint8, colorModel: .rgb,
            data: [UInt8](repeating: 50, count: 13 * 7 * 3)
        )
        var config = JLIEncoderConfiguration.default
        config.chromaSubsampling = .yuv444
        let jpegData = try JLIEncoder().encode(image, configuration: config)
        #expect(jpegData[0] == 0xFF)
        #expect(jpegData[1] == 0xD8)
    }

    @Test("Encoder rejects invalid quality")
    func encoderRejectsInvalidQuality() throws {
        let image = try JLIImage(
            width: 1, height: 1,
            pixelFormat: .uint8, colorModel: .rgb,
            data: [0, 0, 0]
        )
        var config = JLIEncoderConfiguration.default
        config.quality = 101.0
        #expect(throws: JLIError.self) {
            try JLIEncoder().encode(image, configuration: config)
        }
    }

    @Test("Encoder rejects negative distance")
    func encoderRejectsNegativeDistance() throws {
        let image = try JLIImage(
            width: 1, height: 1,
            pixelFormat: .uint8, colorModel: .rgb,
            data: [0, 0, 0]
        )
        var config = JLIEncoderConfiguration.default
        config.distance = -1.0
        #expect(throws: JLIError.self) {
            try JLIEncoder().encode(image, configuration: config)
        }
    }

    @Test("Higher quality produces larger output")
    func higherQualityLargerOutput() throws {
        let image = try JLIImage(
            width: 16, height: 16,
            pixelFormat: .uint8, colorModel: .rgb,
            data: (0..<(16 * 16 * 3)).map { UInt8($0 % 256) }
        )

        var lowConfig = JLIEncoderConfiguration.default
        lowConfig.quality = 10; lowConfig.chromaSubsampling = .yuv444
        var highConfig = JLIEncoderConfiguration.default
        highConfig.quality = 95; highConfig.chromaSubsampling = .yuv444

        let lowData = try JLIEncoder().encode(image, configuration: lowConfig)
        let highData = try JLIEncoder().encode(image, configuration: highConfig)

        #expect(highData.count > lowData.count)
    }

    // MARK: - Decoder

    @Test("Decoder rejects non-JPEG data")
    func decoderRejectsNonJPEG() {
        #expect(throws: JLIError.self) {
            try JLIDecoder().decode(from: [0x00, 0x00, 0x00])
        }
    }

    @Test("Decoder inspect rejects non-JPEG data")
    func decoderInspectRejectsNonJPEG() {
        #expect(throws: JLIError.self) {
            try JLIDecoder().inspect(data: [0x89, 0x50])
        }
    }

    // MARK: - Encode → Decode Round-Trip

    @Test("Encode then decode produces image with correct dimensions")
    func encodeDecodeRoundTripDimensions() throws {
        let width = 16
        let height = 16
        let image = try JLIImage(
            width: width, height: height,
            pixelFormat: .uint8, colorModel: .rgb,
            data: [UInt8](repeating: 128, count: width * height * 3)
        )

        var config = JLIEncoderConfiguration.default
        config.chromaSubsampling = .yuv444
        let jpegData = try JLIEncoder().encode(image, configuration: config)
        let decoded = try JLIDecoder().decode(from: jpegData)

        #expect(decoded.width == width)
        #expect(decoded.height == height)
        #expect(decoded.colorModel == .rgb)
    }

    @Test("Inspect returns correct metadata for encoded JPEG")
    func inspectEncodedJPEG() throws {
        let image = try JLIImage(
            width: 32, height: 24,
            pixelFormat: .uint8, colorModel: .rgb,
            data: [UInt8](repeating: 100, count: 32 * 24 * 3)
        )

        var config = JLIEncoderConfiguration.default
        config.chromaSubsampling = .yuv420
        let jpegData = try JLIEncoder().encode(image, configuration: config)
        let info = try JLIDecoder().inspect(data: jpegData)

        #expect(info.width == 32)
        #expect(info.height == 24)
        #expect(info.componentCount == 3)
        #expect(info.bitsPerComponent == 8)
        #expect(info.chromaSubsampling == .yuv420)
    }

    @Test("Encode-decode round-trip preserves pixel values within JPEG tolerance")
    func encodeDecodeRoundTripPixelValues() throws {
        // Use a simple solid color image for best round-trip fidelity
        let width = 8
        let height = 8
        var pixelData = [UInt8](repeating: 0, count: width * height * 3)
        for i in 0..<(width * height) {
            pixelData[i * 3] = 128     // R
            pixelData[i * 3 + 1] = 128 // G
            pixelData[i * 3 + 2] = 128 // B
        }

        let image = try JLIImage(
            width: width, height: height,
            pixelFormat: .uint8, colorModel: .rgb,
            data: pixelData
        )

        var config = JLIEncoderConfiguration.default
        config.quality = 100
        config.chromaSubsampling = .yuv444
        let jpegData = try JLIEncoder().encode(image, configuration: config)
        let decoded = try JLIDecoder().decode(from: jpegData)

        // At quality 100, uniform gray should be very close
        for i in 0..<decoded.data.count {
            let diff = abs(Int(decoded.data[i]) - 128)
            #expect(diff <= 3, "Pixel byte \(i): expected ~128, got \(decoded.data[i])")
        }
    }

    @Test("Grayscale encode-decode round-trip")
    func grayscaleRoundTrip() throws {
        let width = 8
        let height = 8
        let image = try JLIImage(
            width: width, height: height,
            pixelFormat: .uint8, colorModel: .grayscale,
            data: [UInt8](repeating: 200, count: width * height)
        )

        var config = JLIEncoderConfiguration.default
        config.quality = 100
        config.chromaSubsampling = .yuv400

        let jpegData = try JLIEncoder().encode(image, configuration: config)
        let decoderConfig = JLIDecoderConfiguration(
            outputPixelFormat: .uint8,
            outputColorModel: .grayscale
        )
        let decoded = try JLIDecoder().decode(from: jpegData, configuration: decoderConfig)

        #expect(decoded.width == width)
        #expect(decoded.height == height)
        #expect(decoded.colorModel == .grayscale)

        for i in 0..<decoded.data.count {
            let diff = abs(Int(decoded.data[i]) - 200)
            #expect(diff <= 3, "Grayscale byte \(i): expected ~200, got \(decoded.data[i])")
        }
    }

    // MARK: - 12-bit grayscale

    /// Helper: pack a uint16 grayscale plane into the little-endian byte layout
    /// JLIImage expects for `.uint16`.
    private func packLE16(_ samples: [UInt16]) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: samples.count * 2)
        for i in 0..<samples.count {
            bytes[i * 2] = UInt8(samples[i] & 0xFF)
            bytes[i * 2 + 1] = UInt8(samples[i] >> 8)
        }
        return bytes
    }

    private func unpackLE16(_ bytes: [UInt8]) -> [UInt16] {
        var out = [UInt16](repeating: 0, count: bytes.count / 2)
        for i in 0..<out.count {
            out[i] = UInt16(bytes[i * 2]) | (UInt16(bytes[i * 2 + 1]) << 8)
        }
        return out
    }

    @Test("12-bit JPEG reports precision 12 via inspect")
    func twelveBitInspect() throws {
        let w = 16, h = 16
        // A 12-bit gradient: values 0…4095 across the image.
        var samples = [UInt16](repeating: 0, count: w * h)
        for i in 0..<samples.count { samples[i] = UInt16(i * 4095 / (w * h - 1)) }
        let image = try JLIImage(
            width: w, height: h, pixelFormat: .uint16, colorModel: .grayscale,
            data: packLE16(samples)
        )
        var config = JLIEncoderConfiguration.default
        config.chromaSubsampling = .yuv400
        let jpeg = try JLIEncoder().encode(image, configuration: config)

        let info = try JLIDecoder().inspect(data: jpeg)
        #expect(info.bitsPerComponent == 12)
        #expect(info.isExtendedPrecision)
        #expect(info.width == w && info.height == h)
    }

    @Test("12-bit grayscale round-trips with sub-1% error and outputs uint16")
    func twelveBitRoundTrip() throws {
        let w = 32, h = 32
        // Smooth 12-bit ramp — compresses well, and rounding error should be tiny.
        var samples = [UInt16](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                samples[y * w + x] = UInt16((x + y) * 4095 / (w + h - 2))
            }
        }
        let image = try JLIImage(
            width: w, height: h, pixelFormat: .uint16, colorModel: .grayscale,
            data: packLE16(samples)
        )
        var config = JLIEncoderConfiguration.default
        config.quality = 95
        config.chromaSubsampling = .yuv400

        let jpeg = try JLIEncoder().encode(image, configuration: config)
        let decoded = try JLIDecoder().decode(from: jpeg)

        #expect(decoded.pixelFormat == .uint16)
        #expect(decoded.colorModel == .grayscale)
        #expect(decoded.width == w && decoded.height == h)

        let out = unpackLE16(decoded.data)
        #expect(out.count == samples.count)
        // At q=95 a 12-bit smooth ramp should reconstruct within a small fraction
        // of the 0–4095 range. Allow ~1% (40 levels) tolerance for DCT/quant loss.
        var maxErr = 0
        for i in 0..<out.count {
            maxErr = max(maxErr, abs(Int(out[i]) - Int(samples[i])))
        }
        #expect(maxErr <= 40, "max 12-bit error \(maxErr) exceeds tolerance")
    }

    @Test("12-bit color round-trips and outputs uint16 RGB")
    func twelveBitColorRoundTrip() throws {
        let w = 32, h = 32
        // Independent smooth 12-bit ramps per channel.
        var samples = [UInt16](repeating: 0, count: w * h * 3)
        for y in 0..<h {
            for x in 0..<w {
                let i = (y * w + x) * 3
                samples[i]     = UInt16(x * 4095 / (w - 1))
                samples[i + 1] = UInt16(y * 4095 / (h - 1))
                samples[i + 2] = UInt16((x + y) * 4095 / (w + h - 2))
            }
        }
        let image = try JLIImage(
            width: w, height: h, pixelFormat: .uint16, colorModel: .rgb,
            data: packLE16(samples)
        )
        var config = JLIEncoderConfiguration.default
        config.quality = 95
        config.chromaSubsampling = .yuv444   // no chroma loss, isolate precision

        let jpeg = try JLIEncoder().encode(image, configuration: config)
        let info = try JLIDecoder().inspect(data: jpeg)
        #expect(info.bitsPerComponent == 12)
        #expect(info.componentCount == 3)

        let decoded = try JLIDecoder().decode(from: jpeg)
        #expect(decoded.pixelFormat == .uint16)
        #expect(decoded.colorModel == .rgb)
        #expect(decoded.width == w && decoded.height == h)

        let out = unpackLE16(decoded.data)
        #expect(out.count == samples.count)
        // 12-bit uses the standard (8-bit-range) quant tables, so coefficients are
        // barely quantized → near-lossless. Allow color-conversion + quant rounding.
        var maxErr = 0
        for i in 0..<out.count { maxErr = max(maxErr, abs(Int(out[i]) - Int(samples[i]))) }
        #expect(maxErr <= 48, "max 12-bit color error \(maxErr) exceeds tolerance")
    }

    // MARK: - Restart markers

    @Test("Restart markers round-trip identically to no-restart and emit DRI + RSTn")
    func restartMarkers() throws {
        let w = 48, h = 40   // 4:2:0 → 3×3 = 9 MCUs
        var rgb = [UInt8](repeating: 0, count: w * h * 3)
        for y in 0..<h {
            for x in 0..<w {
                let i = (y * w + x) * 3
                rgb[i] = UInt8((x * 5) & 0xFF)
                rgb[i + 1] = UInt8((y * 7) & 0xFF)
                rgb[i + 2] = UInt8(((x + y) * 3) & 0xFF)
            }
        }
        let image = try JLIImage(width: w, height: h, pixelFormat: .uint8, colorModel: .rgb, data: rgb)

        var base = JLIEncoderConfiguration.default
        base.progressive = false; base.chromaSubsampling = .yuv420; base.restartInterval = 0
        var rst = base; rst.restartInterval = 3

        let baseJPEG = try JLIEncoder().encode(image, configuration: base)
        let rstJPEG = try JLIEncoder().encode(image, configuration: rst)

        // Count RSTn markers in the entropy segment (after SOS, where 0xFF is only
        // ever followed by 0x00 stuffing or 0xD0–0xD7 restart).
        func sos(_ d: [UInt8]) -> Int {
            var i = 2; while i < d.count - 1 { if d[i] == 0xFF && d[i + 1] == 0xDA { return i }; i += 1 }; return d.count
        }
        func rstCount(_ d: [UInt8]) -> Int {
            var n = 0; var i = sos(d) + 2
            while i < d.count - 1 {
                if d[i] == 0xFF && (0xD0...0xD7).contains(d[i + 1]) { n += 1; i += 2 } else { i += 1 }
            }
            return n
        }
        func hasDRI(_ d: [UInt8]) -> Bool {
            var i = 2; while i < d.count - 1 { if d[i] == 0xFF && d[i + 1] == 0xDD { return true }; i += 1 }; return false
        }

        // RST fires before MCU 3 and MCU 6 → exactly 2 markers; baseline has none.
        #expect(rstCount(rstJPEG) == 2, "expected 2 RST markers, got \(rstCount(rstJPEG))")
        #expect(hasDRI(rstJPEG))
        #expect(rstCount(baseJPEG) == 0 && !hasDRI(baseJPEG))
        #expect(rstJPEG.count > baseJPEG.count)

        // Restart markers don't change the image — decode must be pixel-identical.
        let baseDec = try JLIDecoder().decode(from: baseJPEG)
        let rstDec = try JLIDecoder().decode(from: rstJPEG)
        #expect(rstDec.width == w && rstDec.height == h)
        var maxDiff = 0
        for i in 0..<min(baseDec.data.count, rstDec.data.count) {
            maxDiff = max(maxDiff, abs(Int(baseDec.data[i]) - Int(rstDec.data[i])))
        }
        #expect(maxDiff == 0, "restart vs no-restart decode differ by \(maxDiff)")
    }

    // MARK: - Scaled (thumbnail) decode

    @Test("1/8 scaled decode yields a block-average thumbnail (color)")
    func scaledDecode8Color() throws {
        let w = 64, h = 48   // exact 8-multiples → no partial (edge-replicated) blocks
        var rgb = [UInt8](repeating: 0, count: w * h * 3)
        for y in 0..<h {
            for x in 0..<w {
                let i = (y * w + x) * 3
                rgb[i] = UInt8(40 + x)          // mid-range + smooth → no clipping
                rgb[i + 1] = UInt8(50 + y)
                rgb[i + 2] = UInt8(60 + (x + y) / 2)
            }
        }
        let image = try JLIImage(width: w, height: h, pixelFormat: .uint8, colorModel: .rgb, data: rgb)
        var cfg = JLIEncoderConfiguration.default
        cfg.quality = 92; cfg.chromaSubsampling = .yuv444
        let jpeg = try JLIEncoder().encode(image, configuration: cfg)

        let full = try JLIDecoder().decode(from: jpeg)
        var thumbCfg = JLIDecoderConfiguration.default; thumbCfg.scale = 8
        let thumb = try JLIDecoder().decode(from: jpeg, configuration: thumbCfg)

        #expect(thumb.width == w / 8 && thumb.height == h / 8)
        #expect(thumb.pixelFormat == .uint8 && thumb.colorModel == .rgb)

        // DC = block average, and YCbCr→RGB is linear, so each thumbnail pixel
        // matches the average of the full decode over its 8×8 region (no clipping
        // in this image, so the per-pixel clamp doesn't perturb the average).
        var maxErr = 0
        for ty in 0..<thumb.height {
            for tx in 0..<thumb.width {
                for c in 0..<3 {
                    var sum = 0
                    for dy in 0..<8 { for dx in 0..<8 {
                        sum += Int(full.data[((ty * 8 + dy) * w + (tx * 8 + dx)) * 3 + c])
                    } }
                    let avg = (sum + 32) / 64
                    let tv = Int(thumb.data[(ty * thumb.width + tx) * 3 + c])
                    maxErr = max(maxErr, abs(tv - avg))
                }
            }
        }
        #expect(maxErr <= 6, "thumbnail vs block-average max err \(maxErr)")
    }

    @Test("1/8 scaled decode handles non-multiple dims and 12-bit grayscale")
    func scaledDecode8Gray() throws {
        // Non-multiple-of-8 dimensions → ceil sizing.
        let w = 50, h = 30
        var gray = [UInt8](repeating: 0, count: w * h)
        for i in 0..<gray.count { gray[i] = UInt8(64 + (i % 64)) }
        let img8 = try JLIImage(width: w, height: h, pixelFormat: .uint8, colorModel: .grayscale, data: gray)
        var cfg = JLIEncoderConfiguration.default; cfg.chromaSubsampling = .yuv400
        let jpeg8 = try JLIEncoder().encode(img8, configuration: cfg)
        var thumbCfg = JLIDecoderConfiguration.default; thumbCfg.scale = 8
        let t8 = try JLIDecoder().decode(from: jpeg8, configuration: thumbCfg)
        #expect(t8.width == (w + 7) / 8 && t8.height == (h + 7) / 8)
        #expect(t8.pixelFormat == .uint8 && t8.colorModel == .grayscale)
        #expect(t8.data.count == ((w + 7) / 8) * ((h + 7) / 8))

        // 12-bit grayscale thumbnail → uint16 output at 1/8 dims.
        var s = [UInt8](repeating: 0, count: w * h * 2)
        for i in 0..<(w * h) {
            let v = UInt16(1000 + (i % 2000))
            s[i * 2] = UInt8(v & 0xFF); s[i * 2 + 1] = UInt8(v >> 8)
        }
        let img12 = try JLIImage(width: w, height: h, pixelFormat: .uint16, colorModel: .grayscale, data: s)
        let jpeg12 = try JLIEncoder().encode(img12, configuration: cfg)
        let t12 = try JLIDecoder().decode(from: jpeg12, configuration: thumbCfg)
        #expect(t12.width == (w + 7) / 8 && t12.height == (h + 7) / 8)
        #expect(t12.pixelFormat == .uint16)
        #expect(t12.data.count == ((w + 7) / 8) * ((h + 7) / 8) * 2)
    }

    @Test("1/2 & 1/4 scaled decode equal the box-average of the full decode (color 4:4:4)")
    func scaledDecodeBoxAverageColor() throws {
        let w = 64, h = 48
        var rgb = [UInt8](repeating: 0, count: w * h * 3)
        for y in 0..<h {
            for x in 0..<w {
                let i = (y * w + x) * 3
                rgb[i] = UInt8(40 + x)              // smooth, mid-range → no clipping
                rgb[i + 1] = UInt8(50 + y)
                rgb[i + 2] = UInt8(60 + (x + y) / 2)
            }
        }
        let image = try JLIImage(width: w, height: h, pixelFormat: .uint8, colorModel: .rgb, data: rgb)
        var cfg = JLIEncoderConfiguration.default
        cfg.quality = 92; cfg.chromaSubsampling = .yuv444   // 4:4:4 → linear convert, tight match
        let jpeg = try JLIEncoder().encode(image, configuration: cfg)
        let full = try JLIDecoder().decode(from: jpeg)

        for scale in [2, 4] {
            var sc = JLIDecoderConfiguration.default; sc.scale = scale
            let small = try JLIDecoder().decode(from: jpeg, configuration: sc)
            #expect(small.width == w / scale && small.height == h / scale)
            #expect(small.colorModel == .rgb && small.pixelFormat == .uint8)
            var maxErr = 0
            for ty in 0..<small.height {
                for tx in 0..<small.width {
                    for c in 0..<3 {
                        var sum = 0
                        for dy in 0..<scale { for dx in 0..<scale {
                            sum += Int(full.data[((ty * scale + dy) * w + (tx * scale + dx)) * 3 + c])
                        } }
                        let avg = (sum + scale * scale / 2) / (scale * scale)
                        let tv = Int(small.data[(ty * small.width + tx) * 3 + c])
                        maxErr = max(maxErr, abs(tv - avg))
                    }
                }
            }
            #expect(maxErr <= 4, "scale 1/\(scale) vs box-average max err \(maxErr)")
        }
    }

    @Test("1/2 & 1/4 scaled decode: grayscale (8/12-bit) box-average + non-multiple dims")
    func scaledDecodeBoxAverageGray() throws {
        let w = 48, h = 32
        var gray = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h { for x in 0..<w { gray[y * w + x] = UInt8(50 + (x + y) % 120) } }
        let img8 = try JLIImage(width: w, height: h, pixelFormat: .uint8, colorModel: .grayscale, data: gray)
        var cfg = JLIEncoderConfiguration.default; cfg.quality = 92; cfg.chromaSubsampling = .yuv400
        let jpeg8 = try JLIEncoder().encode(img8, configuration: cfg)
        let full8 = try JLIDecoder().decode(from: jpeg8)
        for scale in [2, 4] {
            var sc = JLIDecoderConfiguration.default; sc.scale = scale
            let small = try JLIDecoder().decode(from: jpeg8, configuration: sc)
            #expect(small.width == w / scale && small.height == h / scale)
            var maxErr = 0
            for ty in 0..<small.height {
                for tx in 0..<small.width {
                    var sum = 0
                    for dy in 0..<scale { for dx in 0..<scale {
                        sum += Int(full8.data[(ty * scale + dy) * w + (tx * scale + dx)])
                    } }
                    let avg = (sum + scale * scale / 2) / (scale * scale)
                    maxErr = max(maxErr, abs(Int(small.data[ty * small.width + tx]) - avg))
                }
            }
            #expect(maxErr <= 4, "gray scale 1/\(scale) vs box-average max err \(maxErr)")
        }

        // 12-bit grayscale → uint16 output, and non-multiple dimensions → ceil sizing.
        let w2 = 50, h2 = 30
        var s16 = [UInt8](repeating: 0, count: w2 * h2 * 2)
        for i in 0..<(w2 * h2) {
            let v = UInt16(1000 + (i % 2000))
            s16[i * 2] = UInt8(v & 0xFF); s16[i * 2 + 1] = UInt8(v >> 8)
        }
        let img12 = try JLIImage(width: w2, height: h2, pixelFormat: .uint16, colorModel: .grayscale, data: s16)
        let jpeg12 = try JLIEncoder().encode(img12, configuration: cfg)
        for scale in [2, 4] {
            var sc = JLIDecoderConfiguration.default; sc.scale = scale
            let t = try JLIDecoder().decode(from: jpeg12, configuration: sc)
            #expect(t.width == (w2 + scale - 1) / scale && t.height == (h2 + scale - 1) / scale)
            #expect(t.pixelFormat == .uint16)
            #expect(t.data.count == t.width * t.height * 2)
        }
    }

    @Test("Parallel trellis + AC-count encode is deterministic and round-trips (large image)")
    func parallelTrellisEncodeDeterministic() throws {
        // 1024×1024 4:2:0 → Y is 16384 blocks, hitting both the trellis (≥4096)
        // and AC-count (≥16384) parallel thresholds, so both parallel stages run;
        // a data race in either surfaces as non-identical output across runs, and
        // a partitioning bug as round-trip corruption.
        let w = 1024, h = 1024
        var rgb = [UInt8](repeating: 0, count: w * h * 3)
        for y in 0..<h {
            for x in 0..<w {
                let i = (y * w + x) * 3
                // Smooth gradient + light texture: races in the parallel stages
                // show up regardless of content (they run on block count), so keep
                // the trellis DP light to keep this large-image test fast.
                rgb[i] = UInt8((30 + x / 6 + (x & 3)) & 0xFF)
                rgb[i + 1] = UInt8((40 + y / 6 + (y & 3)) & 0xFF)
                rgb[i + 2] = UInt8((50 + (x + y) / 8) & 0xFF)
            }
        }
        let img = try JLIImage(width: w, height: h, pixelFormat: .uint8, colorModel: .rgb, data: rgb)
        var cfg = JLIEncoderConfiguration.default
        cfg.quality = 88; cfg.chromaSubsampling = .yuv420      // trellis on (adaptiveQuantization default)
        let enc = JLIEncoder()
        let first = try enc.encode(img, configuration: cfg)
        for _ in 0..<2 {
            #expect(try enc.encode(img, configuration: cfg) == first,
                    "parallel trellis encode is not deterministic (possible data race)")
        }
        let dec = try JLIDecoder().decode(from: first)
        #expect(dec.width == w && dec.height == h && dec.colorModel == .rgb)
        #expect(dec.data.count == w * h * 3)
    }

    @Test("Parallel Step-7 reconstruction is bit-identical to serial (large image)")
    func parallelDecodeDeterministic() throws {
        // 1024×1023 4:2:0 → 16384 luma blocks (over the reconstruct gate of
        // 2048), with a non-multiple-of-8 height so edge blocks exercise the
        // partial-row scatter. Decode races surface as non-identical pixels
        // across runs; the forced-serial decode proves the block-range fan-out
        // itself is bit-identical.
        let w = 1024, h = 1023
        var rgb = [UInt8](repeating: 0, count: w * h * 3)
        for y in 0..<h {
            for x in 0..<w {
                let i = (y * w + x) * 3
                rgb[i] = UInt8((30 + x / 5 + (y & 7)) & 0xFF)
                rgb[i + 1] = UInt8((60 + y / 4 + (x & 3)) & 0xFF)
                rgb[i + 2] = UInt8((90 + (x + y) / 9) & 0xFF)
            }
        }
        let img = try JLIImage(width: w, height: h, pixelFormat: .uint8, colorModel: .rgb, data: rgb)
        let jpeg = try JLIEncoder().encode(img, configuration: .default)

        let parallel = try JLIDecoder().decode(from: jpeg)
        for _ in 0..<2 {
            #expect(try JLIDecoder().decode(from: jpeg).data == parallel.data,
                    "parallel decode is not deterministic (possible data race)")
        }

        let savedGate = JLIDecoder.reconstructMinBlocksPerChunk
        JLIDecoder.reconstructMinBlocksPerChunk = .max
        defer { JLIDecoder.reconstructMinBlocksPerChunk = savedGate }
        let serial = try JLIDecoder().decode(from: jpeg)
        #expect(serial.data == parallel.data, "parallel decode differs from serial")
    }

    // MARK: - Distance parameter

    @Test("Larger distance produces smaller output (monotonic rate)")
    func distanceMonotonicRate() throws {
        let w = 64, h = 64
        var rgb = [UInt8](repeating: 0, count: w * h * 3)
        // A textured pattern so quantization actually bites.
        for y in 0..<h {
            for x in 0..<w {
                let i = (y * w + x) * 3
                let v = UInt8((x * 7 + y * 13) & 0xFF)
                rgb[i] = v; rgb[i + 1] = 255 &- v; rgb[i + 2] = v
            }
        }
        let image = try JLIImage(
            width: w, height: h, pixelFormat: .uint8, colorModel: .rgb, data: rgb
        )

        func sizeAt(distance: Double) throws -> Int {
            var cfg = JLIEncoderConfiguration.default
            cfg.distance = distance
            cfg.chromaSubsampling = .yuv444
            return try JLIEncoder().encode(image, configuration: cfg).count
        }

        // Distances from visually lossless to aggressive — sizes must not increase.
        let distances = [0.5, 1.0, 2.0, 4.0, 8.0]
        var sizes = [Int]()
        for d in distances { sizes.append(try sizeAt(distance: d)) }
        for k in 1..<sizes.count {
            #expect(sizes[k] <= sizes[k - 1],
                    "size rose at distance \(distances[k]): \(sizes) ")
        }
    }

    @Test("Distance overrides quality when both are set")
    func distanceOverridesQuality() throws {
        let w = 32, h = 32
        let rgb = (0..<(w * h * 3)).map { UInt8($0 % 256) }
        let image = try JLIImage(
            width: w, height: h, pixelFormat: .uint8, colorModel: .rgb, data: rgb
        )
        // quality says "low" but distance says "near-lossless" — distance wins,
        // so output should match the equivalent distance-only encode and be
        // markedly larger than the quality-only low-quality encode.
        var lowQ = JLIEncoderConfiguration.default
        lowQ.quality = 10; lowQ.distance = nil; lowQ.chromaSubsampling = .yuv444
        var distOverride = JLIEncoderConfiguration.default
        distOverride.quality = 10; distOverride.distance = 0.5; distOverride.chromaSubsampling = .yuv444

        let lowQData = try JLIEncoder().encode(image, configuration: lowQ)
        let overrideData = try JLIEncoder().encode(image, configuration: distOverride)
        #expect(overrideData.count > lowQData.count,
                "distance 0.5 should override quality 10 and yield a larger file")

        // And it round-trips.
        let decoded = try JLIDecoder().decode(from: overrideData)
        #expect(decoded.width == w && decoded.height == h)
    }

    @Test("12-bit preserves more precision than 8-bit on a fine gradient")
    func twelveBitBeatsEightBit() throws {
        // A gradient with fine steps that 8-bit can't represent: 16 distinct
        // 12-bit levels packed into a span of 64 (i.e. steps of 4 in 12-bit,
        // which collapse to the same 8-bit value after >>4).
        let w = 64, h = 8
        var samples12 = [UInt16](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                samples12[y * w + x] = UInt16(2000 + x)  // 2000…2063, fine 12-bit detail
            }
        }
        let img12 = try JLIImage(
            width: w, height: h, pixelFormat: .uint16, colorModel: .grayscale,
            data: packLE16(samples12)
        )
        var config = JLIEncoderConfiguration.default
        config.quality = 98
        config.chromaSubsampling = .yuv400

        let jpeg12 = try JLIEncoder().encode(img12, configuration: config)
        let dec12 = unpackLE16(try JLIDecoder().decode(from: jpeg12).data)

        // The 12-bit round-trip should preserve the fine ramp's monotonic detail:
        // the reconstructed span must be clearly wider than the ~16 levels an
        // 8-bit pipeline (>>4) would have collapsed it to.
        let span = Int(dec12.max()!) - Int(dec12.min()!)
        #expect(span >= 40, "12-bit reconstructed span \(span) too small — detail lost")
    }

    @Test("Adaptive quant field changes the output and round-trips (4:4:4)")
    func adaptiveQuantField() throws {
        // Smooth left half + busy right half — the content adaptive quant targets.
        let w = 96, h = 96
        var rgb = [UInt8](repeating: 0, count: w * h * 3)
        for y in 0..<h {
            for x in 0..<w {
                let i = (y * w + x) * 3
                if x < w / 2 {
                    let v = 40 + x * 120 / w
                    rgb[i] = UInt8(v); rgb[i + 1] = UInt8(v); rgb[i + 2] = UInt8(min(255, v + 20))
                } else {
                    rgb[i] = UInt8((x ^ y) & 0xFF)
                    rgb[i + 1] = UInt8((x &* 5 &+ y &* 3) & 0xFF)
                    rgb[i + 2] = UInt8((x &+ y &* 7) & 0xFF)
                }
            }
        }
        let img = try JLIImage(width: w, height: h, pixelFormat: .uint8, colorModel: .rgb, data: rgb)
        var off = JLIEncoderConfiguration.default
        // Exercise the adaptive field against the Annex-K path: under the new
        // perceptual-table default the field is effectively inert (it barely
        // shifts the trellis λ when the quant steps already come from the
        // perceptual model), so pin perceptual off to isolate the field's effect.
        off.chromaSubsampling = .yuv444; off.quality = 85; off.perceptualQuantTables = false
        var on = off; on.adaptiveQuantField = true

        let jOff = try JLIEncoder().encode(img, configuration: off)
        let jOn = try JLIEncoder().encode(img, configuration: on)
        #expect(jOn != jOff, "adaptiveQuantField should change the encoded output")

        // Both must round-trip to a valid full-size RGB image (no corruption).
        for jpeg in [jOff, jOn] {
            let dec = try JLIDecoder().decode(from: jpeg)
            #expect(dec.width == w && dec.height == h && dec.colorModel == .rgb)
            #expect(dec.data.count == w * h * 3)
        }
    }

    // MARK: - float32 input

    private func float32LE(_ values: [Float]) -> [UInt8] {
        var out = [UInt8](); out.reserveCapacity(values.count * 4)
        for v in values {
            let b = v.bitPattern
            out.append(UInt8(b & 0xFF)); out.append(UInt8((b >> 8) & 0xFF))
            out.append(UInt8((b >> 16) & 0xFF)); out.append(UInt8((b >> 24) & 0xFF))
        }
        return out
    }

    @Test("float32 input ([0,1]) encodes identically to its 8-bit quantization")
    func float32Input() throws {
        let w = 40, h = 32
        var floats = [Float](repeating: 0, count: w * h * 3)
        var u8 = [UInt8](repeating: 0, count: w * h * 3)
        for i in 0..<floats.count {
            let v = Float(i % 256) / 255.0                   // in [0,1]
            floats[i] = v
            u8[i] = UInt8(clamping: Int((v * 255).rounded()))
        }
        let fImg = try JLIImage(width: w, height: h, pixelFormat: .float32, colorModel: .rgb, data: float32LE(floats))
        let uImg = try JLIImage(width: w, height: h, pixelFormat: .uint8, colorModel: .rgb, data: u8)
        // The float path quantizes to exactly `u8`, so the encoded bytes match.
        for cfg in [JLIEncoderConfiguration.default,
                    { var c = JLIEncoderConfiguration.default; c.lossless = true; c.chromaSubsampling = .yuv444; return c }()] {
            #expect(try JLIEncoder().encode(fImg, configuration: cfg) == JLIEncoder().encode(uImg, configuration: cfg),
                    "float32 input must encode identically to its 8-bit quantization")
        }
        let dec = try JLIDecoder().decode(from: try JLIEncoder().encode(fImg, configuration: .default))
        #expect(dec.width == w && dec.height == h && dec.pixelFormat == .uint8 && dec.colorModel == .rgb)
    }

    @Test("float32 input clamps out-of-range values to [0,1]")
    func float32Clamp() throws {
        let w = 8, h = 8
        var cfg = JLIEncoderConfiguration.default
        cfg.lossless = true; cfg.chromaSubsampling = .yuv400   // lossless → read back exact
        for (v, expected): (Float, UInt8) in [(-0.5, 0), (1.5, 255), (0.5, 128)] {
            let data = float32LE([Float](repeating: v, count: w * h))
            let img = try JLIImage(width: w, height: h, pixelFormat: .float32, colorModel: .grayscale, data: data)
            let dec = try JLIDecoder().decode(from: try JLIEncoder().encode(img, configuration: cfg))
            #expect(dec.data.allSatisfy { $0 == expected },
                    "float \(v) should clamp/scale to \(expected), got \(dec.data.first ?? 99)")
        }
    }
}
