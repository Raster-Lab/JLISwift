// SPDX-License-Identifier: Apache-2.0
// Copyright 2024 Raster Lab. All rights reserved.

import Testing
@testable import JLISwift

@Suite("JLISwift Core Types")
struct CoreTypeTests {
    // MARK: - JLIImage

    @Test("JLIImage rejects zero width")
    func imageRejectsZeroWidth() throws {
        #expect(throws: JLIError.self) {
            try JLIImage(width: 0, height: 10, pixelFormat: .uint8, colorModel: .rgb, data: [])
        }
    }

    @Test("JLIImage rejects zero height")
    func imageRejectsZeroHeight() throws {
        #expect(throws: JLIError.self) {
            try JLIImage(width: 10, height: 0, pixelFormat: .uint8, colorModel: .rgb, data: [])
        }
    }

    @Test("JLIImage rejects mismatched buffer size")
    func imageRejectsMismatchedBuffer() throws {
        #expect(throws: JLIError.self) {
            try JLIImage(
                width: 2, height: 2,
                pixelFormat: .uint8, colorModel: .rgb,
                data: [UInt8](repeating: 0, count: 10)  // expected 12
            )
        }
    }

    @Test("JLIImage accepts correctly sized buffer")
    func imageAcceptsCorrectBuffer() throws {
        let image = try JLIImage(
            width: 2, height: 2,
            pixelFormat: .uint8, colorModel: .rgb,
            data: [UInt8](repeating: 128, count: 12)
        )
        #expect(image.width == 2)
        #expect(image.height == 2)
        #expect(image.bytesPerRow == 6)
    }

    @Test("JLIImage accepts 16-bit pixel format")
    func imageAccepts16Bit() throws {
        // 1×1 RGB uint16 = 3 components × 2 bytes = 6 bytes
        let image = try JLIImage(
            width: 1, height: 1,
            pixelFormat: .uint16, colorModel: .rgb,
            data: [UInt8](repeating: 0, count: 6)
        )
        #expect(image.pixelFormat.bitsPerComponent == 16)
    }

    @Test("JLIImage accepts float32 pixel format")
    func imageAcceptsFloat32() throws {
        // 1×1 RGB float32 = 3 components × 4 bytes = 12 bytes
        let image = try JLIImage(
            width: 1, height: 1,
            pixelFormat: .float32, colorModel: .rgb,
            data: [UInt8](repeating: 0, count: 12)
        )
        #expect(image.pixelFormat.bitsPerComponent == 32)
    }

    // MARK: - JLIPixelFormat

    @Test("Pixel format bytes per component")
    func pixelFormatBytesPerComponent() {
        #expect(JLIPixelFormat.uint8.bytesPerComponent == 1)
        #expect(JLIPixelFormat.uint16.bytesPerComponent == 2)
        #expect(JLIPixelFormat.float32.bytesPerComponent == 4)
    }

    // MARK: - JLIColorModel

    @Test("Color model component counts")
    func colorModelComponentCounts() {
        #expect(JLIColorModel.grayscale.componentCount == 1)
        #expect(JLIColorModel.rgb.componentCount == 3)
        #expect(JLIColorModel.rgba.componentCount == 4)
        #expect(JLIColorModel.yCbCr.componentCount == 3)
        #expect(JLIColorModel.cmyk.componentCount == 4)
        #expect(JLIColorModel.xyb.componentCount == 3)
    }

    // MARK: - JLIEncoderConfiguration

    @Test("Default encoder configuration has sensible values")
    func defaultEncoderConfiguration() {
        let config = JLIEncoderConfiguration.default
        #expect(config.quality == 90.0)
        #expect(config.distance == nil)
        #expect(config.progressive == true)
        #expect(config.adaptiveQuantization == true)
    }

    // MARK: - JLIEncoder

    @Test("Encoder rejects invalid quality")
    func encoderRejectsInvalidQuality() throws {
        let encoder = JLIEncoder()
        let image = try JLIImage(
            width: 1, height: 1,
            pixelFormat: .uint8, colorModel: .rgb,
            data: [UInt8](repeating: 0, count: 3)
        )
        var config = JLIEncoderConfiguration.default
        config.quality = 101.0
        #expect(throws: JLIError.self) {
            try encoder.encode(image, configuration: config)
        }
    }

    @Test("Encoder rejects negative distance")
    func encoderRejectsNegativeDistance() throws {
        let encoder = JLIEncoder()
        let image = try JLIImage(
            width: 1, height: 1,
            pixelFormat: .uint8, colorModel: .rgb,
            data: [UInt8](repeating: 0, count: 3)
        )
        var config = JLIEncoderConfiguration.default
        config.distance = -1.0
        #expect(throws: JLIError.self) {
            try encoder.encode(image, configuration: config)
        }
    }

    @Test("Encoder returns not-implemented for valid input")
    func encoderNotImplemented() throws {
        let encoder = JLIEncoder()
        let image = try JLIImage(
            width: 1, height: 1,
            pixelFormat: .uint8, colorModel: .rgb,
            data: [UInt8](repeating: 0, count: 3)
        )
        #expect(throws: JLIError.self) {
            try encoder.encode(image)
        }
    }

    // MARK: - JLIDecoder

    @Test("Decoder rejects non-JPEG data")
    func decoderRejectsNonJPEG() {
        let decoder = JLIDecoder()
        #expect(throws: JLIError.self) {
            try decoder.decode(from: [0x00, 0x00, 0x00])
        }
    }

    @Test("Decoder inspect rejects non-JPEG data")
    func decoderInspectRejectsNonJPEG() {
        let decoder = JLIDecoder()
        #expect(throws: JLIError.self) {
            try decoder.inspect(data: [0x89, 0x50])  // PNG magic, not JPEG
        }
    }

    @Test("Decoder returns not-implemented for valid JPEG header")
    func decoderNotImplemented() {
        let decoder = JLIDecoder()
        // Minimal valid JPEG SOI marker
        #expect(throws: JLIError.self) {
            try decoder.decode(from: [0xFF, 0xD8, 0xFF, 0xD9])
        }
    }

    // MARK: - JLIPlatformCapabilities

    @Test("Platform capabilities are detected")
    func platformCapabilities() {
        let caps = JLIPlatformCapabilities.current
        // On any platform, architecture should not be unknown in CI
        #expect(caps.architecture != .unknown)
    }

    // MARK: - Version

    @Test("Library version is set")
    func libraryVersion() {
        #expect(JLISwift.version == "0.1.0")
    }
}
