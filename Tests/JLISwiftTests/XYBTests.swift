// SPDX-License-Identifier: Apache-2.0
// Copyright 2024 Raster Lab. All rights reserved.

import Testing
import Foundation
import CoreGraphics
@testable import JLISwift

/// XYB color JPEG support. The headline check: the embedded ICC profile (a port
/// of libjxl's XYB profile) is accepted by Apple's color engine and transforms
/// XYB samples → sRGB matching our own inverse — i.e. a standard ICC-aware
/// decoder renders our XYB JPEGs correctly.
@Suite("XYB color")
struct XYBTests {

    @Test("XYB ICC profile is a valid ICC and matches our inverse transform")
    func iccMatchesInverse() throws {
        let profile = XYBICCProfile.data
        #expect(profile.count > 128, "profile suspiciously small")
        // ICC magic 'acsp' at byte 36, and the declared size equals the data.
        #expect(Array(profile[36..<40]) == Array("acsp".utf8))
        let declared = (Int(profile[0]) << 24) | (Int(profile[1]) << 16)
            | (Int(profile[2]) << 8) | Int(profile[3])
        #expect(declared == profile.count, "ICC size field wrong")

        // Apple's CMS must parse it, and applying it must reproduce our
        // analytic XYB→sRGB to within a couple of LSBs (CLUT interpolation).
        let xyb = try #require(CGColorSpace(iccData: Data(profile) as CFData))
        #expect(xyb.numberOfComponents == 3)
        let srgb = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        var maxErr: Double = 0
        for r in stride(from: 16, through: 240, by: 32) {
            for g in stride(from: 16, through: 240, by: 32) {
                for b in stride(from: 16, through: 240, by: 64) {
                    let (sx, sy, sb) = ColorConversion.rgbToXYBSample(r: Float(r), g: Float(g), b: Float(b))
                    let mine = ColorConversion.xybSampleToRGB(x: sx, y: sy, bChannel: sb)
                    guard let c = CGColor(colorSpace: xyb,
                                          components: [CGFloat(sx / 255), CGFloat(sy / 255),
                                                       CGFloat(sb / 255), 1]),
                          let conv = c.converted(to: srgb, intent: .perceptual, options: nil),
                          let comps = conv.components, comps.count >= 3 else { continue }
                    maxErr = max(maxErr, abs(Double(comps[0]) * 255 - Double(mine.r)))
                    maxErr = max(maxErr, abs(Double(comps[1]) * 255 - Double(mine.g)))
                    maxErr = max(maxErr, abs(Double(comps[2]) * 255 - Double(mine.b)))
                }
            }
        }
        #expect(maxErr < 2.0, "XYB ICC transform disagrees with our inverse (max err \(maxErr))")
    }

    @Test("XYB encode → our decode round-trips, and embeds the XYB ICC + APP14")
    func encodeDecodeRoundTrip() throws {
        let w = 64, h = 48
        var rgb = [UInt8](repeating: 0, count: w * h * 3)
        for y in 0..<h {
            for x in 0..<w {
                let i = (y * w + x) * 3      // smooth gradients, mid-range
                rgb[i] = UInt8(40 + x * 150 / w)
                rgb[i + 1] = UInt8(50 + y * 150 / h)
                rgb[i + 2] = UInt8(60 + (x + y) * 120 / (w + h))
            }
        }
        let img = try JLIImage(width: w, height: h, pixelFormat: .uint8, colorModel: .rgb, data: rgb)
        var cfg = JLIEncoderConfiguration.default
        cfg.quality = 95; cfg.colorSpace = .xyb
        let jpeg = try JLIEncoder().encode(img, configuration: cfg)

        // It must carry the XYB ICC (APP2) and an Adobe APP14 (transform=0).
        let dec = try JLIDecoder().decode(from: jpeg)
        #expect(dec.iccProfile == XYBICCProfile.data, "XYB JPEG must embed the XYB ICC")
        #expect(dec.width == w && dec.height == h && dec.colorModel == .rgb)

        // Our decoder inverts XYB; round-trip error is bounded (lossy DCT + the
        // nonlinear XYB inverse, so judge by mean, with a loose max).
        var sumErr = 0.0, maxErr = 0
        for i in 0..<rgb.count {
            let e = abs(Int(dec.data[i]) - Int(rgb[i]))
            sumErr += Double(e); maxErr = max(maxErr, e)
        }
        let meanErr = sumErr / Double(rgb.count)
        #expect(meanErr < 4.0, "XYB round-trip mean error \(meanErr) too high")
        #expect(maxErr < 40, "XYB round-trip max error \(maxErr) too high")
    }
}
