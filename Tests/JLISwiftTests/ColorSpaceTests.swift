// SPDX-License-Identifier: Apache-2.0
// Copyright 2024 Raster Lab. All rights reserved.

import Testing
@testable import JLISwift

@Suite("Color Space – RGB/YCbCr/XYB Conversions and Chroma Sampling")
struct ColorSpaceTests {

    // MARK: - RGB ↔ YCbCr

    @Test("Black pixel converts to YCbCr correctly")
    func blackPixelToYCbCr() {
        let (y, cb, cr) = ColorConversion.rgbToYCbCr(r: 0, g: 0, b: 0)
        #expect(abs(y) < 1.0)
        #expect(abs(cb - 128.0) < 1.0)
        #expect(abs(cr - 128.0) < 1.0)
    }

    @Test("White pixel converts to YCbCr correctly")
    func whitePixelToYCbCr() {
        let (y, cb, cr) = ColorConversion.rgbToYCbCr(r: 255, g: 255, b: 255)
        #expect(abs(y - 255.0) < 1.0)
        #expect(abs(cb - 128.0) < 1.0)
        #expect(abs(cr - 128.0) < 1.0)
    }

    @Test("RGB → YCbCr → RGB round-trips within tolerance")
    func rgbYCbCrRoundTrip() {
        let testColors: [(Float, Float, Float)] = [
            (0, 0, 0), (255, 255, 255), (255, 0, 0),
            (0, 255, 0), (0, 0, 255), (128, 64, 192)
        ]
        for (r, g, b) in testColors {
            let (y, cb, cr) = ColorConversion.rgbToYCbCr(r: r, g: g, b: b)
            let (rr, gg, bb) = ColorConversion.ycbcrToRGB(y: y, cb: cb, cr: cr)
            #expect(abs(rr - r) < 1.5, "R mismatch for (\(r),\(g),\(b))")
            #expect(abs(gg - g) < 1.5, "G mismatch for (\(r),\(g),\(b))")
            #expect(abs(bb - b) < 1.5, "B mismatch for (\(r),\(g),\(b))")
        }
    }

    @Test("Image-level RGB to YCbCr conversion has correct dimensions")
    func imageRGBToYCbCrDimensions() {
        let width = 4
        let height = 3
        let data = [UInt8](repeating: 128, count: width * height * 3)
        let (y, cb, cr) = ColorConversion.imageRGBToYCbCr(
            data: data, width: width, height: height, componentCount: 3
        )
        #expect(y.count == width * height)
        #expect(cb.count == width * height)
        #expect(cr.count == width * height)
    }

    @Test("Image-level round-trip preserves pixel values")
    func imageRoundTrip() {
        let width = 2
        let height = 2
        let data: [UInt8] = [
            128, 64, 192,   255, 0, 0,
            0, 255, 0,      0, 0, 255
        ]

        let (y, cb, cr) = ColorConversion.imageRGBToYCbCr(
            data: data, width: width, height: height, componentCount: 3
        )
        let result = ColorConversion.imageYCbCrToRGB(
            y: y, cb: cb, cr: cr, width: width, height: height
        )

        for i in 0..<data.count {
            let diff = abs(Int(result[i]) - Int(data[i]))
            #expect(diff <= 2, "Byte \(i): expected \(data[i]), got \(result[i])")
        }
    }

    // MARK: - Grayscale

    @Test("Grayscale to Y plane preserves values")
    func grayscaleToY() {
        let data: [UInt8] = [0, 64, 128, 192, 255]
        let y = ColorConversion.imageGrayscaleToY(data: data, width: 5, height: 1)
        for i in 0..<5 {
            #expect(abs(y[i] - Float(data[i])) < 0.01)
        }
    }

    // MARK: - XYB

    @Test("RGB → XYB → RGB round-trips within tolerance")
    func xybRoundTrip() {
        let (x, y, b) = ColorConversion.rgbToXYB(r: 128, g: 100, b: 200)
        let (rr, gg, bb) = ColorConversion.xybToRGB(x: x, y: y, bChannel: b)
        // XYB uses approximate inverse matrix; tolerance reflects this
        #expect(abs(rr - 128) < 30.0)
        #expect(abs(gg - 100) < 30.0)
        #expect(abs(bb - 200) < 30.0)
    }

    // MARK: - Chroma Sampling

    @Test("4:4:4 sampling returns original dimensions")
    func sampling444() {
        let plane = [Float](repeating: 1, count: 16)
        let result = ChromaSampling.downsample(plane, width: 4, height: 4,
                                                horizontally: false, vertically: false)
        #expect(result.width == 4)
        #expect(result.height == 4)
        #expect(result.data.count == 16)
    }

    @Test("Horizontal downsampling halves width")
    func horizontalDownsample() {
        let plane = [Float](repeating: 100, count: 8)
        let result = ChromaSampling.downsample(plane, width: 4, height: 2,
                                                horizontally: true, vertically: false)
        #expect(result.width == 2)
        #expect(result.height == 2)
        #expect(result.data.count == 4)
    }

    @Test("Downsampling and upsampling preserves dimensions")
    func downsampleUpsampleDimensions() {
        let width = 8
        let height = 8
        let plane = [Float](repeating: 128, count: width * height)
        let ds = ChromaSampling.downsample(plane, width: width, height: height,
                                            horizontally: true, vertically: true)
        let us = ChromaSampling.upsample(ds.data, width: ds.width, height: ds.height,
                                          targetWidth: width, targetHeight: height)
        #expect(us.count == width * height)
    }

    @Test("Sampling factors match expected values")
    func samplingFactors() {
        #expect(ChromaSampling.samplingFactors(for: .yuv444) == (1, 1))
        #expect(ChromaSampling.samplingFactors(for: .yuv422) == (2, 1))
        #expect(ChromaSampling.samplingFactors(for: .yuv420) == (2, 2))
        #expect(ChromaSampling.samplingFactors(for: .yuv400) == (1, 1))
    }
}
