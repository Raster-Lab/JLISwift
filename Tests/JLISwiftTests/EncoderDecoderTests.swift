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
}
